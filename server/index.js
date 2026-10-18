const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, exec } = require('child_process');
const { WebSocketServer, WebSocket } = require('ws');
const qrcode = require('qrcode-terminal');

const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const NATIVE_BIN = path.join(__dirname, '..', 'native', 'mac_host');
let nativeProcess = null;

// Global EPIPE safety net
process.on('uncaughtException', (err) => {
  if (err.code === 'EPIPE' || err.code === 'ECONNRESET') {
    console.warn('[Server] Safe pipe notice (prevented crash):', err.message);
    return;
  }
  console.error('[Server] Uncaught Exception:', err);
});

// Safe helper to write to native mac_host process without EPIPE crashes
function sendToNative(obj) {
  if (!nativeProcess || !nativeProcess.stdin || !nativeProcess.stdin.writable) return;
  try {
    const payload = typeof obj === 'string' ? obj : JSON.stringify(obj) + '\n';
    nativeProcess.stdin.write(payload, (err) => {
      if (err && err.code !== 'EPIPE') {
        console.warn('[Native] Stdin pipe error:', err.message);
      }
    });
  } catch (err) {
    if (err.code !== 'EPIPE') {
      console.warn('[Native] Stdin write exception:', err.message);
    }
  }
}

// Helper: Find local IPv4 addresses
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push({ name, address: iface.address });
      }
    }
  }
  return addresses;
}

// HTTP Server
const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon'
};

let lastJpegFrame = null;
let currentDisplayInfo = { width: 1280, height: 800, fps: 90 };
let currentBrightness = 0.5;
let adbBrightnessTimeout = null;
const mjpegClients = new Set();
let lastClientDisconnectTime = 0;

function setTabletHardwareBrightness(val) {
  currentBrightness = Math.max(0.05, Math.min(1.0, val));
  if (adbBrightnessTimeout) clearTimeout(adbBrightnessTimeout);
  adbBrightnessTimeout = setTimeout(() => {
    const val255 = Math.round(currentBrightness * 255);
    const { exec } = require('child_process');
    exec(`adb shell settings put system screen_brightness ${val255}`, () => {});
  }, 100);
}

// Battery Monitoring (Mac + Tablet)
let currentBattery = {
  mac: { level: null, charging: false },
  tablet: { level: null, charging: false }
};

function checkBatteryStatus(callback) {
  // Read Mac battery via pmset
  exec('pmset -g batt', (err, stdout) => {
    if (!err && stdout) {
      const match = stdout.match(/(\d+)%;\s*([^;]+);/);
      if (match) {
        const level = parseInt(match[1], 10);
        const stateStr = match[2].toLowerCase();
        const charging = stateStr.includes('charging') || stateStr.includes('charged') || stdout.includes("'AC Power'");
        currentBattery.mac = { level, charging };
      }
    }

    // Read tablet battery via ADB if connected
    exec('adb shell dumpsys battery 2>/dev/null', { timeout: 2500 }, (aErr, aStdout) => {
      if (!aErr && aStdout) {
        const lMatch = aStdout.match(/level:\s*(\d+)/);
        const sMatch = aStdout.match(/status:\s*(\d+)/);
        const acMatch = aStdout.match(/AC powered:\s*(true|false)/);
        const usbMatch = aStdout.match(/USB powered:\s*(true|false)/);
        const dockMatch = aStdout.match(/Dock powered:\s*(true|false)/);
        const wirelessMatch = aStdout.match(/Wireless powered:\s*(true|false)/);
        if (lMatch) {
          const tLevel = parseInt(lMatch[1], 10);
          const isStatusCharging = sMatch && (sMatch[1] === '2' || sMatch[1] === '5');
          const isPowered = (acMatch && acMatch[1] === 'true') ||
                            (usbMatch && usbMatch[1] === 'true') ||
                            (dockMatch && dockMatch[1] === 'true') ||
                            (wirelessMatch && wirelessMatch[1] === 'true');
          const tCharging = isStatusCharging || isPowered;
          currentBattery.tablet = { level: tLevel, charging: tCharging };
        }
      } else {
        currentBattery.tablet = { level: null, charging: false };
      }

      if (callback) callback(currentBattery);
    });
  });
}

function broadcastBattery() {
  checkBatteryStatus((batt) => {
    if (!wss) return;
    const payload = JSON.stringify({
      type: 'battery',
      mac: batt.mac,
      tablet: batt.tablet
    });
    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(payload);
      }
    }
  });
}

