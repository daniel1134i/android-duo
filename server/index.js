const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, exec } = require('child_process');
const { WebSocketServer, WebSocket } = require('ws');
const qrcode = require('qrcode-terminal');

const PORT = parseInt(process.env.PORT, 10) || 3000;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const NATIVE_BIN = path.join(__dirname, '..', 'native', 'mac_host');
const CONFIG_FILE = path.join(os.homedir(), '.android_duo_config.json');

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
    }
  } catch (e) {
    console.error('[Config] Failed to load config:', e.message);
  }
  return { tabletLaunchTarget: 'native' };
}

function saveConfig(cfg) {
  try {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), 'utf8');
  } catch (e) {
    console.error('[Config] Failed to save config:', e.message);
  }
}

let appConfig = loadConfig();
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

// Hardware Clamshell (Lid) State Inspector
function checkIsLidClosedSync() {
  try {
    const { execSync } = require('child_process');
    const out = execSync('ioreg -r -n IOPMrootDomain | grep -i AppleClamshellState', { timeout: 350 }).toString();
    return out.includes('Yes');
  } catch (_) {
    return false;
  }
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
let isScreenCaptureGranted = null;
let isAdbDeviceConnected = false;
let isAdbReverseActive = false;
let usbMigrateFallbackTimer = null;

function getClientIp(req) {
  let ip = req.socket ? req.socket.remoteAddress : '';
  if (!ip) return 'unknown';
  if (ip.startsWith('::ffff:')) ip = ip.substring(7);
  if (ip === '::1') ip = '127.0.0.1';
  return ip;
}

function isUsbIp(ip) {
  return ip === '127.0.0.1' || ip === 'localhost';
}

function getActiveTransport() {
  if (!wss || wss.clients.size === 0) return 'none';
  let hasWifi = false;
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      if (client.isUsb) return 'usb';
      hasWifi = true;
    }
  }
  return hasWifi ? 'wifi' : 'none';
}

function setTabletHardwareBrightness(val) {
  currentBrightness = Math.max(0.05, Math.min(1.0, val));
  if (adbBrightnessTimeout) clearTimeout(adbBrightnessTimeout);
  adbBrightnessTimeout = setTimeout(() => {
    const val255 = Math.round(currentBrightness * 255);
    const valFloat = currentBrightness.toFixed(3);
    const { exec } = require('child_process');
    exec(`adb shell "settings put system screen_brightness ${val255}; settings put system screen_brightness_float ${valFloat}" >/dev/null 2>&1`, () => {});
  }, 80);
}

// Tablet Hardware Display Refresh Rate Control (Optimization 5)
let currentTabletFpsSetting = 90;

function setTabletHardwareRefreshRate(fps) {
  const target = parseInt(fps, 10) || 90;
  currentTabletFpsSetting = target;
  // If target <= 60 FPS, drop hardware display refresh rate to 60 Hz to conserve battery and GPU power.
  // If target > 60 FPS (e.g. 90 FPS), unlock 90 Hz for ultra-smoothness.
  const rate = target > 60 ? '90.0' : '60.0';
  const { exec } = require('child_process');
  exec(`adb shell "settings put system peak_refresh_rate ${rate}; settings put system min_refresh_rate 60.0" >/dev/null 2>&1`, (err) => {
    if (!err) {
      console.log(`[Display] ⚡ Tablet display hardware refresh rate synced: ${rate} Hz (Target FPS: ${target})`);
    }
  });
}

// Battery Monitoring (Mac + Tablet)
let currentBattery = {
  mac: { level: null, charging: false },
  tablet: { level: null, charging: false }
};

