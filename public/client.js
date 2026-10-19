/**
 * DuoDisplay - Android / HyperOS Tablet Web Client
 * High-performance remote display, touch gesture engine, and keyboard bridge for macOS.
 */

(function () {
  'use strict';

  // ============================================================================
  // Global State & Configuration
  // ============================================================================
  const state = {
    // Connection & Multi-Endpoint Failover (USB <-> Wi-Fi)
    ws: null,
    connected: false,
    activeHost: location.host || 'localhost:3000',
    candidateHosts: [],
    candidateIndex: 0,
    wifiIps: [],
    serverPort: 3000,
    transport: 'usb',
    reconnectAttempts: 0,
    reconnectTimer: null,
    maxReconnectDelay: 4000,
    pingInterval: null,
    lastPingTimestamp: 0,
    lastPongTimestamp: 0,
    latency: 0,

    // Stream & Display
    quality: 'high',       // 'low' | 'med' | 'high'
    targetFps: 90,         // 30 | 60 | 90
    scaleMode: 'fill',     // 'fit' | 'fill'
    selectedDisplay: null, // set dynamically from display_info
    remoteWidth: 1280,
    remoteHeight: 800,
    renderMetrics: {
      scale: 1,
      offsetX: 0,
      offsetY: 0,
      renderWidth: 0,
      renderHeight: 0
    },

    // FPS calculation
    fps: 0,
    frameCount: 0,
    lastFpsUpdateTime: performance.now(),

    // Touch & Input Mode (Default: Disabled / View-Only external monitor)
    touchEnabled: false,
    mode: 'off',           // 'direct' | 'trackpad' | 'off'
    savedActiveMode: 'direct',
    trackpadSensitivity: 1.4,
    scrollSensitivity: 1.2,

    // Active sticky modifiers (toggled via UI buttons)
    modifiers: {
      cmd: false,
      opt: false,
      ctrl: false,
      shift: false
    },

    // WakeLock
    wakeLock: null,
    wakeLockRequested: false,

    // Toolbar UI state
    toolbarExpanded: false
  };

  // ============================================================================
  // DOM Elements
  // ============================================================================
  const canvas = document.getElementById('screen-canvas');
  const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
  const canvasContainer = document.getElementById('canvas-container');
  const touchIndicator = document.getElementById('touch-indicator');
  const longpressIndicator = document.getElementById('longpress-indicator');
  const hiddenInput = document.getElementById('hidden-keyboard-input');
  const toastBanner = document.getElementById('toast-banner');
  const toastText = document.getElementById('toast-text');
  let trackpadCursorX = window.innerWidth / 2;
  let trackpadCursorY = window.innerHeight / 2;

  // Toolbar Elements
  const floatingToolbar = document.getElementById('floating-toolbar');
  const toolbarPill = document.getElementById('toolbar-pill');
  const btnExpandToolbar = document.getElementById('btn-expand-toolbar');
  const btnCollapseToolbar = document.getElementById('btn-collapse-toolbar');
  const pillStatusDot = document.getElementById('pill-status-dot');
  const pillTransport = document.getElementById('pill-transport');
  const pillRes = document.getElementById('pill-res');
  const pillFps = document.getElementById('pill-fps');
  const pillPing = document.getElementById('pill-ping');
  const pillTouchToggle = document.getElementById('pill-touch-toggle');
  const pillTouchIcon = document.getElementById('pill-touch-icon');
  const pillTouchText = document.getElementById('pill-touch-text');
  const pillBattery = document.getElementById('pill-battery');

  // Battery Alert Modal Elements
  const batteryModal = document.getElementById('battery-alert-modal');
  const btnCloseBatteryModal = document.getElementById('btn-close-battery-modal');
  const btnTrafficClose = document.getElementById('btn-traffic-close');
  const btnDismissBattery = document.getElementById('btn-dismiss-battery');
  const batteryModalTitle = document.getElementById('battery-modal-title');
  const batteryModalMsg = document.getElementById('battery-modal-msg');
  const macBattVal = document.getElementById('mac-batt-val');
  const tabletBattVal = document.getElementById('tablet-batt-val');
  const badgeMac = document.getElementById('battery-badge-mac');
  const badgeTablet = document.getElementById('battery-badge-tablet');

  // Panel Header Elements
  const statusIndicator = document.getElementById('status-indicator');
  const statusLabel = document.getElementById('status-label');
  const valFps = document.getElementById('val-fps');
  const valPing = document.getElementById('val-ping');
  const valResolution = document.getElementById('val-resolution');

  // Control Selectors
  const modeSelector = document.getElementById('mode-selector');
  const qualitySelector = document.getElementById('quality-selector');
  const fpsSelector = document.getElementById('fps-selector');
  const scaleSelector = document.getElementById('scale-selector');
  const displaySelect = document.getElementById('display-select');
  const sliderBrightness = document.getElementById('slider-brightness');
  const valBrightness = document.getElementById('val-brightness');

  // Modifiers & Actions
  const modCmd = document.getElementById('mod-cmd');
  const modOpt = document.getElementById('mod-opt');
  const modCtrl = document.getElementById('mod-ctrl');
  const modShift = document.getElementById('mod-shift');
  const btnSoftKeyboard = document.getElementById('btn-soft-keyboard');
  const btnWakeLock = document.getElementById('btn-wakelock');
  const btnFullscreen = document.getElementById('btn-fullscreen');
  const btnReconnect = document.getElementById('btn-reconnect');
  const btnPwaInstall = document.getElementById('btn-pwa-install');
  const pillPwaChip = document.getElementById('pill-pwa-chip');

  // ============================================================================
  // Toast Notifications
  // ============================================================================
  let toastTimeout = null;
  function showToast(message, duration = 3000) {
    if (toastTimeout) clearTimeout(toastTimeout);
    toastText.textContent = message;
    toastBanner.classList.remove('hidden');
    toastTimeout = setTimeout(() => {
      toastBanner.classList.add('hidden');
    }, duration);
  }

  // ============================================================================
  // PWA (Progressive Web App) & Service Worker
  // ============================================================================
  let deferredInstallPrompt = null;

  const isAlreadyInstalled = localStorage.getItem('duo_pwa_installed') === 'true' ||
                             location.search.includes('pwa=1') ||
                             window.matchMedia('(display-mode: standalone)').matches ||
                             window.matchMedia('(display-mode: fullscreen)').matches ||
                             window.matchMedia('(display-mode: minimal-ui)').matches ||
                             window.navigator.standalone === true ||
                             document.referrer.includes('android-app://');

  if (isAlreadyInstalled) {
    try { localStorage.setItem('duo_pwa_installed', 'true'); } catch (_) {}
    if (pillPwaChip) {
      pillPwaChip.classList.add('hidden');
      pillPwaChip.style.display = 'none';
    }
    if (btnPwaInstall) btnPwaInstall.style.display = 'none';
  }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').then((reg) => {
        console.log('[PWA] Service Worker registered:', reg.scope);
      }).catch((err) => {
        console.warn('[PWA] Service Worker registration failed:', err);
      });
    });
  }

  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferredInstallPrompt = e;
    console.log('[PWA] beforeinstallprompt captured');

    const installed = localStorage.getItem('duo_pwa_installed') === 'true' ||
                      location.search.includes('pwa=1') ||
                      window.matchMedia('(display-mode: standalone)').matches ||
                      window.matchMedia('(display-mode: fullscreen)').matches ||
                      window.matchMedia('(display-mode: minimal-ui)').matches ||
                      window.navigator.standalone === true ||
                      document.referrer.includes('android-app://');

    if (!installed) {
      if (btnPwaInstall) btnPwaInstall.style.display = 'inline-flex';
      if (pillPwaChip) {
        pillPwaChip.classList.remove('hidden');
        pillPwaChip.style.display = 'inline-flex';
      }
    } else {
      if (pillPwaChip) {
        pillPwaChip.classList.add('hidden');
        pillPwaChip.style.display = 'none';
      }
      if (btnPwaInstall) btnPwaInstall.style.display = 'none';
    }
  });

  window.addEventListener('appinstalled', () => {
    console.log('[PWA] App installed successfully');
    try { localStorage.setItem('duo_pwa_installed', 'true'); } catch (_) {}
    deferredInstallPrompt = null;
    if (btnPwaInstall) btnPwaInstall.style.display = 'none';
    if (pillPwaChip) {
      pillPwaChip.classList.add('hidden');
      pillPwaChip.style.display = 'none';
    }
    showToast('✨ Android Duo установлено на рабочий стол!');
  });

  function triggerPwaInstall() {
    // Immediately hide the button upon tap so it never hangs
    try { localStorage.setItem('duo_pwa_installed', 'true'); } catch (_) {}
    if (btnPwaInstall) btnPwaInstall.style.display = 'none';
    if (pillPwaChip) {
      pillPwaChip.classList.add('hidden');
      pillPwaChip.style.display = 'none';
    }

    if (deferredInstallPrompt) {
      deferredInstallPrompt.prompt();
      deferredInstallPrompt.userChoice.then((choiceResult) => {
        console.log('[PWA] Install choice outcome:', choiceResult.outcome);
        deferredInstallPrompt = null;
      });
    } else {
      showToast('✅ Приложение уже установлено на рабочий стол!');
    }
  }

  // ============================================================================
  // WebSocket Connection & Stream Protocol
  // ============================================================================
  function updateCandidateHosts() {
    const list = [];
    const currentHost = location.host || 'localhost:3000';
    if (!list.includes(currentHost)) {
      list.push(currentHost);
    }

    // Retrieve saved Wi-Fi endpoints from memory or localStorage
    let savedIps = state.wifiIps;
    if (!savedIps || savedIps.length === 0) {
      try {
        savedIps = JSON.parse(localStorage.getItem('duo_wifi_ips') || '[]');
      } catch (_) {
        savedIps = [];
      }
    }
    const port = state.serverPort || location.port || 3000;

    for (const ip of savedIps) {
      const candidate = `${ip}:${port}`;
      if (!list.includes(candidate)) {
        list.push(candidate);
      }
    }

    // Always keep 127.0.0.1 and localhost in candidates (for USB reconnection)
    if (!list.includes(`127.0.0.1:${port}`)) {
      list.push(`127.0.0.1:${port}`);
    }
    if (!list.includes(`localhost:${port}`)) {
      list.push(`localhost:${port}`);
    }

    state.candidateHosts = list;
    return list;
  }

  function updateTransportUI(transport, host) {
    state.transport = transport;
    if (pillTransport) {
      if (transport === 'usb') {
        pillTransport.textContent = '⚡ USB';
        pillTransport.style.color = '#38bdf8';
      } else {
        pillTransport.textContent = '📶 Wi-Fi';
        pillTransport.style.color = '#34d399';
      }
    }
  }

  function upgradeToUsb(port) {
    const targetPort = port || state.serverPort || 3000;
    const usbHost = `127.0.0.1:${targetPort}`;
    const isCurrentHostUsb = state.activeHost.startsWith('127.0.0.1') || state.activeHost.startsWith('localhost');
    const isLocationUsb = location.hostname === '127.0.0.1' || location.hostname === 'localhost';

    if (state.connected && isCurrentHostUsb && isLocationUsb) {
      return;
    }

    console.log(`[DuoDisplay] Upgrading connection to Zero-Latency USB (${usbHost})...`);
    showToast('⚡ USB подключен — Переключение на сверхбыстрый USB-канал');

    // If currently loaded from a Wi-Fi address (192.168.x.x), Chrome's Private Network Access
    // policy blocks cross-network subresources and WebSockets to 127.0.0.1.
    // Top-level location.replace cleanly moves the page origin to 127.0.0.1 with zero PNA/CORS issues.
    if (!isLocationUsb) {
      const usbUrl = `http://${usbHost}/?pwa=1`;
      window.location.replace(usbUrl);
      return;
    }

    if (state.ws) {
      state.ws.onclose = null;
      state.ws.onerror = null;
      try { state.ws.close(); } catch (_) {}
      state.ws = null;
    }
    initWebSocket(usbHost);
  }

  function switchToUsb() {
    upgradeToUsb(state.serverPort);
  }

  function initWebSocket(preferredHost) {
    if (state.ws && (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }

    updateCandidateHosts();
    let targetHost;
    if (preferredHost) {
      targetHost = preferredHost;
      const idx = state.candidateHosts.indexOf(preferredHost);
      state.candidateIndex = idx >= 0 ? idx : 0;
    } else {
      targetHost = state.candidateHosts[state.candidateIndex] || location.host || 'localhost:3000';
    }
    state.activeHost = targetHost;

    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${targetHost}/ws`;

    const isUsb = targetHost.startsWith('localhost') || targetHost.startsWith('127.0.0.1');
    updateTransportUI(isUsb ? 'usb' : 'wifi', targetHost);
    updateConnectionUI('connecting');
    console.log(`[DuoDisplay] Connecting to WebSocket: ${wsUrl} (endpoint ${state.candidateIndex + 1}/${state.candidateHosts.length})`);

    try {
      const ws = new WebSocket(wsUrl);
      state.ws = ws;
      ws.binaryType = 'arraybuffer';

      // Fast connection timeout: if endpoint doesn't respond in 1.8s, move to next endpoint
      const connectTimeout = setTimeout(() => {
        if (ws.readyState === WebSocket.CONNECTING) {
          console.warn(`[DuoDisplay] Connection timeout on ${targetHost}, trying next endpoint...`);
          ws.close();
        }
      }, 1800);

      ws.onopen = () => {
        clearTimeout(connectTimeout);
        handleWsOpen();
      };
      ws.onmessage = handleWsMessage;
      ws.onclose = (event) => {
        clearTimeout(connectTimeout);
        handleWsClose(event);
      };
      ws.onerror = (err) => {
        clearTimeout(connectTimeout);
        handleWsError(err);
      };
    } catch (err) {
      console.error('[DuoDisplay] WebSocket initialization error:', err);
      scheduleReconnect();
    }
  }

  function handleWsOpen() {
    console.log(`[DuoDisplay] Connected to macOS stream server via ${state.activeHost}`);
    state.connected = true;
    state.reconnectAttempts = 0;
    updateConnectionUI('connected');

    const isUsb = state.activeHost.startsWith('localhost') || state.activeHost.startsWith('127.0.0.1');
    updateTransportUI(isUsb ? 'usb' : 'wifi', state.activeHost);

    if (isUsb) {
      showToast('⚡ Подключено по USB (0 мс)');
      try {
        if (location.hostname === '127.0.0.1' || location.hostname === 'localhost') {
          history.replaceState(null, '', `http://${state.activeHost}/`);
        }
      } catch (_) {}
    } else {
      showToast(`📶 Подключено по Wi-Fi (${state.activeHost.split(':')[0]})`);
      // Update browser URL so page refresh stays on Wi-Fi without dying
      try {
        if (location.host === state.activeHost) {
          history.replaceState(null, '', `http://${state.activeHost}/`);
        }
      } catch (_) {}
    }

    // Start periodic heartbeat ping
    startPingInterval();

    // Send initial client configuration & request frame
    sendClientConfig();
    sendJson({ type: 'request_frame' });
  }

  function handleWsMessage(event) {
    if (typeof event.data === 'string') {
      try {
        const msg = JSON.parse(event.data);
        handleControlMessage(msg);
      } catch (e) {
        console.warn('[DuoDisplay] Failed to parse JSON message:', e);
      }
    } else if (event.data instanceof ArrayBuffer) {
      handleBinaryFrame(event.data);
    } else if (event.data instanceof Blob) {
      event.data.arrayBuffer().then(handleBinaryFrame);
    }
  }

  function handleWsClose(event) {
    console.warn(`[DuoDisplay] WebSocket closed on ${state.activeHost} (code: ${event.code})`);
    const wasConnected = state.connected;
    state.connected = false;
    stopPingInterval();
    updateConnectionUI('disconnected');

    // Instant failover if USB cable was yanked while connected
    const wasUsb = state.activeHost && (state.activeHost.startsWith('localhost') || state.activeHost.startsWith('127.0.0.1'));
    if (wasConnected && wasUsb && state.candidateHosts.length > 1) {
      console.log('[DuoDisplay] USB disconnected! Instantly failing over to Wi-Fi...');
      showToast('⚡ USB unplugged — Continuing over Wi-Fi...');
      const wifiCandidateIdx = state.candidateHosts.findIndex(h => !h.startsWith('localhost') && !h.startsWith('127.0.0.1'));
      if (wifiCandidateIdx !== -1) {
        state.candidateIndex = wifiCandidateIdx;
      } else {
        state.candidateIndex = (state.candidateIndex + 1) % state.candidateHosts.length;
      }
      if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
      state.reconnectTimer = setTimeout(() => {
        state.reconnectTimer = null;
        initWebSocket();
      }, 150);
      return;
    }

    scheduleReconnect();
  }

  function handleWsError(err) {
    console.error('[DuoDisplay] WebSocket error:', err);
  }

  function scheduleReconnect() {
    if (state.reconnectTimer) return;
    state.reconnectAttempts++;

    // Cycle to next candidate endpoint (USB <-> Wi-Fi) on each retry
    if (state.candidateHosts.length > 1) {
      state.candidateIndex = (state.candidateIndex + 1) % state.candidateHosts.length;
    }

    const delay = Math.min(600 * Math.pow(1.3, state.reconnectAttempts - 1), state.maxReconnectDelay);
    console.log(`[DuoDisplay] Reconnecting to candidate ${state.candidateIndex + 1} in ${(delay / 1000).toFixed(1)}s...`);
    updateConnectionUI('connecting');

    state.reconnectTimer = setTimeout(() => {
      state.reconnectTimer = null;
      initWebSocket();
    }, delay);
  }

  function updateConnectionUI(status) {
    statusIndicator.className = 'status-indicator ' + status;
    pillStatusDot.className = 'pill-status-dot ' + status;

    if (status === 'connected') {
      statusLabel.textContent = 'Подключено';
      if (pillFps && pillFps.textContent === '-- FPS') {
        pillFps.textContent = `${state.targetFps || 90} FPS`;
      }
    } else if (status === 'connecting') {
      statusLabel.textContent = `Подключение (Попытка ${state.reconnectAttempts})...`;
    } else {
      statusLabel.textContent = 'Отключено';
      pillFps.textContent = '-- FPS';
      pillPing.textContent = '-- ms';
      valFps.textContent = '0';
      valPing.textContent = '0';
    }
  }

  function sendJson(payload) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      try {
        state.ws.send(JSON.stringify(payload));
      } catch (err) {
        console.error('[DuoDisplay] Error sending message:', err);
      }
    }
  }

  function sendClientConfig() {
    sendJson({
      type: 'settings',
      quality: state.quality,
      qualityValue: state.quality === 'high' ? 0.90 : (state.quality === 'med' ? 0.80 : 0.65),
      targetFps: state.targetFps,
      scaleMode: state.scaleMode,
      displayId: state.selectedDisplay,
      clientResolution: {
        width: Math.round(window.innerWidth * (window.devicePixelRatio || 1)),
        height: Math.round(window.innerHeight * (window.devicePixelRatio || 1))
      }
    });
  }

  function handleControlMessage(msg) {
    switch (msg.type) {
      case 'usb_connected':
        if (state.activeHost && !state.activeHost.startsWith('localhost') && !state.activeHost.startsWith('127.0.0.1')) {
          console.log('[DuoDisplay] Server notified USB reverse tunnel is ready. Upgrading to USB...');
          upgradeToUsb(msg.port || state.serverPort);
        }
        break;

      case 'pong':
        if (msg.timestamp) {
          state.lastPongTimestamp = performance.now();
          state.latency = Math.max(1, Math.round(state.lastPongTimestamp - msg.timestamp));
          valPing.textContent = state.latency;
          pillPing.textContent = `${state.latency} ms`;
        }
        break;

      case 'init':
        if (msg.wifiIps && Array.isArray(msg.wifiIps)) {
          state.wifiIps = msg.wifiIps;
          try { localStorage.setItem('duo_wifi_ips', JSON.stringify(msg.wifiIps)); } catch (_) {}
        }
        if (msg.port) {
          state.serverPort = msg.port;
          try { localStorage.setItem('duo_server_port', msg.port); } catch (_) {}
        }
        updateCandidateHosts();

        // If server informs USB reverse tunnel is active and client is currently on Wi-Fi, upgrade immediately!
        if (msg.usbAvailable && !state.activeHost.startsWith('127.0.0.1') && !state.activeHost.startsWith('localhost')) {
          console.log('[DuoDisplay] USB reverse tunnel detected on init. Upgrading to USB...');
          upgradeToUsb(msg.port || state.serverPort);
          return;
        }
        // Fallthrough to display_info
      case 'display_info':
        if (msg.screenWidth && msg.screenHeight) {
          state.remoteWidth = msg.screenWidth;
          state.remoteHeight = msg.screenHeight;
          if (valResolution) valResolution.textContent = `${msg.screenWidth}x${msg.screenHeight}`;
          if (pillRes) pillRes.textContent = `${msg.screenWidth}×${msg.screenHeight}`;

          // Keep UI scale buttons in sync
          const targetRes = `${msg.screenWidth}x${msg.screenHeight}`;
          document.querySelectorAll('#ui-scale-selector .segment-btn').forEach(btn => {
            if (btn.getAttribute('data-res') === targetRes) {
              btn.classList.add('active');
            } else {
              btn.classList.remove('active');
            }
          });

          resizeCanvas();
        }
        if (msg.displays && Array.isArray(msg.displays)) {
          updateDisplayDropdown(msg.displays);
        }
        break;

      case 'displays':
        if (Array.isArray(msg.displays)) {
          updateDisplayDropdown(msg.displays);
        }
        break;

      case 'brightness':
        if (msg.value !== undefined) {
          updateBrightnessUI(msg.value);
        }
        break;

      case 'battery':
        handleBatteryUpdate(msg.mac, msg.tablet);
        break;

      case 'mac_state':
        if (msg.state === 'sleep' || msg.state === 'lock') {
          console.log('[DuoDisplay] 🌙 Mac entered sleep/lock state. Blanking display & releasing WakeLock...');
          state.isMacAsleep = true;
          releaseWakeLock();
          if (ctx && canvas) {
            ctx.fillStyle = '#000000';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
          }
        } else if (msg.state === 'wake' || msg.state === 'unlock') {
          console.log('[DuoDisplay] ☀️ Mac woke up / unlocked. Resuming stream...');
          state.isMacAsleep = false;
          autoActivateInteraction();
          sendJson({ type: 'request_frame' });
        }
        break;

      default:
        // Other custom control messages from server
        break;
    }
  }

  // Battery State & Alerts
  const batteryState = {
    mac: { level: null, charging: false },
    tablet: { level: null, charging: false },
    dismissedKey: null
  };

  function handleBatteryUpdate(mac, tablet) {
    if (mac) {
      if (mac.level !== null && mac.level !== undefined) batteryState.mac.level = mac.level;
      if (mac.charging !== undefined) batteryState.mac.charging = mac.charging;
    }
    if (tablet) {
      if (tablet.level !== null && tablet.level !== undefined) batteryState.tablet.level = tablet.level;
      if (tablet.charging !== undefined) batteryState.tablet.charging = tablet.charging;
    }

    updateBatteryUI();
  }

  function updateBatteryUI() {
    const { mac, tablet } = batteryState;

    // Update status pill battery label
    if (pillBattery) {
      const parts = [];
      let isLow = false;

      if (mac.level !== null) {
        const chargingIcon = mac.charging ? '⚡' : '';
        parts.push(`💻 ${mac.level}%${chargingIcon}`);
        if (mac.level <= 25 && !mac.charging) isLow = true;
      }
      if (tablet.level !== null) {
        const chargingIcon = tablet.charging ? '⚡' : '';
        parts.push(`📱 ${tablet.level}%${chargingIcon}`);
        if (tablet.level <= 25 && !tablet.charging) isLow = true;
      }

      if (parts.length > 0) {
        pillBattery.textContent = (isLow ? '🪫 ' : '🔋 ') + parts.join(' · ');
        if (isLow) {
          pillBattery.classList.add('low');
        } else {
          pillBattery.classList.remove('low');
        }
      }
    }

    // Update Modal Badges
    if (macBattVal) {
      macBattVal.textContent = mac.level !== null ? `${mac.level}% ${mac.charging ? '⚡' : ''}` : '--%';
      if (badgeMac) {
        if (mac.level !== null && mac.level <= 25 && !mac.charging) {
          badgeMac.classList.add('low');
        } else {
          badgeMac.classList.remove('low');
        }
      }
    }
    if (tabletBattVal) {
      tabletBattVal.textContent = tablet.level !== null ? `${tablet.level}% ${tablet.charging ? '⚡' : ''}` : '--%';
      if (badgeTablet) {
        if (tablet.level !== null && tablet.level <= 25 && !tablet.charging) {
          badgeTablet.classList.add('low');
        } else {
          badgeTablet.classList.remove('low');
        }
      }
    }

    // Check if we need to show low battery alert (< 25% and not charging)
    const macLow = mac.level !== null && mac.level <= 25 && !mac.charging;
    const tabletLow = tablet.level !== null && tablet.level <= 25 && !tablet.charging;

    if (macLow || tabletLow) {
      const currentAlertKey = `${macLow ? mac.level : 'ok'}_${tabletLow ? tablet.level : 'ok'}`;
      if (batteryState.dismissedKey !== currentAlertKey) {
        if (macLow && tabletLow) {
          batteryModalTitle.textContent = 'Низкий заряд Mac и планшета!';
          batteryModalMsg.textContent = `Заряд батареи Mac (${mac.level}%) и планшета (${tablet.level}%) меньше 25%. Пожалуйста, поставьте устройства на зарядку!`;
        } else if (macLow) {
          batteryModalTitle.textContent = 'Низкий заряд Mac!';
          batteryModalMsg.textContent = `Уровень заряда батареи Mac: ${mac.level}%. Пожалуйста, поставьте Mac на зарядку!`;
        } else {
          batteryModalTitle.textContent = 'Низкий заряд планшета!';
          batteryModalMsg.textContent = `Уровень заряда батареи планшета: ${tablet.level}%. Пожалуйста, поставьте планшет на зарядку!`;
        }

        if (batteryModal) batteryModal.classList.remove('hidden');
      }
    } else {
      // Auto-hide when plugged in
      if (batteryModal && (mac.charging || tablet.charging)) {
        batteryModal.classList.add('hidden');
      }
    }
  }

  function dismissBatteryModal() {
    if (batteryModal) {
      batteryModal.classList.add('hidden');
    }
    const macLow = batteryState.mac.level !== null && batteryState.mac.level <= 25 && !batteryState.mac.charging;
    const tabletLow = batteryState.tablet.level !== null && batteryState.tablet.level <= 25 && !batteryState.tablet.charging;
    batteryState.dismissedKey = `${macLow ? batteryState.mac.level : 'ok'}_${tabletLow ? batteryState.tablet.level : 'ok'}`;
  }

  function updateBrightnessUI(val) {
    state.brightness = val;
    const pct = Math.round(val * 100);
    if (sliderBrightness) sliderBrightness.value = pct;
    if (valBrightness) valBrightness.textContent = `${pct}%`;
    // Visual adjustment for screen
    if (canvas) {
      canvas.style.filter = `brightness(${0.35 + val * 0.65})`;
    }
  }

  function updateDisplayDropdown(displays) {
    displaySelect.innerHTML = '';
    displays.forEach((d, idx) => {
      const opt = document.createElement('option');
      opt.value = d.id !== undefined ? d.id : idx;
      opt.textContent = `${d.name || 'Display ' + (idx + 1)} (${d.width || '?'}x${d.height || '?'})`;
      if (d.id === state.selectedDisplay || (d.primary && state.selectedDisplay === 0)) {
        opt.selected = true;
      }
      displaySelect.appendChild(opt);
    });
  }

  function startPingInterval() {
    stopPingInterval();
    state.lastPongTimestamp = performance.now();

    // Send immediate ping upon connection to establish ultra-fast latency baseline
    if (state.connected) {
      state.lastPingTimestamp = performance.now();
      sendJson({ type: 'ping', timestamp: state.lastPingTimestamp });
    }

    state.pingInterval = setInterval(() => {
      if (state.connected) {
        const now = performance.now();
        // If no pong for >2.8s while supposed to be connected, force close to trigger instant failover
        if (state.lastPongTimestamp && (now - state.lastPongTimestamp > 2800)) {
          console.warn('[DuoDisplay] Heartbeat lost (cable pulled), initiating immediate failover...');
          if (state.ws) {
            state.ws.close();
          }
          return;
        }
        state.lastPingTimestamp = now;
        sendJson({ type: 'ping', timestamp: state.lastPingTimestamp });
      }
    }, 1000);
  }

  function stopPingInterval() {
    if (state.pingInterval) {
      clearInterval(state.pingInterval);
      state.pingInterval = null;
    }
  }

  // ============================================================================
  // Binary Stream Decoder (High-Speed Metal GPU JPEG)
  // ============================================================================
  function handleBinaryFrame(buffer) {
    if (!buffer || buffer.byteLength < 2) return;
    const view = new DataView(buffer);
    if (view.getUint8(0) === 0x01) {
      // JPEG Packet (prefixed with 0x01)
      handleJpegBuffer(buffer.slice(1));
    } else {
      // Raw JPEG (starts with FF D8)
      handleJpegBuffer(buffer);
    }
  }

  // ============================================================================
  // Binary Stream Decoder & V-Sync Renderer (requestAnimationFrame)
  // ============================================================================
  let isDecodingJpeg = false;
  let latestPendingJpegBuffer = null;
  let pendingRenderBitmap = null;
  let isRenderRafScheduled = false;
  let lastRenderedBitmap = null;

  async function handleJpegBuffer(buffer) {
    latestPendingJpegBuffer = buffer;

    if (isDecodingJpeg) {
      // Decode loop will pick up latestPendingJpegBuffer on next cycle
      return;
    }

    isDecodingJpeg = true;
    while (latestPendingJpegBuffer) {
      const currentBuffer = latestPendingJpegBuffer;
      latestPendingJpegBuffer = null;

      try {
        const blob = new Blob([currentBuffer], { type: 'image/jpeg' });
        const bitmap = await createImageBitmap(blob);

        if (bitmap.width !== state.remoteWidth || bitmap.height !== state.remoteHeight) {
          state.remoteWidth = bitmap.width;
          state.remoteHeight = bitmap.height;
          if (valResolution) valResolution.textContent = `${bitmap.width}x${bitmap.height}`;
          if (pillRes) pillRes.textContent = `${bitmap.width}×${bitmap.height}`;
          resizeCanvas();
        }

        // Buffer the latest decoded frame for the next screen refresh cycle (V-Sync)
        if (pendingRenderBitmap && pendingRenderBitmap !== bitmap) {
          try { pendingRenderBitmap.close(); } catch (_) {}
        }
        pendingRenderBitmap = bitmap;
        scheduleRenderFrame();
      } catch (err) {
        console.warn('[DuoDisplay] Error decoding JPEG frame:', err);
      }
    }
    isDecodingJpeg = false;
  }

  // Periodic FPS calculator ensuring FPS never freezes on -- or stale values when screen is static
  setInterval(() => {
    if (state.connected) {
      const now = performance.now();
      const elapsed = now - state.lastFpsUpdateTime;
      if (elapsed >= 1000) {
        state.fps = Math.round((state.frameCount * 1000) / elapsed);
        state.frameCount = 0;
        state.lastFpsUpdateTime = now;
        if (valFps) valFps.textContent = state.fps;
        if (pillFps) {
          pillFps.textContent = state.fps > 0 ? `${state.fps} FPS` : `${state.targetFps || 60} FPS`;
        }
      }
    }
  }, 1000);

  function updateImageSmoothing(destW, destH, srcW, srcH) {
    const isOneToOne = (Math.round(destW) === Math.round(srcW) && Math.round(destH) === Math.round(srcH));
    if (isOneToOne) {
      if (ctx.imageSmoothingEnabled !== false) {
        ctx.imageSmoothingEnabled = false;
        if ('webkitImageSmoothingEnabled' in ctx) ctx.webkitImageSmoothingEnabled = false;
        if ('mozImageSmoothingEnabled' in ctx) ctx.mozImageSmoothingEnabled = false;
      }
    } else {
      if (ctx.imageSmoothingEnabled !== true) {
        ctx.imageSmoothingEnabled = true;
        if ('webkitImageSmoothingEnabled' in ctx) ctx.webkitImageSmoothingEnabled = true;
        if ('mozImageSmoothingEnabled' in ctx) ctx.mozImageSmoothingEnabled = true;
      }
      if (ctx.imageSmoothingQuality !== 'high') {
        ctx.imageSmoothingQuality = 'high';
      }
    }
    return isOneToOne;
  }

  function scheduleRenderFrame() {
    if (isRenderRafScheduled) return;
    isRenderRafScheduled = true;
    requestAnimationFrame(renderVsyncFrame);
  }

  function renderVsyncFrame() {
    isRenderRafScheduled = false;

    if (!pendingRenderBitmap) return;

    const bitmap = pendingRenderBitmap;
    pendingRenderBitmap = null;

    // Track FPS based on actual frames drawn to screen
    state.frameCount++;
    const now = performance.now();
    if (now - state.lastFpsUpdateTime >= 1000) {
      state.fps = Math.round((state.frameCount * 1000) / (now - state.lastFpsUpdateTime));
      state.frameCount = 0;
      state.lastFpsUpdateTime = now;
      if (valFps) valFps.textContent = state.fps;
      if (pillFps) pillFps.textContent = `${state.fps} FPS`;
    }

    // Draw frame to canvas desynchronized with V-Sync alignment
    if (state.scaleMode === 'fill') {
      updateImageSmoothing(canvas.width, canvas.height, bitmap.width, bitmap.height);
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    } else {
      const { renderWidth, renderHeight, offsetX, offsetY } = state.renderMetrics;
      if (offsetX > 0 || offsetY > 0) {
        ctx.fillStyle = '#000000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
      }
      updateImageSmoothing(renderWidth, renderHeight, bitmap.width, bitmap.height);
      ctx.drawImage(bitmap, offsetX, offsetY, renderWidth, renderHeight);
    }

    // Release old bitmap resources immediately
    if (lastRenderedBitmap && lastRenderedBitmap !== bitmap) {
      try { lastRenderedBitmap.close(); } catch (_) {}
    }
    lastRenderedBitmap = bitmap;

    // If another frame finished decoding while we were rendering, schedule next V-Sync render immediately
    if (pendingRenderBitmap) {
      scheduleRenderFrame();
    }
  }

  // ============================================================================
  // Canvas Sizing & Coordinate Transformation
  // ============================================================================
  function resizeCanvas() {
    // Use full devicePixelRatio (no artificial 1.5 cap) for crystal-clear retina rendering
    const dpr = window.devicePixelRatio || 1;
    const screenW = window.innerWidth;
    const screenH = window.innerHeight;
    let targetW = Math.round(screenW * dpr);
    let targetH = Math.round(screenH * dpr);

    const remoteW = state.remoteWidth || 1920;
    const remoteH = state.remoteHeight || 1200;

    // Check aspect ratios (Xiaomi Pad SE physical aspect ratio is 16:10 = 1.6)
    const screenAspect = screenW / screenH;
    const remoteAspect = remoteW / remoteH;
    const isAspectMatch = Math.abs(screenAspect - remoteAspect) < 0.05;
    const isFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);

    // In fullscreen or fill mode, when aspect ratio matches remote display (16:10),
    // snap canvas backing store to exact physical pixels / remoteWidth x remoteHeight
    // to eliminate fractional DPR rounding errors (e.g. 1919.75 -> 1920 on 1.75 DPR)
    // and guarantee 1:1 pixel mapping with zero scaling.
    if ((isFullscreen || state.scaleMode === 'fill') && isAspectMatch) {
      if (Math.abs(targetW - remoteW) <= 32 && Math.abs(targetH - remoteH) <= 32) {
        targetW = remoteW;
        targetH = remoteH;
      }
    }

    if (canvas.width !== targetW || canvas.height !== targetH) {
      canvas.width = targetW;
      canvas.height = targetH;
    }
    canvas.style.width = `${screenW}px`;
    canvas.style.height = `${screenH}px`;

    computeRenderMetrics(canvas.width, canvas.height);

    // Configure image smoothing: disable when 1:1 for crisp pixel rendering and fast GPU blit
    updateImageSmoothing(canvas.width, canvas.height, remoteW, remoteH);

    // Re-draw last bitmap immediately to avoid black screen on resize / fullscreen
    if (lastRenderedBitmap) {
      if (state.scaleMode === 'fill') {
        updateImageSmoothing(canvas.width, canvas.height, lastRenderedBitmap.width, lastRenderedBitmap.height);
        ctx.drawImage(lastRenderedBitmap, 0, 0, canvas.width, canvas.height);
      } else {
        const { renderWidth, renderHeight, offsetX, offsetY } = state.renderMetrics;
        if (offsetX > 0 || offsetY > 0) {
          ctx.fillStyle = '#000000';
          ctx.fillRect(0, 0, canvas.width, canvas.height);
        }
        updateImageSmoothing(renderWidth, renderHeight, lastRenderedBitmap.width, lastRenderedBitmap.height);
        ctx.drawImage(lastRenderedBitmap, offsetX, offsetY, renderWidth, renderHeight);
      }
    }
  }

  function computeRenderMetrics(canvasW, canvasH) {
    const remoteW = state.remoteWidth || 1920;
    const remoteH = state.remoteHeight || 1200;

    if (state.scaleMode === 'fill') {
      state.renderMetrics = {
        scale: canvasW / remoteW,
        offsetX: 0,
        offsetY: 0,
        renderWidth: canvasW,
        renderHeight: canvasH
      };
      return;
    }

    // Letterbox / Pillarbox fit preserving exact aspect ratio
    const scale = Math.min(canvasW / remoteW, canvasH / remoteH);
    const renderWidth = Math.round(remoteW * scale);
    const renderHeight = Math.round(remoteH * scale);
    const offsetX = Math.round((canvasW - renderWidth) / 2);
    const offsetY = Math.round((canvasH - renderHeight) / 2);

    state.renderMetrics = {
      scale,
      offsetX,
      offsetY,
      renderWidth,
      renderHeight
    };
  }

  window.addEventListener('resize', () => {
    resizeCanvas();
  });

  window.addEventListener('orientationchange', () => {
    setTimeout(resizeCanvas, 200);
  });

  /**
   * Convert tablet viewport touch coordinate (clientX, clientY) to macOS remote display coordinate
   * Uses viewport CSS bounding rect directly to guarantee 1:1 pixel accuracy with 0 DPR distortion.
   */
  function clientToMacCoords(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    const cssW = rect.width || window.innerWidth;
    const cssH = rect.height || window.innerHeight;

    let normX, normY;
    if (state.scaleMode === 'fill') {
      normX = (clientX - rect.left) / cssW;
      normY = (clientY - rect.top) / cssH;
    } else {
      const remoteW = state.remoteWidth || 1920;
      const remoteH = state.remoteHeight || 1200;
      const scale = Math.min(cssW / remoteW, cssH / remoteH);
      const renderW = remoteW * scale;
      const renderH = remoteH * scale;
      const offsetX = (cssW - renderW) / 2;
      const offsetY = (cssH - renderH) / 2;
      normX = (clientX - rect.left - offsetX) / renderW;
      normY = (clientY - rect.top - offsetY) / renderH;
    }

    normX = Math.max(0, Math.min(1, normX));
    normY = Math.max(0, Math.min(1, normY));

    const absX = Math.round(normX * (state.remoteWidth || 1920));
    const absY = Math.round(normY * (state.remoteHeight || 1200));

    return { normX, normY, absX, absY };
  }

  // ============================================================================
  // Touch & Gesture Engine (Optimized for Xiaomi Pad / HyperOS)
  // ============================================================================
  const gesture = {
    // Single touch tracking
    activeTouches: 0,
    startX: 0,
    startY: 0,
    startTime: 0,
    lastX: 0,
    lastY: 0,
    hasMoved: false,
    isScrolling: false,
    longPressTimer: null,
    isLongPressed: false,

    // Double tap drag tracking
    lastTapTime: 0,
    lastTapX: 0,
    lastTapY: 0,
    isDragging: false,

    // Two finger tracking (scroll / pinch / right click tap)
    twoFingerStartTime: 0,
    twoFingerMoved: false,
    lastMidX: 0,
    lastMidY: 0,
    lastPinchDist: 0,

    // Three finger tracking (Mission Control / Show Desktop / Toolbar)
    threeFingerStartTime: 0,
    threeFingerStartY: 0,
    threeFingerMoved: false
  };

  function triggerVibrate(pattern) {
    if (navigator.vibrate) {
      try {
        navigator.vibrate(pattern);
      } catch (e) {
        // Ignored if browser blocks vibration without permission
      }
    }
  }

  function showTouchIndicator(x, y) {
    touchIndicator.style.left = `${x}px`;
    touchIndicator.style.top = `${y}px`;
    touchIndicator.classList.remove('active');
    void touchIndicator.offsetWidth; // Force reflow
    touchIndicator.classList.add('active');
    setTimeout(() => {
      touchIndicator.classList.remove('active');
    }, 280);
  }

  function startLongPressFeedback(x, y) {
    longpressIndicator.style.left = `${x}px`;
    longpressIndicator.style.top = `${y}px`;
    longpressIndicator.classList.remove('charging');
    void longpressIndicator.offsetWidth;
    longpressIndicator.classList.add('charging');
  }

  function cancelLongPressFeedback() {
    longpressIndicator.classList.remove('charging');
  }

  // Prevent default context menus anywhere on canvas or container
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  canvasContainer.addEventListener('contextmenu', (e) => e.preventDefault());

  // --------------------------------------------------------------------------
  // Touch Event Handlers
  // --------------------------------------------------------------------------
  canvas.addEventListener('touchstart', handleTouchStart, { passive: false });
  canvas.addEventListener('touchmove', handleTouchMove, { passive: false });
  canvas.addEventListener('touchend', handleTouchEnd, { passive: false });
  canvas.addEventListener('touchcancel', handleTouchCancel, { passive: false });

  let isInitialFullscreenTap = true;

  function handleTouchStart(e) {
    autoEnterFullscreen();

    if (!state.touchEnabled || state.mode === 'off') {
      return;
    }
    e.preventDefault();

    gesture.activeTouches = e.touches.length;

    if (e.touches.length === 1) {
      handleSingleTouchStart(e.touches[0]);
    } else if (e.touches.length === 2) {
      handleTwoFingerStart(e.touches);
    } else if (e.touches.length === 3) {
      handleThreeFingerStart(e.touches);
    }
  }

  function handleTouchMove(e) {
    if (!state.touchEnabled || state.mode === 'off') {
      return;
    }
    e.preventDefault();

    if (e.touches.length === 1 && gesture.activeTouches === 1) {
      handleSingleTouchMove(e.touches[0]);
    } else if (e.touches.length === 2) {
      handleTwoFingerMove(e.touches);
    } else if (e.touches.length === 3) {
      handleThreeFingerMove(e.touches);
    }
  }

  function handleTouchEnd(e) {
    if (!state.touchEnabled || state.mode === 'off') {
      return;
    }
    e.preventDefault();

    if (gesture.activeTouches === 1) {
      handleSingleTouchEnd(e.changedTouches[0]);
    } else if (gesture.activeTouches === 2) {
      handleTwoFingerEnd(e.changedTouches);
    } else if (gesture.activeTouches === 3) {
      handleThreeFingerEnd(e.changedTouches);
    }

    gesture.activeTouches = e.touches.length;
  }

  function handleTouchCancel(e) {
    if (!state.touchEnabled || state.mode === 'off') {
      return;
    }
    clearTimeout(gesture.longPressTimer);
    cancelLongPressFeedback();
    if (gesture.isDragging) {
      const coords = clientToMacCoords(gesture.lastX, gesture.lastY);
      sendMouseEvent('mouseup', { button: 'left', ...coords });
      gesture.isDragging = false;
    }
    gesture.activeTouches = 0;
  }

  // --------------------------------------------------------------------------
  // 1 Finger Gestures: Direct Touch & Drag (Sidecar-Style), Tap, Long-Press (Right Click), Trackpad
  // --------------------------------------------------------------------------
  const DRAG_THRESHOLD = 8;

  function handleSingleTouchStart(touch) {
    const x = touch.clientX;
    const y = touch.clientY;
    const now = performance.now();

    gesture.startX = x;
    gesture.startY = y;
    gesture.lastX = x;
    gesture.lastY = y;
    gesture.startTime = now;
    gesture.hasMoved = false;
    gesture.isDragging = false;
    gesture.isScrolling = false;
    gesture.isLongPressed = false;

    if (state.mode === 'direct') {
      // Direct Touch: Hold for 500ms for right-click context menu
      startLongPressFeedback(x, y);
      clearTimeout(gesture.longPressTimer);
      gesture.longPressTimer = setTimeout(() => {
        if (!gesture.hasMoved && gesture.activeTouches === 1) {
          gesture.isLongPressed = true;
          cancelLongPressFeedback();
          triggerVibrate([30, 40]);
          showTouchIndicator(x, y);

          const coords = clientToMacCoords(x, y);
          sendMouseEvent('click', { button: 'right', ...coords });
        }
      }, 500);
      return;
    }

    // Trackpad mode:
    gesture.isDragging = false;
    const tapDistance = Math.hypot(x - gesture.lastTapX, y - gesture.lastTapY);
    if (now - gesture.lastTapTime < 320 && tapDistance < 25) {
      gesture.isDragging = true;
      triggerVibrate(20);
      const coords = clientToMacCoords(trackpadCursorX, trackpadCursorY);
      sendMouseEvent('mousedown', { button: 'left', ...coords });
      return;
    }

    startLongPressFeedback(x, y);
    clearTimeout(gesture.longPressTimer);
    gesture.longPressTimer = setTimeout(() => {
      if (!gesture.hasMoved && gesture.activeTouches === 1) {
        gesture.isLongPressed = true;
        cancelLongPressFeedback();
        triggerVibrate([30, 40]);
        showTouchIndicator(trackpadCursorX, trackpadCursorY);

        const coords = clientToMacCoords(trackpadCursorX, trackpadCursorY);
        sendMouseEvent('click', { button: 'right', ...coords });
      }
    }, 500);
  }

  function handleSingleTouchMove(touch) {
    const x = touch.clientX;
    const y = touch.clientY;
    const dx = x - gesture.lastX;
    const dy = y - gesture.lastY;
    const totalDist = Math.hypot(x - gesture.startX, y - gesture.startY);

    // Movement > 5px cancels long press
    if (totalDist > 5) {
      gesture.hasMoved = true;
      clearTimeout(gesture.longPressTimer);
      cancelLongPressFeedback();
    }

    if (state.mode === 'direct') {
      if (gesture.isLongPressed) return;

      // Only engage drag if finger moves past threshold (prevents tap jitter from turning into drags!)
      if (totalDist >= DRAG_THRESHOLD) {
        if (!gesture.isDragging) {
          gesture.isDragging = true;
          const startCoords = clientToMacCoords(gesture.startX, gesture.startY);
          sendMouseEvent('mousedown', { button: 'left', ...startCoords });
        }
        const coords = clientToMacCoords(x, y);
        sendMouseEvent('mousemove', {
          ...coords,
          dx,
          dy,
          buttons: 1,
          isDragging: true
        });
      }
    } else {
      // Trackpad mode: relative motion
      const scaledDx = dx * state.trackpadSensitivity;
      const scaledDy = dy * state.trackpadSensitivity;

      trackpadCursorX = Math.max(0, Math.min(window.innerWidth, trackpadCursorX + scaledDx));
      trackpadCursorY = Math.max(0, Math.min(window.innerHeight, trackpadCursorY + scaledDy));

      sendMouseEvent('mousemove_delta', {
        dx: scaledDx,
        dy: scaledDy,
        buttons: gesture.isDragging ? 1 : 0
      });
    }

    gesture.lastX = x;
    gesture.lastY = y;
  }

  function handleSingleTouchEnd(touch) {
    clearTimeout(gesture.longPressTimer);
    cancelLongPressFeedback();

    const x = touch.clientX;
    const y = touch.clientY;
    const now = performance.now();
    const duration = now - gesture.startTime;
    const dist = Math.hypot(x - gesture.startX, y - gesture.startY);

    if (gesture.isLongPressed) {
      gesture.isLongPressed = false;
      gesture.isDragging = false;
      return;
    }

    if (state.mode === 'direct') {
      if (gesture.isDragging) {
        gesture.isDragging = false;
        const coords = clientToMacCoords(x, y);
        sendMouseEvent('mouseup', { button: 'left', ...coords });
      } else if (dist < DRAG_THRESHOLD && duration < 400) {
        // Clean Direct Tap!
        showTouchIndicator(x, y);
        triggerVibrate(15);
        const coords = clientToMacCoords(x, y);
        
        // Double-tap detection
        const tapDist = Math.hypot(x - gesture.lastTapX, y - gesture.lastTapY);
        const isDoubleTap = (now - gesture.lastTapTime < 320) && (tapDist < 25);
        
        if (isDoubleTap) {
          sendMouseEvent('click', { button: 'left', count: 2, ...coords });
          gesture.lastTapTime = 0;
        } else {
          sendMouseEvent('click', { button: 'left', count: 1, ...coords });
          gesture.lastTapTime = now;
          gesture.lastTapX = x;
          gesture.lastTapY = y;
        }
      }
      return;
    }

    // Trackpad mode:
    if (gesture.isDragging) {
      gesture.isDragging = false;
      const coords = clientToMacCoords(trackpadCursorX, trackpadCursorY);
      sendMouseEvent('mouseup', { button: 'left', ...coords });
      return;
    }

    // Trackpad mode tap = left click at current cursor
    if (duration < 350 && dist < 15) {
      showTouchIndicator(trackpadCursorX, trackpadCursorY);
      triggerVibrate(15);

      const coords = clientToMacCoords(trackpadCursorX, trackpadCursorY);
      const tapDist = Math.hypot(x - gesture.lastTapX, y - gesture.lastTapY);
      const isDoubleTap = (now - gesture.lastTapTime < 320) && (tapDist < 25);

      if (isDoubleTap) {
        sendMouseEvent('click', { button: 'left', count: 2, ...coords });
        gesture.lastTapTime = 0;
      } else {
        sendMouseEvent('click', { button: 'left', count: 1, ...coords });
        gesture.lastTapTime = now;
        gesture.lastTapX = x;
        gesture.lastTapY = y;
      }
    }
  }

  // --------------------------------------------------------------------------
  // 2 Finger Gestures: Two-finger Tap (Right Click), Two-finger Scroll, Pinch Zoom
  // --------------------------------------------------------------------------
  function handleTwoFingerStart(touches) {
    clearTimeout(gesture.longPressTimer);
    cancelLongPressFeedback();

    // Release any single finger drag cleanly when a second finger is placed down
    if (state.mode === 'direct' && gesture.isDragging) {
      const coords = clientToMacCoords(gesture.lastX, gesture.lastY);
      sendMouseEvent('mouseup', { button: 'left', ...coords });
      gesture.isDragging = false;
    }

    const t1 = touches[0];
    const t2 = touches[1];

    gesture.twoFingerStartTime = performance.now();
    gesture.twoFingerMoved = false;
    gesture.lastMidX = (t1.clientX + t2.clientX) / 2;
    gesture.lastMidY = (t1.clientY + t2.clientY) / 2;
    gesture.lastPinchDist = Math.hypot(t2.clientX - t1.clientX, t2.clientY - t1.clientY);
  }

  function handleTwoFingerMove(touches) {
    const t1 = touches[0];
    const t2 = touches[1];

    const midX = (t1.clientX + t2.clientX) / 2;
    const midY = (t1.clientY + t2.clientY) / 2;
    const dist = Math.hypot(t2.clientX - t1.clientX, t2.clientY - t1.clientY);

    const deltaX = midX - gesture.lastMidX;
    const deltaY = midY - gesture.lastMidY;
    const pinchDelta = dist - gesture.lastPinchDist;

    if (Math.hypot(deltaX, deltaY) > 2 || Math.abs(pinchDelta) > 5) {
      gesture.twoFingerMoved = true;
    }

    // Two finger scroll (natural scrolling on macOS)
    if (Math.hypot(deltaX, deltaY) > 1.5) {
      const scrollDx = deltaX * state.scrollSensitivity;
      const scrollDy = deltaY * state.scrollSensitivity;
      const coords = clientToMacCoords(midX, midY);

      sendScrollEvent({
        dx: scrollDx,
        dy: scrollDy,
        ...coords
      });
    }

    // Pinch-to-zoom gesture
    if (Math.abs(pinchDelta) > 4 && gesture.lastPinchDist > 0) {
      const scaleFactor = dist / gesture.lastPinchDist;
      sendPinchEvent({
        scale: scaleFactor,
        delta: pinchDelta,
        x: midX,
        y: midY
      });
    }

    gesture.lastMidX = midX;
    gesture.lastMidY = midY;
    gesture.lastPinchDist = dist;
  }

  function handleTwoFingerEnd(changedTouches) {
    const duration = performance.now() - gesture.twoFingerStartTime;

    // Two-finger tap (<320ms without move) -> Right Click (Context Menu)
    if (!gesture.twoFingerMoved && duration < 320) {
      triggerVibrate([20, 30]);
      showTouchIndicator(gesture.lastMidX, gesture.lastMidY);

      const coords = clientToMacCoords(gesture.lastMidX, gesture.lastMidY);
      sendMouseEvent('mousedown', { button: 'right', ...coords });
      sendMouseEvent('mouseup', { button: 'right', ...coords });
      sendMouseEvent('click', { button: 'right', ...coords });
    }
  }

  // --------------------------------------------------------------------------
  // 3 Finger Gestures: Tap (Toggle Toolbar), Swipe Up (Mission Control), Swipe Down (Desktop)
  // --------------------------------------------------------------------------
  function handleThreeFingerStart(touches) {
    clearTimeout(gesture.longPressTimer);
    cancelLongPressFeedback();

    gesture.threeFingerStartTime = performance.now();
    gesture.threeFingerStartY = (touches[0].clientY + touches[1].clientY + touches[2].clientY) / 3;
    gesture.threeFingerMoved = false;
  }

  function handleThreeFingerMove(touches) {
    const currentY = (touches[0].clientY + touches[1].clientY + touches[2].clientY) / 3;
    const dy = currentY - gesture.threeFingerStartY;

    if (Math.abs(dy) > 30) {
      gesture.threeFingerMoved = true;
    }
  }

  function handleThreeFingerEnd(changedTouches) {
    const duration = performance.now() - gesture.threeFingerStartTime;
    const endY = (changedTouches[0]?.clientY || gesture.threeFingerStartY);
    const dy = endY - gesture.threeFingerStartY;

    if (!gesture.threeFingerMoved && duration < 350) {
      // Three-finger tap: Toggle floating toolbar
      triggerVibrate(30);
      toggleToolbar();
    } else if (gesture.threeFingerMoved) {
      if (dy < -50) {
        // Swipe Up: Mission Control (Ctrl + Up)
        triggerVibrate([20, 40]);
        showToast('Mission Control (Ctrl+Up)');
        sendShortcut('mission_control');
      } else if (dy > 50) {
        // Swipe Down: Show Desktop (F11)
        triggerVibrate([20, 40]);
        showToast('Show Desktop (F11)');
        sendShortcut('show_desktop');
      }
    }
  }

  // ============================================================================
  // Event Dispatchers: Mouse, Scroll, Keyboard
  // ============================================================================
  let pendingMouseMove = null;
  let mouseMoveRaf = null;

  function flushMouseMove() {
    if (pendingMouseMove) {
      sendJson(pendingMouseMove);
      pendingMouseMove = null;
    }
    mouseMoveRaf = null;
  }

  function sendMouseEvent(action, data = {}) {
    const hasCoords = (data.normX !== undefined || data.x !== undefined);
    const normX = hasCoords ? (data.normX !== undefined ? data.normX : data.x) : undefined;
    const normY = hasCoords ? (data.normY !== undefined ? data.normY : data.y) : undefined;
    const isDragging = !!(data.isDragging || data.buttons === 1);
    const payload = {
      type: 'mouse',
      action, // 'mousedown' | 'mouseup' | 'mousemove' | 'mousemove_delta' | 'click'
      button: data.button || 'left',
      count: data.count || 1,
      x: normX,
      y: normY,
      normX: normX,
      normY: normY,
      absX: data.absX,
      absY: data.absY,
      dx: data.dx !== undefined ? data.dx : 0,
      dy: data.dy !== undefined ? data.dy : 0,
      buttons: data.buttons !== undefined ? data.buttons : 0,
      isDragging,
      modifiers: getActiveModifiersArray()
    };

    if (action === 'mousemove' || action === 'mousemove_delta') {
      pendingMouseMove = payload;
      if (!mouseMoveRaf) {
        mouseMoveRaf = requestAnimationFrame(flushMouseMove);
      }
    } else {
      if (mouseMoveRaf) {
        cancelAnimationFrame(mouseMoveRaf);
        flushMouseMove();
      }
      sendJson(payload);
    }
  }

  function sendScrollEvent(data) {
    sendJson({
      type: 'scroll',
      dx: data.dx,
      dy: data.dy,
      x: data.normX,
      y: data.normY,
      normX: data.normX,
      normY: data.normY,
      absX: data.absX,
      absY: data.absY,
      modifiers: getActiveModifiersArray()
    });
  }

  function sendPinchEvent(data) {
    sendJson({
      type: 'pinch',
      scale: data.scale,
      delta: data.delta,
      modifiers: getActiveModifiersArray()
    });
  }

  // Map DOM key names and codes to Apple macOS CGKeyCodes
  const DOM_TO_MAC_CGKEYCODE = {
    // Control & Editing
    Enter: 0x24, Return: 0x24, NumpadEnter: 0x4C,
    Backspace: 0x33,
    Tab: 0x30,
    Space: 0x31, ' ': 0x31,
    Escape: 0x35, Esc: 0x35,
    Delete: 0x75,
    ArrowLeft: 0x7B, Left: 0x7B,
    ArrowUp: 0x7E, Up: 0x7E,
    ArrowRight: 0x7C, Right: 0x7C,
    ArrowDown: 0x7D, Down: 0x7D,
    // Letters: A-Z
    KeyA: 0x00, KeyB: 0x0B, KeyC: 0x08, KeyD: 0x02, KeyE: 0x0E,
    KeyF: 0x03, KeyG: 0x05, KeyH: 0x04, KeyI: 0x22, KeyJ: 0x26,
    KeyK: 0x28, KeyL: 0x25, KeyM: 0x2E, KeyN: 0x2D, KeyO: 0x1F,
    KeyP: 0x23, KeyQ: 0x0C, KeyR: 0x0F, KeyS: 0x01, KeyT: 0x11,
    KeyU: 0x20, KeyV: 0x09, KeyW: 0x0D, KeyX: 0x07, KeyY: 0x10, KeyZ: 0x06,
    // Digits: 0-9
    Digit0: 0x1D, Digit1: 0x12, Digit2: 0x13, Digit3: 0x14, Digit4: 0x15,
    Digit5: 0x17, Digit6: 0x16, Digit7: 0x1A, Digit8: 0x1C, Digit9: 0x19
  };

  // Web DOM numeric keyCode to Apple macOS CGKeyCode
  // (Prevents Enter=13 becoming 'w' and Backspace=8 becoming 'c' on macOS!)
  const WEB_KEY_CODE_TO_MAC = {
    13: 0x24, // Enter -> kVK_Return (0x24 = 36)
    8: 0x33,  // Backspace -> kVK_Delete (0x33 = 51)
    9: 0x30,  // Tab -> kVK_Tab (0x30 = 48)
    32: 0x31, // Space -> kVK_Space (0x31 = 49)
    27: 0x35, // Escape -> kVK_Escape (0x35 = 53)
    37: 0x7B, // Left Arrow
    38: 0x7E, // Up Arrow
    39: 0x7C, // Right Arrow
    40: 0x7D, // Down Arrow
    46: 0x75, // Forward Delete
    // Letters
    65: 0x00, 66: 0x0B, 67: 0x08, 68: 0x02, 69: 0x0E, 70: 0x03, 71: 0x05, 72: 0x04,
    73: 0x22, 74: 0x26, 75: 0x28, 76: 0x25, 77: 0x2E, 78: 0x2D, 79: 0x1F, 80: 0x23,
    81: 0x0C, 82: 0x0F, 83: 0x01, 84: 0x11, 85: 0x20, 86: 0x09, 87: 0x0D, 88: 0x07,
    89: 0x10, 90: 0x06,
    // Digits
    48: 0x1D, 49: 0x12, 50: 0x13, 51: 0x14, 52: 0x15, 53: 0x17, 54: 0x16, 55: 0x1A, 56: 0x1C, 57: 0x19
  };

  function resolveMacKeyCode(keyData) {
    if (keyData.macKeyCode !== undefined) {
      return keyData.macKeyCode;
    }
    if (keyData.code && DOM_TO_MAC_CGKEYCODE[keyData.code] !== undefined) {
      return DOM_TO_MAC_CGKEYCODE[keyData.code];
    }
    if (keyData.key && DOM_TO_MAC_CGKEYCODE[keyData.key] !== undefined) {
      return DOM_TO_MAC_CGKEYCODE[keyData.key];
    }
    if (keyData.key && keyData.key.length === 1) {
      const codeName = 'Key' + keyData.key.toUpperCase();
      if (DOM_TO_MAC_CGKEYCODE[codeName] !== undefined) {
        return DOM_TO_MAC_CGKEYCODE[codeName];
      }
      const digitName = 'Digit' + keyData.key;
      if (DOM_TO_MAC_CGKEYCODE[digitName] !== undefined) {
        return DOM_TO_MAC_CGKEYCODE[digitName];
      }
    }
    if (keyData.keyCode && WEB_KEY_CODE_TO_MAC[keyData.keyCode] !== undefined) {
      return WEB_KEY_CODE_TO_MAC[keyData.keyCode];
    }
    return keyData.keyCode || 0;
  }

  function sendKeyEvent(action, keyData) {
    const macKeyCode = resolveMacKeyCode(keyData);
    const key = keyData.key || keyData.code || '';
    const code = keyData.code || keyData.key || '';

    if (action === 'press') {
      sendJson({
        type: 'key',
        action: 'down',
        key,
        code,
        keyCode: macKeyCode,
        macKeyCode,
        modifiers: getActiveModifiersArray()
      });
      setTimeout(() => {
        sendJson({
          type: 'key',
          action: 'up',
          key,
          code,
          keyCode: macKeyCode,
          macKeyCode,
          modifiers: getActiveModifiersArray()
        });
      }, 25);
      return;
    }

    sendJson({
      type: 'key',
      action, // 'down' | 'up'
      key,
      code,
      keyCode: macKeyCode,
      macKeyCode,
      modifiers: getActiveModifiersArray()
    });
  }

  function sendShortcut(combo) {
    sendJson({
      type: 'shortcut',
      combo, // e.g. 'cmd+c', 'mission_control'
      modifiers: getActiveModifiersArray()
    });
  }

  function getActiveModifiersArray() {
    const list = [];
    if (state.modifiers.cmd) list.push('cmd');
    if (state.modifiers.opt) list.push('opt');
    if (state.modifiers.ctrl) list.push('ctrl');
    if (state.modifiers.shift) list.push('shift');
    return list;
  }

  // ============================================================================
  // Keyboard Engine & Virtual Input
  // ============================================================================
  function setupKeyboardEngine() {
    // Hidden input for summoning Android soft keyboard
    btnSoftKeyboard.addEventListener('click', (e) => {
      e.stopPropagation();
      hiddenInput.focus();
      showToast('Virtual Keyboard Activated');
    });

    hiddenInput.addEventListener('keydown', (e) => {
      sendKeyEvent('down', {
        key: e.key,
        code: e.code,
        keyCode: e.keyCode
      });

      if (e.key === 'Enter') {
        hiddenInput.value = '';
      }
    });

    hiddenInput.addEventListener('keyup', (e) => {
      sendKeyEvent('up', {
        key: e.key,
        code: e.code,
        keyCode: e.keyCode
      });
    });

    hiddenInput.addEventListener('input', (e) => {
      // Clear after text ingestion to prevent IME accumulation
      setTimeout(() => {
        hiddenInput.value = '';
      }, 50);
    });

    // Hardware Bluetooth keyboard attached to tablet
    window.addEventListener('keydown', (e) => {
      if (e.target === hiddenInput) return;

      // Intercept common macOS browser keys to forward them to remote desktop
      const isSystemKey = e.key === 'Tab' || e.key === 'Escape' || (e.metaKey || e.ctrlKey);
      if (isSystemKey) {
        e.preventDefault();
      }

      sendKeyEvent('down', {
        key: e.key,
        code: e.code,
        keyCode: e.keyCode
      });
    });

    window.addEventListener('keyup', (e) => {
      if (e.target === hiddenInput) return;

      sendKeyEvent('up', {
        key: e.key,
        code: e.code,
        keyCode: e.keyCode
      });
    });
  }

  // ============================================================================
  // UI Controls & Toolbar Management
  // ============================================================================
  function toggleToolbar() {
    state.toolbarExpanded = !state.toolbarExpanded;
    if (state.toolbarExpanded) {
      floatingToolbar.classList.remove('toolbar-collapsed');
      floatingToolbar.classList.add('toolbar-expanded');
    } else {
      floatingToolbar.classList.remove('toolbar-expanded');
      floatingToolbar.classList.add('toolbar-collapsed');
    }
  }

  function setupToolbarUI() {
    // Pill and Panel collapse / expand
    toolbarPill.addEventListener('click', () => toggleToolbar());
    btnExpandToolbar.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleToolbar();
    });
    btnCollapseToolbar.addEventListener('click', () => toggleToolbar());

    function setTouchEnabled(enabled, requestedMode) {
      state.touchEnabled = enabled;

      if (enabled) {
        state.mode = requestedMode || state.savedActiveMode || 'direct';
        if (pillTouchToggle) {
          pillTouchToggle.classList.remove('disabled');
          pillTouchToggle.classList.add('active');
        }
        if (pillTouchIcon) pillTouchIcon.textContent = '👆';
        if (pillTouchText) pillTouchText.textContent = state.mode === 'direct' ? 'TOUCH: ON' : 'TRACKPAD';
        
        modeSelector.querySelectorAll('.segment-btn').forEach(b => {
          b.classList.toggle('active', b.getAttribute('data-mode') === state.mode);
        });
        showToast(`Сенсорный ввод: ВКЛЮЧЕН (${state.mode === 'direct' ? 'Прямой тач' : 'Трекпад'})`);
      } else {
        if (state.mode !== 'off') {
          state.savedActiveMode = state.mode;
        }
        state.mode = 'off';
        if (pillTouchToggle) {
          pillTouchToggle.classList.add('disabled');
          pillTouchToggle.classList.remove('active');
        }
        if (pillTouchIcon) pillTouchIcon.textContent = '🔒';
        if (pillTouchText) pillTouchText.textContent = 'TOUCH: OFF';
        
        modeSelector.querySelectorAll('.segment-btn').forEach(b => {
          b.classList.toggle('active', b.getAttribute('data-mode') === 'off');
        });
        showToast('Сенсорный ввод: ОТКЛЮЧЕН (Только монитор)');
      }
    }

    // Toggle touch on pill button
    if (pillTouchToggle) {
      pillTouchToggle.addEventListener('click', (e) => {
        e.stopPropagation();
        triggerVibrate(25);
        setTouchEnabled(!state.touchEnabled);
      });
    }

    // Mode Selector: Direct vs Trackpad vs Disabled
    modeSelector.addEventListener('click', (e) => {
      const btn = e.target.closest('.segment-btn');
      if (!btn) return;
      const selectedMode = btn.getAttribute('data-mode');
      triggerVibrate(15);

      if (selectedMode === 'off') {
        setTouchEnabled(false);
      } else {
        state.savedActiveMode = selectedMode;
        setTouchEnabled(true, selectedMode);
      }
    });

    // Brightness Slider input listener
    if (sliderBrightness) {
      sliderBrightness.addEventListener('input', (e) => {
        const val = parseInt(e.target.value, 10) / 100;
        updateBrightnessUI(val);
        sendJson({ type: 'set_brightness', value: val });
      });
    }

    // Stream Quality Selector
    qualitySelector.addEventListener('click', (e) => {
      const btn = e.target.closest('.segment-btn');
      if (!btn) return;
      qualitySelector.querySelectorAll('.segment-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      state.quality = btn.getAttribute('data-quality');
      sendClientConfig();
      const qLabels = { low: 'Низкое', med: 'Среднее', high: 'Высокое' };
      showToast(`Качество: ${qLabels[state.quality] || state.quality.toUpperCase()}`);
    });

    // FPS Selector (30 / 60 / 90)
    fpsSelector.addEventListener('click', (e) => {
      const btn = e.target.closest('.segment-btn');
      if (!btn) return;
      fpsSelector.querySelectorAll('.segment-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      state.targetFps = parseInt(btn.getAttribute('data-fps'), 10);
      sendClientConfig();
      showToast(`Частота кадров: ${state.targetFps} FPS`);
    });

    // Scaling Mode (Fit vs Fill)
    scaleSelector.addEventListener('click', (e) => {
      const btn = e.target.closest('.segment-btn');
      if (!btn) return;
      scaleSelector.querySelectorAll('.segment-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      state.scaleMode = btn.getAttribute('data-scale');
      resizeCanvas();
      sendClientConfig();
      showToast(`Масштаб картинки: ${state.scaleMode === 'fill' ? 'Fill (Без полей)' : 'Letterbox (С полями)'}`);
    });

    // UI Scale / Resolution Selector
    const uiScaleSelector = document.getElementById('ui-scale-selector');
    if (uiScaleSelector) {
      uiScaleSelector.addEventListener('click', (e) => {
        const btn = e.target.closest('.segment-btn');
        if (!btn) return;
        uiScaleSelector.querySelectorAll('.segment-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const res = btn.getAttribute('data-res');
        const [w, h] = res.split('x').map(n => parseInt(n, 10));
        if (w && h) {
          sendJson({ type: 'set_resolution', width: w, height: h });
          showToast(`Масштаб интерфейса: ${res}`);
        }
      });
    }

    // Display Selector
    displaySelect.addEventListener('change', () => {
      state.selectedDisplay = parseInt(displaySelect.value, 10);
      sendJson({
        type: 'select_display',
        displayId: state.selectedDisplay
      });
      showToast(`Дисплей переключен: Монитор ${state.selectedDisplay + 1}`);
    });

    // Sticky Modifier Toggles (Cmd, Opt, Ctrl, Shift)
    const setupModifierToggle = (button, modKey) => {
      button.addEventListener('click', () => {
        state.modifiers[modKey] = !state.modifiers[modKey];
        if (state.modifiers[modKey]) {
          button.classList.add('active');
          triggerVibrate(20);
        } else {
          button.classList.remove('active');
        }
      });
    };

    setupModifierToggle(modCmd, 'cmd');
    setupModifierToggle(modOpt, 'opt');
    setupModifierToggle(modCtrl, 'ctrl');
    setupModifierToggle(modShift, 'shift');

    // Quick Utility Keys
    document.querySelectorAll('.key-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        triggerVibrate(15);
        const shortcut = btn.getAttribute('data-shortcut');
        const key = btn.getAttribute('data-key');
        const code = btn.getAttribute('data-code');
        const dataMacKeycode = parseInt(btn.getAttribute('data-mac-keycode') || btn.getAttribute('data-keycode'), 10);

        if (shortcut) {
          sendShortcut(shortcut);
          showToast(`Shortcut: ${shortcut}`);
        } else if (key || code || !isNaN(dataMacKeycode)) {
          const macKeyCode = !isNaN(dataMacKeycode) ? dataMacKeycode : undefined;
          sendKeyEvent('press', { key: key || code, code: code || key, macKeyCode });
          showToast(`Key: ${key || code}`);
        }
      });
    });

    // WakeLock Toggle
    btnWakeLock.addEventListener('click', toggleWakeLock);

    // Fullscreen Toggles
    btnFullscreen.addEventListener('click', toggleFullscreen);
    const btnPillFullscreen = document.getElementById('btn-pill-fullscreen');
    if (btnPillFullscreen) {
      btnPillFullscreen.addEventListener('click', (e) => {
        e.stopPropagation();
        toggleFullscreen();
      });
    }

    // PWA Install Button & Chip
    if (btnPwaInstall) {
      btnPwaInstall.addEventListener('click', () => {
        triggerPwaInstall();
      });
    }
    if (pillPwaChip) {
      pillPwaChip.addEventListener('click', (e) => {
        e.stopPropagation();
        triggerPwaInstall();
      });
    }

    // Manual Reconnect Button
    btnReconnect.addEventListener('click', () => {
      showToast('Reconnecting...');
      if (state.reconnectTimer) {
        clearTimeout(state.reconnectTimer);
        state.reconnectTimer = null;
      }
      state.reconnectAttempts = 0;
      state.candidateIndex = 0;
      if (state.ws) {
        state.ws.onclose = null;
        state.ws.onerror = null;
        try { state.ws.close(); } catch (_) {}
        state.ws = null;
      }
      initWebSocket();
    });

    // Battery Alert Modal
    if (btnCloseBatteryModal) {
      btnCloseBatteryModal.addEventListener('click', (e) => {
        e.stopPropagation();
        dismissBatteryModal();
      });
    }
    if (btnTrafficClose) {
      btnTrafficClose.addEventListener('click', (e) => {
        e.stopPropagation();
        dismissBatteryModal();
      });
    }
    if (btnDismissBattery) {
      btnDismissBattery.addEventListener('click', (e) => {
        e.stopPropagation();
        dismissBatteryModal();
      });
    }
    if (batteryModal) {
      batteryModal.addEventListener('click', (e) => {
        if (e.target === batteryModal) {
          dismissBatteryModal();
        }
      });
    }
    if (pillBattery) {
      pillBattery.addEventListener('click', (e) => {
        e.stopPropagation();
        if (batteryModal) {
          if (batteryModal.classList.contains('hidden')) {
            batteryModal.classList.remove('hidden');
          } else {
            dismissBatteryModal();
          }
        }
      });
    }
  }

  // ============================================================================
  // Screen WakeLock API
  // ============================================================================
  async function toggleWakeLock() {
    if (!('wakeLock' in navigator)) {
      showToast('WakeLock not supported in this browser');
      return;
    }

    if (state.wakeLock) {
      try {
        await state.wakeLock.release();
        state.wakeLock = null;
        state.wakeLockRequested = false;
        btnWakeLock.classList.remove('active');
        showToast('Screen WakeLock Disabled');
      } catch (err) {
        console.error('[DuoDisplay] Error releasing WakeLock:', err);
      }
    } else {
      try {
        state.wakeLock = await navigator.wakeLock.request('screen');
        state.wakeLockRequested = true;
        btnWakeLock.classList.add('active');
        showToast('Screen WakeLock Active');

        state.wakeLock.addEventListener('release', () => {
          if (!state.wakeLockRequested) {
            btnWakeLock.classList.remove('active');
          }
        });
      } catch (err) {
        console.error('[DuoDisplay] WakeLock request error:', err);
        showToast('Failed to enable WakeLock');
      }
    }
  }

  async function releaseWakeLock() {
    if (state.wakeLock) {
      try {
        state.wakeLockRequested = false;
        await state.wakeLock.release();
        state.wakeLock = null;
        if (btnWakeLock) btnWakeLock.classList.remove('active');
      } catch (_) {}
    }
  }

  // Re-acquire WakeLock on visibility change (e.g. tablet screen turned back on)
  document.addEventListener('visibilitychange', async () => {
    if (state.wakeLockRequested && document.visibilityState === 'visible') {
      try {
        state.wakeLock = await navigator.wakeLock.request('screen');
        btnWakeLock.classList.add('active');
      } catch (e) {
        console.warn('[DuoDisplay] Could not re-acquire WakeLock on visibilitychange:', e);
      }
    }
  });

  // Automatically activate WakeLock to keep screen from going to sleep
  async function autoActivateInteraction() {
    if (!state.wakeLock && 'wakeLock' in navigator) {
      try {
        state.wakeLock = await navigator.wakeLock.request('screen');
        state.wakeLockRequested = true;
        if (btnWakeLock) btnWakeLock.classList.add('active');
        console.log('[DuoDisplay] Screen WakeLock active: screen will not sleep');
      } catch (e) {
        // Ignored if user has not interacted yet or permission restricted
      }
    }
  }
  // Try immediate WakeLock request
  autoActivateInteraction();
  document.addEventListener('DOMContentLoaded', autoActivateInteraction);
  window.addEventListener('touchstart', autoActivateInteraction, { passive: true });
  window.addEventListener('pointerdown', autoActivateInteraction, { passive: true });
  window.addEventListener('click', autoActivateInteraction, { passive: true });

  // ============================================================================
  // Fullscreen Management
  // ============================================================================
  function toggleFullscreen() {
    if (!document.fullscreenElement && !document.webkitFullscreenElement) {
      const elem = document.documentElement;
      if (elem.requestFullscreen) {
        elem.requestFullscreen().catch(err => console.warn(err));
      } else if (elem.webkitRequestFullscreen) {
        elem.webkitRequestFullscreen();
      }
      btnFullscreen.classList.add('active');
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen().catch(err => console.warn(err));
      } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen();
      }
      btnFullscreen.classList.remove('active');
    }
  }

  ['fullscreenchange', 'webkitfullscreenchange'].forEach(evt => {
    document.addEventListener(evt, () => {
      if (document.fullscreenElement || document.webkitFullscreenElement) {
        btnFullscreen.classList.add('active');
      } else {
        btnFullscreen.classList.remove('active');
      }
      setTimeout(resizeCanvas, 150);
    });
  });

  // Auto-enter fullscreen gracefully on first user interaction
  let fullscreenAttempted = false;
  function autoEnterFullscreen() {
    if (fullscreenAttempted) return;
    if (!document.fullscreenElement && !document.webkitFullscreenElement) {
      fullscreenAttempted = true;
      const elem = document.documentElement;
      if (elem.requestFullscreen) {
        elem.requestFullscreen().catch(() => {});
      } else if (elem.webkitRequestFullscreen) {
        elem.webkitRequestFullscreen();
      }
    }
  }

  window.addEventListener('touchstart', autoEnterFullscreen, { passive: true, once: true });
  window.addEventListener('click', autoEnterFullscreen, { passive: true, once: true });

  // ============================================================================
  // Application Entrypoint
  // ============================================================================
  function init() {
    resizeCanvas();
    setupToolbarUI();
    setupKeyboardEngine();
    initWebSocket();

    // Browser Battery Status API (tablet local readout)
    if ('getBattery' in navigator) {
      navigator.getBattery().then(batt => {
        const updateLocalBattery = () => {
          const level = Math.round(batt.level * 100);
          const charging = !!batt.charging;
          handleBatteryUpdate(null, { level, charging });
        };
        updateLocalBattery();
        batt.addEventListener('levelchange', updateLocalBattery);
        batt.addEventListener('chargingchange', updateLocalBattery);
      }).catch(() => {});
    }
  }

  // Launch when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