const server = http.createServer((req, res) => {
  // CORS & Chrome Private Network Access headers for seamless failover between Wi-Fi and USB
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Fallback MJPEG Stream for any browser or VLC
  if (req.url === '/stream.mjpg') {
    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=--myboundary',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
      'Connection': 'close',
      'Pragma': 'no-cache'
    });
    mjpegClients.add(res);
    req.on('close', () => mjpegClients.delete(res));
    return;
  }

  // REST API: Device & Network Info
  if (req.url === '/api/info') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      ips: getLocalIPs(),
      port: PORT,
      display: currentDisplayInfo,
      battery: currentBattery,
      connectedClients: wss ? wss.clients.size : 0
    }));
    return;
  }

  // Static File Serving
  let reqPath = req.url.split('?')[0];
  if (reqPath === '/') reqPath = '/index.html';
  const filePath = path.join(PUBLIC_DIR, reqPath);

  // Security: prevent directory traversal
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    res.end('Access Denied');
    return;
  }

  fs.stat(filePath, (err, stats) => {
    if (err || !stats.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('File Not Found');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': stats.size,
      'Cache-Control': 'no-cache'
    });
    fs.createReadStream(filePath).pipe(res);
  });
});

// Disable Nagle's algorithm for instant packet delivery on all HTTP/TCP connections
server.on('connection', (socket) => {
  socket.setNoDelay(true);
});