function checkBatteryStatus(callback) {
  const { exec } = require('child_process');
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
    const transport = getActiveTransport();
    const localIps = getLocalIPs();
    res.end(JSON.stringify({
      ips: localIps,
      serverIps: localIps.map(i => i.address),
      port: PORT,
      display: currentDisplayInfo,
      battery: currentBattery,
      connectedClients: wss ? wss.clients.size : 0,
      screenCaptureGranted: isScreenCaptureGranted,
      transport: transport,
      adbConnected: isAdbDeviceConnected,
      adbReverseActive: isAdbReverseActive,
      clients: Array.from(wss ? wss.clients : []).filter(c => c.readyState === WebSocket.OPEN).map(c => ({
        ip: c.clientIp || 'unknown',
        isUsb: !!c.isUsb
      }))
    }));
    return;
  }

  // REST API: Power State Control (Sleep / Wake / Lid)
  if (req.url.startsWith('/api/power')) {
    const urlObj = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const state = urlObj.searchParams.get('state');
    if (state === 'sleep' || state === 'wake' || state === 'unlock') {
      handleMacPowerStateChange(state);
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, state: state }));
    return;
  }

  // REST API: Change Resolution
  if (req.url.startsWith('/api/resolution')) {
    const urlObj = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const width = parseInt(urlObj.searchParams.get('width'), 10);
    const height = parseInt(urlObj.searchParams.get('height'), 10);
    if (!isNaN(width) && !isNaN(height) && width > 0 && height > 0) {
      console.log(`[Display] REST request to change resolution: ${width}x${height}`);
      currentDisplayInfo.width = width;
      currentDisplayInfo.height = height;
      currentDisplayInfo.screenWidth = width;
      currentDisplayInfo.screenHeight = height;
      sendToNative({ type: 'set_resolution', width, height });
      for (const client of wss.clients) {
        if (client.readyState === WebSocket.OPEN) {
          try {
            client.send(JSON.stringify({
              type: 'display_info',
              width,
              height,
              screenWidth: width,
              screenHeight: height,
              fps: currentDisplayInfo.fps || 90
            }));
          } catch (_) {}
        }
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, width, height }));
      return;
    }
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Invalid width or height' }));
    return;
  }

  // REST API: Launch Target Settings
  if (req.url.startsWith('/api/tablet/launch-target')) {
    const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const newTarget = parsedUrl.searchParams.get('target');
    if (newTarget && ['native', 'fully', 'webapk', 'browser'].includes(newTarget)) {
      appConfig.tabletLaunchTarget = newTarget;
      saveConfig(appConfig);
      console.log(`[Config] 🎯 Tablet launch target set to: ${newTarget}`);
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, target: appConfig.tabletLaunchTarget || 'native' }));
    return;
  }

  // REST API: Launch Tablet App
  if (req.url.startsWith('/api/launch')) {
    const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const targetOverride = parsedUrl.searchParams.get('target');
    launchTabletApp(null, targetOverride);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, target: targetOverride || appConfig.tabletLaunchTarget || 'native' }));
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
      'Cache-Control': 'no-cache, no-store, must-revalidate'
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

wss.on('headers', (headers, req) => {
  headers.push('Access-Control-Allow-Origin: *');
  headers.push('Access-Control-Allow-Headers: *');
  headers.push('Access-Control-Allow-Private-Network: true');
});