// WebSocket Server for Ultra Low-Latency Stream & Gestures
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws, req) => {
  if (req.socket) {
    req.socket.setNoDelay(true);
    req.socket.setKeepAlive(true, 10000);
  }
  if (ws._socket) {
    ws._socket.setNoDelay(true);
  }

  const ip = req.socket ? req.socket.remoteAddress : 'unknown';
  console.log(`[WebSocket] Client connected from ${ip}`);

  // Send initial display info matching client expectations with Wi-Fi fallback IPs
  const localIps = getLocalIPs();
  ws.send(JSON.stringify({
    type: 'init',
    screenWidth: currentDisplayInfo.width,
    screenHeight: currentDisplayInfo.height,
    fps: currentDisplayInfo.fps || 60,
    port: PORT,
    wifiIps: localIps.map(i => i.address),
    wifiUrls: localIps.map(i => `http://${i.address}:${PORT}`),
    displays: currentDisplayInfo.displays || [{
      id: currentDisplayInfo.displayID || 0,
      name: 'macOS Display',
      width: currentDisplayInfo.width,
      height: currentDisplayInfo.height,
      primary: true
    }]
  }));

  // Send latest frame immediately if available, and request fresh capture from native host
  if (lastJpegFrame) {
    ws.send(lastJpegFrame, { binary: true });
  }
  sendToNative({ type: 'request_frame' });

  // Send battery status immediately on connection
  broadcastBattery();

  // Trigger browser fullscreen on tablet if supported via keyevent
  setTimeout(() => {
    exec('adb shell input keyevent 141 >/dev/null 2>&1', () => {}); // F11 keycode
  }, 400);

  ws.on('message', (message, isBinary) => {
    if (isBinary) return;

    try {
      const msgStr = message.toString();
      const msg = JSON.parse(msgStr);

      // Handle Ping / Pong for latency measurements
      if (msg.type === 'ping') {
        ws.send(JSON.stringify({
          type: 'pong',
          timestamp: msg.timestamp,
          serverTime: Date.now()
        }));
        return;
      }



      // Handle dynamic client settings (quality, fps, display switching)
      if (msg.type === 'settings' || msg.type === 'config') {
        const qMap = { low: 0.65, med: 0.80, high: 0.90, ultra: 0.95 };
        const quality = typeof msg.quality === 'string' ? (qMap[msg.quality] || 0.90) : (msg.quality || 0.90);
        const fps = parseInt(msg.targetFps || msg.fps, 10) || 90;
        console.log(`[Settings] Updated by client: FPS=${fps}, Quality=${quality}`);
        sendToNative({ type: 'config', fps, quality });
        if (msg.displayId !== undefined && parseInt(msg.displayId, 10) > 0) {
          sendToNative({ type: 'select_display', displayId: parseInt(msg.displayId, 10) });
        }
        return;
      }

      if (msg.type === 'select_display' || msg.type === 'display_select') {
        const dId = parseInt(msg.displayId, 10);
        if (dId > 0) {
          console.log(`[Display] Client selected display ID: ${dId}`);
          sendToNative({ type: 'select_display', displayId: dId });
        }
        return;
      }

      if (msg.type === 'set_resolution') {
        const width = parseInt(msg.width, 10);
        const height = parseInt(msg.height, 10);
        if (width > 0 && height > 0) {
          console.log(`[Display] Client requested resolution: ${width}x${height}`);
          sendToNative({ type: 'set_resolution', width, height });
        }
        return;
      }

      // Handle Manual Brightness adjustment from client slider
      if (msg.type === 'set_brightness') {
        const val = parseFloat(msg.value);
        if (!isNaN(val)) {
          setTabletHardwareBrightness(val);
          for (const client of wss.clients) {
            if (client !== ws && client.readyState === WebSocket.OPEN) {
              client.send(JSON.stringify({ type: 'brightness', value: val }));
            }
          }
        }
        return;
      }

      if (msg.type === 'request_frame') {
        if (lastJpegFrame) {
          ws.send(lastJpegFrame, { binary: true });
        }
        sendToNative({ type: 'request_frame' });
        return;
      }

      // Handle Mouse / Touch actions
      if (msg.type === 'mouse') {
        const normX = msg.normX !== undefined ? msg.normX : (msg.x !== undefined ? msg.x : 0);
        const normY = msg.normY !== undefined ? msg.normY : (msg.y !== undefined ? msg.y : 0);
        const x = (msg.absX !== undefined && msg.absX !== null) ? msg.absX : Math.round(normX * currentDisplayInfo.width);
        const y = (msg.absY !== undefined && msg.absY !== null) ? msg.absY : Math.round(normY * currentDisplayInfo.height);
        let hostCmd = null;

        switch (msg.action) {
          case 'mousemove':
            const isDragging = !!(msg.isDragging || msg.buttons === 1);
            hostCmd = isDragging ? { type: 'drag', x, y, normX, normY } : { type: 'move', x, y, normX, normY };
            break;
          case 'mousemove_delta':
            hostCmd = { type: 'move_relative', dx: msg.dx || 0, dy: msg.dy || 0 };
            break;
          case 'mousedown':
            hostCmd = { type: 'mousedown', button: msg.button || 'left', x, y, normX, normY, modifiers: msg.modifiers || [] };
            break;
          case 'mouseup':
            hostCmd = { type: 'mouseup', button: msg.button || 'left', x, y, normX, normY, modifiers: msg.modifiers || [] };
            break;
          case 'click':
            hostCmd = { type: 'click', button: msg.button || 'left', count: msg.count || 1, x, y, normX, normY, modifiers: msg.modifiers || [] };
            break;
        }

        if (hostCmd) {
          sendToNative(hostCmd);
        }
        return;
      }

      // Handle Smooth Scroll
      if (msg.type === 'scroll') {
        const x = (msg.absX !== undefined && msg.absX !== null) ? msg.absX : Math.round((msg.normX || 0) * currentDisplayInfo.width);
        const y = (msg.absY !== undefined && msg.absY !== null) ? msg.absY : Math.round((msg.normY || 0) * currentDisplayInfo.height);
        sendToNative({
          type: 'scroll',
          dx: msg.dx || 0,
          dy: msg.dy || 0,
          x,
          y,
          normX: msg.normX !== undefined ? msg.normX : msg.x,
          normY: msg.normY !== undefined ? msg.normY : msg.y
        });
        return;
      }

      // Handle Shortcuts (Mission Control, Show Desktop, Copy, Paste, etc.)
      if (msg.type === 'shortcut') {
        const name = msg.combo || msg.name;
        sendToNative({ type: 'shortcut', name });
        return;
      }

      // Handle Key events
      if (msg.type === 'key') {
        sendToNative({
          type: 'key',
          macKeyCode: msg.macKeyCode,
          keyCode: msg.keyCode,
          code: msg.code,
          key: msg.key,
          down: msg.action !== 'up',
          modifiers: msg.modifiers || []
        });
        return;
      }

      // Fallback forward any other commands directly
      sendToNative(msgStr);
    } catch (e) {
      console.error('[WebSocket] Message parse error:', e.message);
    }
  });

  ws.on('close', () => {
    console.log(`[WebSocket] Client disconnected (${ip})`);
    lastClientDisconnectTime = Date.now();
  });

  ws.on('error', (err) => {
    console.error('[WebSocket] Client error:', err.message);
  });
});