wss.on('connection', (ws, req) => {
  if (req.socket) {
    req.socket.setNoDelay(true);
    req.socket.setKeepAlive(true, 10000);
  }
  if (ws._socket) {
    ws._socket.setNoDelay(true);
  }

  const ip = getClientIp(req);
  ws.clientIp = ip;
  ws.isUsb = isUsbIp(ip);
  if (ws.isUsb && usbMigrateFallbackTimer) {
    clearTimeout(usbMigrateFallbackTimer);
    usbMigrateFallbackTimer = null;
  }
  console.log(`[WebSocket] Client connected from ${ip} (Channel: ${ws.isUsb ? '⚡ USB' : '📶 Wi-Fi'})`);

  // Send initial display info matching client expectations with Wi-Fi fallback IPs
  const localIps = getLocalIPs();
  const initialTargetFps = ws.isUsb ? 90 : 60;
  ws.send(JSON.stringify({
    type: 'init',
    screenWidth: currentDisplayInfo.width,
    screenHeight: currentDisplayInfo.height,
    fps: initialTargetFps,
    port: PORT,
    serverIps: localIps.map(i => i.address),
    wifiIps: localIps.map(i => i.address),
    wifiUrls: localIps.map(i => `http://${i.address}:${PORT}`),
    usbAvailable: isAdbReverseActive,
    adbConnected: isAdbDeviceConnected,
    adbReverseActive: isAdbReverseActive,
    isUsbClient: ws.isUsb,
    brightness: currentBrightness,
    isMacAsleep: isMacAsleep,
    displays: currentDisplayInfo.displays || [{
      id: currentDisplayInfo.displayID || 0,
      name: 'macOS Display',
      width: currentDisplayInfo.width,
      height: currentDisplayInfo.height,
      primary: true
    }]
  }));

  // Automatically adapt hardware display refresh rate: 90 Hz for USB, 60 Hz for Wi-Fi
  setTabletHardwareRefreshRate(initialTargetFps);
  sendToNative({ type: 'config', fps: initialTargetFps, quality: 0.90 });

  // Explicitly inform client of current power state and immediately supply last frame
  ws.send(JSON.stringify({ type: 'mac_state', state: isMacAsleep ? 'sleep' : 'wake' }));
  if (!isMacAsleep && lastJpegFrame) {
    ws.send(lastJpegFrame, { binary: true });
  }

  // If a client connects from Wi-Fi but USB tunnel is ready, immediately prompt upgrade to USB
  if (!ws.isUsb && isAdbReverseActive) {
    console.log(`[WebSocket] Wi-Fi client (${ip}) connected while USB reverse tunnel is active. Prompting upgrade.`);
    ws.send(JSON.stringify({
      type: 'usb_status',
      available: true,
      port: PORT,
      localUrl: `http://localhost:${PORT}/?pwa=1`
    }));
    ws.send(JSON.stringify({
      type: 'usb_connected',
      port: PORT,
      url: `http://localhost:${PORT}/?pwa=1`
    }));
  }

  // Send latest frame immediately if available, and request fresh capture from native host
  if (lastJpegFrame) {
    ws.send(lastJpegFrame, { binary: true });
  }
  sendToNative({ type: 'request_frame' });

  // Send battery status immediately on connection
  broadcastBattery();

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
          serverTime: Date.now(),
          usbAvailable: isAdbReverseActive
        }));
        return;
      }

      // Handle dynamic client settings (quality, fps, display switching)
      if (msg.type === 'settings' || msg.type === 'config') {
        if (msg.isUsb !== undefined) {
          ws.isUsb = !!msg.isUsb;
        }
        if (msg.host) {
          ws.clientHost = msg.host;
        }
        const qMap = { low: 0.65, med: 0.80, high: 0.90, ultra: 0.95 };
        const quality = typeof msg.quality === 'string' ? (qMap[msg.quality] || 0.90) : (msg.quality || 0.90);
        let fps = parseInt(msg.targetFps || msg.fps, 10) || (ws.isUsb ? 90 : 60);

        // Clamp FPS based on transport:
        // Wi-Fi: maximum 60 FPS & 60 Hz to avoid latency and packet congestion
        // USB: maximum 90 FPS & 90 Hz
        if (!ws.isUsb && fps > 60) {
          fps = 60;
        }

        console.log(`[Settings] Updated by client (${ws.isUsb ? '⚡ USB' : '📶 Wi-Fi'}): FPS=${fps}, Quality=${quality}`);
        setTabletHardwareRefreshRate(fps);
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
          currentDisplayInfo.width = width;
          currentDisplayInfo.height = height;
          currentDisplayInfo.screenWidth = width;
          currentDisplayInfo.screenHeight = height;
          sendToNative({ type: 'set_resolution', width, height });
          for (const client of wss.clients) {
            if (client.readyState === WebSocket.OPEN) {
              try {
                client.send(JSON.stringify({
                  type: 'display_info',
                  width,
                  height,
                  screenWidth: width,
                  screenHeight: height,
                  fps: currentDisplayInfo.fps || 90
                }));
              } catch (_) {}
            }
          }
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
  if (isMacAsleep) {
    // NEVER broadcast screen frames when Mac is asleep or lid is closed!
    return;
  }
  lastJpegFrame = jpegBuffer;

  // WebSockets: Zero-latency drop-late-frames strategy (32KB prevents bufferbloat & eliminates ping spikes)
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) {
      if (client.bufferedAmount < 32768) {
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
        // JPEG Frame - screen capture is active and working
        isScreenCaptureGranted = true;
        nativeFailures = 0;
        broadcastJpegFrame(payload);
      } else if (frameType === 0x02) {
        // JSON Message
        try {
          const json = JSON.parse(payload.toString('utf8'));
          if (json.type === 'brightness') {
            const bVal = parseFloat(json.value);
            if (!isNaN(bVal)) {
              currentBrightness = Math.max(0.05, Math.min(1.0, bVal));
              setTabletHardwareBrightness(currentBrightness);
              // Broadcast brightness to all connected clients
              for (const client of wss.clients) {
                if (client.readyState === WebSocket.OPEN) {
                  client.send(JSON.stringify({ type: 'brightness', value: currentBrightness }));
                }
              }
            }
          } else if (json.type === 'display_info') {
            currentDisplayInfo = json;
            isScreenCaptureGranted = true;
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
    if (text) {
      console.log(text);
      if (!isMacAsleep && (text.includes('Screen Recording permission is NOT active') || text.includes('TCC Error') || text.includes('TCC Notice'))) {
        isScreenCaptureGranted = false;
      }
    }
  });

  nativeProcess.on('error', (err) => {
    console.error('[Native] mac_host process error:', err.message);
    superviseNativeHost(false);
  });

  nativeProcess.on('exit', (code, signal) => {
    console.log(`[Native] mac_host exited with code ${code}, signal ${signal}`);
    const isPermissionError = (code === 2) && !isMacAsleep;
    if (isPermissionError) {
      isScreenCaptureGranted = false;
    }
    nativeProcess = null;
    superviseNativeHost(isPermissionError);
  });
}

let isShuttingDown = false;
let isRestartingNative = false;
let nativeRestartTimer = null;
let nativeFailures = 0;

function superviseNativeHost(isPermissionError = false) {
  if (isShuttingDown || isRestartingNative) return;
  isRestartingNative = true;
  nativeFailures++;
  
  const delay = isPermissionError ? 5000 : (nativeFailures > 2 ? 6000 : 2000);
  if (isPermissionError) {
    console.warn(`[Supervisor] Screen recording permission required. Checking again in ${delay}ms...`);
  } else {
    console.warn(`[Supervisor] mac_host process terminated. Auto-recovering in ${delay}ms (failures: ${nativeFailures})...`);
  }
  if (nativeRestartTimer) clearTimeout(nativeRestartTimer);
  nativeRestartTimer = setTimeout(() => {
    isRestartingNative = false;
    if (!isShuttingDown) {
      startNativeHost();
    }
  }, delay);
}

// Cleanup on shutdown
let isCleaningUp = false;
function cleanup() {
  if (isCleaningUp) return;
  isCleaningUp = true;
  isShuttingDown = true;
  if (nativeRestartTimer) clearTimeout(nativeRestartTimer);
  if (usbMigrateFallbackTimer) clearTimeout(usbMigrateFallbackTimer);
  console.log('\n[Shutdown] Stopping server and native processes...');
  if (nativeProcess) {
    try {
      nativeProcess.kill('SIGKILL');
    } catch (e) {}
    nativeProcess = null;
  }
  // Hard exit timeout after 200ms in case sockets don't close
  const forceExitTimer = setTimeout(() => {
    process.exit(0);
  }, 200);
  if (forceExitTimer.unref) forceExitTimer.unref();

  try {
    if (wss && wss.clients) {
      for (const client of wss.clients) {
        try { client.terminate(); } catch (e) {}
      }
      wss.close();
    }
  } catch (e) {}

  try {
    if (typeof server.closeAllConnections === 'function') {
      server.closeAllConnections();
    }
    server.close(() => {
      console.log('[Shutdown] Server stopped successfully.');
      process.exit(0);
    });
  } catch (e) {
    process.exit(0);
  }
}

process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);
process.on('SIGHUP', cleanup);

// Automated ADB Reconnect Watcher
function startAdbWatcher() {
  const { exec } = require('child_process');

  function broadcastUsbStatus(available) {
    const statusPayload = JSON.stringify({
      type: 'usb_status',
      available: available,
      port: PORT,
      localUrl: `http://127.0.0.1:${PORT}/?pwa=1`
    });
    const connPayload = available ? JSON.stringify({
      type: 'usb_connected',
      port: PORT,
      url: `http://127.0.0.1:${PORT}/?pwa=1`,
      host: '127.0.0.1',
      force: true
    }) : null;
    const switchPayload = available ? JSON.stringify({
      type: 'switch_to_usb',
      port: PORT,
      url: `http://127.0.0.1:${PORT}/?pwa=1`,
      host: '127.0.0.1',
      force: true
    }) : null;

    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        try {
          client.send(statusPayload);
          if (available && !client.isUsb) {
            if (connPayload) client.send(connPayload);
            if (switchPayload) client.send(switchPayload);
          }
        } catch (_) {}
      }
    }
  }

  function onAdbReverseSuccess() {
    isAdbReverseActive = true;
    console.log(`[ADB] ⚡ Tablet connected via USB! Auto-reversed port ${PORT}.`);

    // If Mac is asleep or lid is closed, do NOT wake tablet screen or launch app!
    if (isMacAsleep || checkIsLidClosedSync()) {
      console.log('[ADB] 💤 Mac is asleep or lid is closed. Skipping tablet wakeup.');
      broadcastUsbStatus(true);
      return;
    }

    // Wake tablet screen if asleep
    exec('adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1', () => {});
    exec('adb shell wm dismiss-keyguard >/dev/null 2>&1', () => {});

    // Enable system immersive mode (hides system status & navigation bars)
    exec('adb shell "settings put global policy_control immersive.full=*" >/dev/null 2>&1', () => {});
    exec('adb shell "settings put global policy_control immersive.navigation=*" >/dev/null 2>&1', () => {});

    // Keep screen awake while connected via USB
    exec('adb shell "settings put global stay_on_while_plugged_in 7; svc power stayon true" >/dev/null 2>&1', () => {});

    // Sync tablet display refresh rate with current FPS setting
    setTabletHardwareRefreshRate(currentTabletFpsSetting);

    // Broadcast USB available status immediately, and repeated after 400ms and 1200ms
    broadcastUsbStatus(true);
    setTimeout(() => broadcastUsbStatus(true), 400);
    setTimeout(() => broadcastUsbStatus(true), 1200);

    // Check if we have active clients
    let hasUsbClient = false;
    let hasWifiClient = false;
    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        if (client.isUsb) hasUsbClient = true;
        else hasWifiClient = true;
      }
    }

    if (usbMigrateFallbackTimer) {
      clearTimeout(usbMigrateFallbackTimer);
      usbMigrateFallbackTimer = null;
    }

    const usbUrl = `http://127.0.0.1:${PORT}/?pwa=1`;

    if (!hasUsbClient && !hasWifiClient) {
      console.log(`[ADB] 🚀 No active clients, auto-launching tablet app: ${usbUrl}`);
      launchTabletApp(usbUrl);
    } else if (hasWifiClient && !hasUsbClient) {
      // Wi-Fi client is active: allow 1.5s for seamless in-page migration or client redirect.
      usbMigrateFallbackTimer = setTimeout(() => {
        usbMigrateFallbackTimer = null;
        let usbNow = false;
        for (const client of wss.clients) {
          if (client.readyState === WebSocket.OPEN && client.isUsb) {
            usbNow = true;
            break;
          }
        }
        if (!usbNow) {
          console.log(`[ADB] ⚡ Wi-Fi client did not migrate to USB within timeout. Directing tablet app to USB: ${usbUrl}`);
          for (const client of wss.clients) {
            if (client.readyState === WebSocket.OPEN && !client.isUsb) {
              try {
                client.send(JSON.stringify({
                  type: 'switch_to_usb',
                  port: PORT,
                  url: usbUrl,
                  force: true
                }));
              } catch (_) {}
            }
          }
          launchTabletApp(usbUrl);
        }
      }, 1500);
    }
  }

  setInterval(() => {
    exec('adb devices', (err, stdout) => {
      if (err) {
        if (usbMigrateFallbackTimer) {
          clearTimeout(usbMigrateFallbackTimer);
          usbMigrateFallbackTimer = null;
        }
        if (isAdbReverseActive) {
          console.log('[ADB] 🔌 USB device disconnected (adb error).');
          isAdbReverseActive = false;
          broadcastUsbStatus(false);
        }
        isAdbDeviceConnected = false;
        return;
      }

      if (stdout.includes('\toffline')) {
        console.log('[ADB] 🔄 Device is offline after sleep/wake. Running adb reconnect...');
        exec('adb reconnect offline >/dev/null 2>&1', () => {});
      }

      const lines = stdout.split('\n').filter(l => l.includes('\tdevice'));
      const devicePresent = lines.length > 0;
      isAdbDeviceConnected = devicePresent;

      if (!devicePresent) {
        if (usbMigrateFallbackTimer) {
          clearTimeout(usbMigrateFallbackTimer);
          usbMigrateFallbackTimer = null;
        }
        if (isAdbReverseActive) {
          console.log('[ADB] 🔌 USB device disconnected.');
          isAdbReverseActive = false;
          broadcastUsbStatus(false);
        }
        return;
      }

      // Device is present! Check if reverse tunnel is actually established in adb
      exec('adb reverse --list', (listErr, listStdout) => {
        const reverseIsActive = !listErr && listStdout && listStdout.includes(`tcp:${PORT}`);

        if (reverseIsActive) {
          if (!isAdbReverseActive) {
            onAdbReverseSuccess();
          } else {
            // Tunnel is ALREADY active: check if any clients are still streaming over Wi-Fi!
            let hasWifiClient = false;
            let hasUsbClient = false;
            for (const client of wss.clients) {
              if (client.readyState === WebSocket.OPEN) {
                if (client.isUsb) hasUsbClient = true;
                else hasWifiClient = true;
              }
            }
            if (hasWifiClient && !hasUsbClient) {
              // Actively push USB migration status to Wi-Fi client so it switches back
              broadcastUsbStatus(true);
            }
          }
          return;
        }

        // Tunnel is not active in adb, run adb reverse!
        exec(`adb reverse tcp:${PORT} tcp:${PORT}`, (rErr) => {
          if (rErr) {
            // If failed because address in use or stale listener, remove and retry
            exec(`adb reverse --remove tcp:${PORT}`, () => {
              exec(`adb reverse tcp:${PORT} tcp:${PORT}`, (retryErr) => {
                if (!retryErr) {
                  onAdbReverseSuccess();
                }
              });
            });
            return;
          }
          onAdbReverseSuccess();
        });
      });
    });
  }, 1000);
}