// Broadcast JPEG frames to all active clients
function broadcastJpegFrame(jpegBuffer) {
  lastJpegFrame = jpegBuffer;

  // WebSockets: Zero-latency drop-late-frames strategy (128KB allows max 1 queued frame)
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      if (client.bufferedAmount < 131072) {
        client.send(jpegBuffer, { binary: true }, () => {});
      }
    }
  }

  // Fallback MJPEG Clients
  if (mjpegClients.size > 0) {
    const header = Buffer.from(
      `--myboundary\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpegBuffer.length}\r\n\r\n`
    );
    const footer = Buffer.from('\r\n');
    for (const res of mjpegClients) {
      try {
        res.write(header);
        res.write(jpegBuffer);
        res.write(footer);
      } catch (_) {}
    }
  }
}

// Spawn Native Host (mac_host binary)
function startNativeHost() {
  if (!fs.existsSync(NATIVE_BIN)) {
    console.error(`[Error] Native binary not found at ${NATIVE_BIN}. Run: npm run build:native`);
    process.exit(1);
  }

  console.log('[Native] Starting macOS ScreenCaptureKit and CoreGraphics engine with Metal GPU JPEG...');
  nativeProcess = spawn(NATIVE_BIN, ['--fps', '90', '--quality', '0.90', '--width', '1280', '--height', '800']);

  nativeProcess.stdin.on('error', (err) => {
    console.warn('[Native] stdin pipe notice:', err.message);
  });

  let bufferAccumulator = Buffer.alloc(0);

  nativeProcess.stdout.on('data', (chunk) => {
    bufferAccumulator = Buffer.concat([bufferAccumulator, chunk]);

    // Parse packets: [MAGIC 0xFD] [TYPE 1 byte] [LENGTH 4 bytes BE] [PAYLOAD]
    while (bufferAccumulator.length >= 6) {
      if (bufferAccumulator[0] !== 0xFD) {
        // Resync: Find next magic byte
        const magicIndex = bufferAccumulator.indexOf(0xFD);
        if (magicIndex === -1) {
          bufferAccumulator = Buffer.alloc(0);
          break;
        } else {
          bufferAccumulator = bufferAccumulator.subarray(magicIndex);
          if (bufferAccumulator.length < 6) break;
        }
      }

      const frameType = bufferAccumulator[1];
      const payloadLength = bufferAccumulator.readUInt32BE(2);
      const totalPacketSize = 6 + payloadLength;

      if (bufferAccumulator.length < totalPacketSize) {
        // Waiting for more data
        break;
      }

      const payload = bufferAccumulator.subarray(6, totalPacketSize);
      bufferAccumulator = bufferAccumulator.subarray(totalPacketSize);

      if (frameType === 0x01) {
        // JPEG Frame
        broadcastJpegFrame(payload);
      } else if (frameType === 0x02) {
        // JSON Message
        try {
          const json = JSON.parse(payload.toString('utf8'));
          if (json.type === 'brightness') {
            setTabletHardwareBrightness(json.value);
            // Broadcast brightness to all connected clients
            for (const client of wss.clients) {
              if (client.readyState === WebSocket.OPEN) {
                client.send(JSON.stringify({ type: 'brightness', value: json.value }));
              }
            }
          } else if (json.type === 'display_info') {
            currentDisplayInfo = json;
            console.log(`[Display] Active display: ${json.width}x${json.height} @ ${json.fps}fps (ID: ${json.displayID})`);
            // Broadcast display info to all clients
            for (const client of wss.clients) {
              if (client.readyState === WebSocket.OPEN) {
                client.send(JSON.stringify({
                  type: 'display_info',
                  display: json,
                  screenWidth: json.screenWidth || json.width,
                  screenHeight: json.screenHeight || json.height,
                  fps: json.fps,
                  displays: json.displays
                }));
              }
            }
          } else if (json.type === 'mac_state') {
            handleMacPowerStateChange(json.state);
          }
        } catch (e) {
          console.error('[Native] JSON parse error:', e.message);
        }
      }
    }
  });

  nativeProcess.stderr.on('data', (data) => {
    const text = data.toString().trim();
    if (text) console.log(text);
  });

  nativeProcess.on('error', (err) => {
    console.error('[Native] mac_host process error:', err.message);
    superviseNativeHost();
  });

  nativeProcess.on('exit', (code, signal) => {
    console.log(`[Native] mac_host exited with code ${code}, signal ${signal}`);
    nativeProcess = null;
    superviseNativeHost();
  });
}