// App Launch Automation for Xiaomi Pad (Native App, Fully Kiosk, WebAPK, or Browser)
function launchTabletApp(url, targetOverride) {
  const targetUrl = url || `http://127.0.0.1:${PORT}/?pwa=1`;
  const target = targetOverride || appConfig.tabletLaunchTarget || 'native';
  const { exec } = require('child_process');

  if (target === 'native') {
    // Check if native Android Duo client is installed
    exec('adb shell pm list packages com.androidduo.client 2>/dev/null', (err, stdout) => {
      if (!err && stdout && stdout.includes('com.androidduo.client')) {
        console.log('[ADB] ⚡ Launching native Android Duo client (com.androidduo.client)');
        exec(`adb shell am start -n com.androidduo.client/.MainActivity --es url "${targetUrl}" >/dev/null 2>&1`, () => {});
      } else {
        console.log('[ADB] ⚠️ Native client not found, falling back to WebAPK/Browser');
        launchFallbackTabletApp(targetUrl);
      }
    });
  } else if (target === 'fully') {
    // Check if Fully Kiosk is installed
    exec('adb shell pm list packages de.ozerov.fully 2>/dev/null', (err, stdout) => {
      if (!err && stdout && stdout.includes('de.ozerov.fully')) {
        console.log('[ADB] 🖥 Launching Fully Kiosk Browser');
        exec(`adb shell am broadcast -a de.ozerov.fully.action.loadurl --es url "${targetUrl}" >/dev/null 2>&1`, () => {
          exec('adb shell am start -n de.ozerov.fully/.MainActivity >/dev/null 2>&1', () => {});
        });
      } else {
        console.log('[ADB] ⚠️ Fully Kiosk not found, falling back to WebAPK/Browser');
        launchFallbackTabletApp(targetUrl);
      }
    });
  } else if (target === 'webapk') {
    launchWebApkTabletApp(targetUrl);
  } else {
    console.log(`[ADB] 🌐 Launching via default browser intent: ${targetUrl}`);
    exec(`adb shell am start -a android.intent.action.VIEW -d "${targetUrl}" >/dev/null 2>&1`, () => {});
  }
}