let isShuttingDown = false;
let isRestartingNative = false;
let nativeRestartTimer = null;

function superviseNativeHost() {
  if (isShuttingDown || isRestartingNative) return;
  isRestartingNative = true;
  console.warn('[Supervisor] mac_host process terminated. Auto-recovering in 1000ms...');
  if (nativeRestartTimer) clearTimeout(nativeRestartTimer);
  nativeRestartTimer = setTimeout(() => {
    isRestartingNative = false;
    if (!isShuttingDown) {
      startNativeHost();
    }
  }, 1000);
}

// Cleanup on shutdown
function cleanup() {
  isShuttingDown = true;
  if (nativeRestartTimer) clearTimeout(nativeRestartTimer);
  console.log('\n[Shutdown] Stopping server and native processes...');
  if (nativeProcess) {
    nativeProcess.kill('SIGINT');
    nativeProcess = null;
  }
  wss.close();
  server.close(() => {
    console.log('[Shutdown] Server stopped successfully.');
    process.exit(0);
  });
}

process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

// Automated ADB Reconnect Watcher
function startAdbWatcher() {
  const { exec } = require('child_process');
  let isReverseActive = false;

  setInterval(() => {
    exec('adb devices', (err, stdout) => {
      if (err) return;
      const lines = stdout.split('\n').filter(l => l.includes('\tdevice'));
      if (lines.length > 0) {
        if (!isReverseActive) {
          exec(`adb reverse tcp:${PORT} tcp:${PORT}`, (rErr) => {
            if (!rErr) {
              isReverseActive = true;
              console.log(`[ADB] ⚡ Tablet connected via USB! Auto-reversed port ${PORT}.`);
              
              // Wake tablet screen if asleep
              exec('adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1', () => {});
              exec('adb shell wm dismiss-keyguard >/dev/null 2>&1', () => {});

              // Enable system immersive mode (hides system status & navigation bars)
              exec('adb shell "settings put global policy_control immersive.full=*" >/dev/null 2>&1', () => {});
              exec('adb shell "settings put global policy_control immersive.navigation=*" >/dev/null 2>&1', () => {});

              // Keep screen awake permanently while Android Duo is connected
              exec('adb shell settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1', () => {});
              exec('adb shell svc power stayon true >/dev/null 2>&1', () => {});
              exec('adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1', () => {});

              // 1. Check if any client is already actively connected over WebSocket (e.g. streaming over Wi-Fi)
              const hasActiveClients = Array.from(wss.clients).some(c => c.readyState === WebSocket.OPEN);
              if (hasActiveClients) {
                console.log(`[ADB] 📱 Client is already active (${wss.clients.size} connected). Upgrading connection to USB without opening new page.`);
                for (const client of wss.clients) {
                  if (client.readyState === WebSocket.OPEN) {
                    client.send(JSON.stringify({ type: 'usb_connected', port: PORT }));
                  }
                }
                return;
              }

              // 2. Check if client disconnected very recently (during cable unplug/replug handover)
              if (Date.now() - lastClientDisconnectTime < 15000) {
                console.log(`[ADB] 📱 Client was connected recently (${Math.round((Date.now() - lastClientDisconnectTime)/1000)}s ago). Reusing existing page without re-launching.`);
                return;
              }

              // 3. No active client and not a recent handover -> Automatically launch browser on tablet
              console.log(`[ADB] 🚀 Auto-launching full-screen browser on tablet: http://localhost:${PORT}/?pwa=1`);
              exec(`adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main -a android.intent.action.VIEW -d "http://localhost:${PORT}/?pwa=1" >/dev/null 2>&1`, (launchErr) => {
                if (launchErr) {
                  exec(`adb shell am start -a android.intent.action.VIEW -d "http://localhost:${PORT}/?pwa=1" >/dev/null 2>&1`, () => {});
                }
                // Send F11 keycode (141) to trigger fullscreen in supported browsers
                setTimeout(() => {
                  exec('adb shell input keyevent 141 >/dev/null 2>&1', () => {}); // F11
                }, 1000);
              });
            }
          });
        }
      } else {
        isReverseActive = false;
      }
    });
  }, 1500);
}

// Smart Mac Sleep, Lid Close & Lock Screen Watcher
let isMacAsleep = false;