function launchFallbackTabletApp(targetUrl) {
  launchWebApkTabletApp(targetUrl);
}

function launchWebApkTabletApp(targetUrl) {
  const { exec } = require('child_process');
  exec('adb shell pm list packages org.chromium.webapk 2>/dev/null', (pErr, pStdout) => {
    if (!pErr && pStdout && pStdout.includes('org.chromium.webapk')) {
      const lines = pStdout.trim().split('\n');
      const pkg = lines[0].replace('package:', '').trim();
      console.log(`[ADB] 📱 Launching installed Android Duo WebAPK: ${pkg}`);
      exec(`adb shell monkey -p ${pkg} 1 >/dev/null 2>&1`, () => {});
    } else {
      console.log(`[ADB] 🌐 Launching via browser intent: ${targetUrl}`);
      exec(`adb shell am start -a android.intent.action.VIEW -d "${targetUrl}" >/dev/null 2>&1`, () => {});
    }
  });
}

// Smart Mac Sleep, Lid Close & Lock Screen Watcher
let isMacAsleep = false;

function handleMacPowerStateChange(state) {
  const { exec } = require('child_process');

  if (state === 'sleep') {
    if (isMacAsleep) return;
    isMacAsleep = true;
    lastJpegFrame = null;
    console.log(`[Power] 🌙 Mac entered sleep state / lid closed. Extinguishing tablet display...`);

    // 1. Broadcast to tablet client to drop WakeLock and activate sleep screen curtain
    for (const client of wss.clients) {
      if (client.readyState === WebSocket.OPEN) {
        try {
          client.send(JSON.stringify({ type: 'mac_state', state: 'sleep' }));
        } catch (_) {}
      }
    }

    // 2. Extinguish tablet display hardware:
    // Reset stay_on_while_plugged_in to 0 so USB power doesn't prevent screen off
    // Set screen_off_timeout to 15000 (15 seconds) so Android's native timer turns off screen
    exec('adb shell "settings put global stay_on_while_plugged_in 0; svc power stayon false; settings put system screen_off_timeout 15000" >/dev/null 2>&1', () => {
      // Query screen state: if awake, send KEYCODE_POWER (26) to extinguish screen immediately!
      exec('adb shell "dumpsys display | grep mScreenState || dumpsys power | grep mWakefulness" 2>/dev/null', (err, stdout) => {
        const isAwake = !stdout || stdout.includes('ON') || stdout.includes('Awake') || stdout.includes('VR');
        if (isAwake) {
          exec('adb shell input keyevent 26 >/dev/null 2>&1', () => {});
        }
      });
    });
  } else if (state === 'wake' || state === 'unlock') {
    if (checkIsLidClosedSync()) {
      console.log('[Power] 🛑 Ignore wake: MacBook lid is still closed (AppleClamshellState = Yes).');
      return;
    }
    isMacAsleep = false;
    console.log(`[Power] ☀️ Mac woke up / lid opened (${state}). Restoring tablet display...`);

    // 1. Wake tablet display hardware and restore brightness/timeout settings
    const wakeCmd = 'settings put global stay_on_while_plugged_in 7; svc power stayon true; settings put system screen_off_timeout 30000; settings put global policy_control immersive.full=*; settings put global policy_control immersive.navigation=*; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard';
    exec(`adb shell "${wakeCmd}" >/dev/null 2>&1`, () => {
      exec('adb shell "dumpsys display | grep mScreenState || dumpsys power | grep mWakefulness" 2>/dev/null', (err, stdout) => {
        const isOff = stdout && (stdout.includes('OFF') || stdout.includes('Asleep') || stdout.includes('Dozing'));
        if (isOff) {
          exec('adb shell "input keyevent 26; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null 2>&1', () => {});
        }
      });
    });

    // Restore tablet hardware display refresh rate
    setTabletHardwareRefreshRate(currentTabletFpsSetting);

    // 2. Immediately launch / bring tablet app to foreground
    launchTabletApp();

    // 3. Broadcast wake event to all connected clients (immediately, and repeated after 500ms, 1200ms)
    const broadcastWake = () => {
      for (const client of wss.clients) {
        if (client.readyState === WebSocket.OPEN) {
          try {
            client.send(JSON.stringify({ type: 'mac_state', state: 'wake' }));
            if (lastJpegFrame) {
              client.send(lastJpegFrame, { binary: true });
            }
          } catch (_) {}
        }
      }
    };
    broadcastWake();
    setTimeout(broadcastWake, 500);
    setTimeout(broadcastWake, 1200);

    // 4. Ensure native capture engine is alive and request fresh frame
    if (!nativeProcess) {
      console.log('[Power] mac_host not running on wake. Starting native host immediately...');
      startNativeHost();
    } else {
      sendToNative({ type: 'wake' });
    }
    sendToNative({ type: 'request_frame' });
    setTimeout(() => sendToNative({ type: 'request_frame' }), 600);
    setTimeout(() => sendToNative({ type: 'request_frame' }), 1500);
  }
}

function startPowerWatcher() {
  const { exec } = require('child_process');
  let lastLidClosed = checkIsLidClosedSync();
  let lastHeartbeat = Date.now();

  // Snappy Hardware Clamshell (Lid) Watcher via ioreg (400ms polling)
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
  }, 400);

  // Deep sleep timer drift detector (protect against false wake during macOS DarkWake / Power Nap)
  setInterval(() => {
    const now = Date.now();
    const elapsed = now - lastHeartbeat;
    lastHeartbeat = now;
    if (elapsed > 3000) {
      if (checkIsLidClosedSync()) {
        console.log(`[Power] 💤 Maintenance tick during clamshell sleep (timer gap: ${Math.round(elapsed/1000)}s) — lid closed, tablet remains asleep.`);
        return;
      }
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