function handleMacPowerStateChange(state) {
  const { exec } = require('child_process');

  if (state === 'sleep' || state === 'lock') {
    if (isMacAsleep) return;
    isMacAsleep = true;
    console.log(`[Power] 🌙 Mac entered ${state} state. Minimizing tablet app to Home Screen...`);

    // 1. Broadcast to tablet client to drop WakeLock and blank canvas
    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({ type: 'mac_state', state: 'sleep' }));
      }
    }

    // 2. Minimize Android app / return to Home Screen
    exec('adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1', () => {});
  } else if (state === 'wake' || state === 'unlock') {
    if (!isMacAsleep) return;
    isMacAsleep = false;
    console.log(`[Power] ☀️ Mac woke up / unlocked (${state}). Restoring tablet app...`);

    // 1. Wake tablet display & dismiss lockscreen
    exec('adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1', () => {});
    exec('adb shell wm dismiss-keyguard >/dev/null 2>&1', () => {});
    exec('adb shell "settings put global policy_control immersive.full=*" >/dev/null 2>&1', () => {});
    exec('adb shell "settings put global policy_control immersive.navigation=*" >/dev/null 2>&1', () => {});

    // 2. Bring Android Duo / Chrome back to front without reloading
    exec(`adb shell am start -n com.android.chrome/com.google.android.apps.chrome.Main -a android.intent.action.VIEW -d "http://localhost:${PORT}/?pwa=1" >/dev/null 2>&1`, (launchErr) => {
      if (launchErr) {
        exec(`adb shell am start -a android.intent.action.VIEW -d "http://localhost:${PORT}/?pwa=1" >/dev/null 2>&1`, () => {});
      }
    });

    // 3. Notify clients to re-acquire WakeLock and resume stream
    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({ type: 'mac_state', state: 'wake' }));
      }
    }

    // 4. Request fresh screen frame
    sendToNative({ type: 'request_frame' });
  }
}

function startPowerWatcher() {
  const { exec } = require('child_process');
  let lastLidClosed = false;
  let lastHeartbeat = Date.now();

  // Hardware Clamshell (Lid) Watcher via ioreg
  setInterval(() => {
    exec('ioreg -r -n IOPMrootDomain | grep -i AppleClamshellState', (err, stdout) => {
      if (err || !stdout) return;
      const isClosed = stdout.includes('Yes');
      if (isClosed !== lastLidClosed) {
        lastLidClosed = isClosed;
        if (isClosed) {
          console.log('[Power] 💻 MacBook lid closed.');
          handleMacPowerStateChange('sleep');
        } else {
          console.log('[Power] 💻 MacBook lid opened.');
          handleMacPowerStateChange('wake');
        }
      }
    });
  }, 2000);

  // Deep sleep timer drift detector
  setInterval(() => {
    const now = Date.now();
    const elapsed = now - lastHeartbeat;
    lastHeartbeat = now;
    if (elapsed > 4000) {
      console.log(`[Power] ⏰ System woke up from deep sleep (timer gap: ${Math.round(elapsed/1000)}s).`);
      handleMacPowerStateChange('wake');
    }
  }, 1000);
}

// Start server
server.listen(PORT, '0.0.0.0', () => {
  const ips = getLocalIPs();
  const primaryIP = ips[0] ? ips[0].address : 'localhost';
  const url = `http://${primaryIP}:${PORT}`;

  console.log('\n============================================================');
  console.log('  🚀 Android Duo — macOS Screen & Touchpad Server is Ready!');
  console.log('============================================================\n');

  console.log(`  🌐 Wi-Fi / Local Network URL: \x1b[36m${url}\x1b[0m`);
  ips.forEach((iface) => {
    console.log(`     • ${iface.name}: http://${iface.address}:${PORT}`);
  });

  console.log('\n  ⚡ Ultra-Fast USB Mode (Zero Latency via ADB):');
  console.log(`     1. Connect tablet via USB-C`);
  console.log(`     2. Run in terminal: \x1b[33madb reverse tcp:${PORT} tcp:${PORT}\x1b[0m`);
  console.log(`     3. Open on tablet browser: \x1b[32mhttp://localhost:${PORT}\x1b[0m\n`);

  console.log('  📱 Scan with your Xiaomi/HyperOS Tablet Camera:');
  qrcode.generate(url, { small: true });

  console.log('============================================================\n');

  startNativeHost();
  startAdbWatcher();
  startPowerWatcher();
  setInterval(broadcastBattery, 10000);
});
