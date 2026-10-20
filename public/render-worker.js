// Android Duo - High-Performance OffscreenCanvas Render Worker
// Offloads JPEG decoding (createImageBitmap) and canvas rendering completely
// from the main UI thread, eliminating UI jank and maximizing battery efficiency.

let canvas = null;
let ctx = null;

let scaleMode = 'fill'; // 'fit' | 'fill'
let renderMetrics = {
  scale: 1,
  offsetX: 0,
  offsetY: 0,
  renderWidth: 0,
  renderHeight: 0
};
let remoteWidth = 1280;
let remoteHeight = 800;

let isDecodingJpeg = false;
let latestPendingJpegBuffer = null;
let pendingRenderBitmap = null;
let isRenderRafScheduled = false;
let lastRenderedBitmap = null;

let isMacAsleep = false;
let frameCount = 0;
let lastFpsUpdateTime = performance.now();
let lastReportedFps = 0;

function updateImageSmoothing(destW, destH, srcW, srcH) {
  if (!ctx) return;
  const isOneToOne = (Math.round(destW) === Math.round(srcW) && Math.round(destH) === Math.round(srcH));
  if (isOneToOne) {
    if (ctx.imageSmoothingEnabled !== false) {
      ctx.imageSmoothingEnabled = false;
    }
  } else {
    if (ctx.imageSmoothingEnabled !== true) {
      ctx.imageSmoothingEnabled = true;
    }
    if (ctx.imageSmoothingQuality !== 'high') {
      ctx.imageSmoothingQuality = 'high';
    }
  }
}

function scheduleRenderFrame() {
  if (isRenderRafScheduled) return;
  isRenderRafScheduled = true;
  requestAnimationFrame(renderVsyncFrame);
}

function renderVsyncFrame() {
  isRenderRafScheduled = false;
  if (!ctx || !canvas || !pendingRenderBitmap) return;

  const bitmap = pendingRenderBitmap;
  pendingRenderBitmap = null;

  frameCount++;
  const now = performance.now();
  if (now - lastFpsUpdateTime >= 1000) {
    lastReportedFps = Math.round((frameCount * 1000) / (now - lastFpsUpdateTime));
    frameCount = 0;
    lastFpsUpdateTime = now;
    self.postMessage({
      type: 'fps',
      fps: lastReportedFps
    });
  }

  // Draw frame to OffscreenCanvas
  if (scaleMode === 'fill') {
    updateImageSmoothing(canvas.width, canvas.height, bitmap.width, bitmap.height);
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  } else {
    const { renderWidth: rW, renderHeight: rH, offsetX, offsetY } = renderMetrics;
    if (offsetX > 0 || offsetY > 0) {
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }
    updateImageSmoothing(rW, rH, bitmap.width, bitmap.height);
    ctx.drawImage(bitmap, offsetX, offsetY, rW, rH);
  }

  // Immediately close previous bitmap to free GPU texture memory
  if (lastRenderedBitmap && lastRenderedBitmap !== bitmap) {
    try { lastRenderedBitmap.close(); } catch (_) {}
  }
  lastRenderedBitmap = bitmap;

  if (pendingRenderBitmap) {
    scheduleRenderFrame();
  }
}

async function decodePendingJpeg() {
  if (isDecodingJpeg) return;
  isDecodingJpeg = true;

  while (latestPendingJpegBuffer) {
    const currentBuffer = latestPendingJpegBuffer;
    latestPendingJpegBuffer = null;

    try {
      const blob = new Blob([currentBuffer], { type: 'image/jpeg' });
      const bitmap = await createImageBitmap(blob);

      if (bitmap.width !== remoteWidth || bitmap.height !== remoteHeight) {
        remoteWidth = bitmap.width;
        remoteHeight = bitmap.height;
        self.postMessage({
          type: 'resolution',
          width: remoteWidth,
          height: remoteHeight
        });
      }

      if (pendingRenderBitmap && pendingRenderBitmap !== bitmap) {
        try { pendingRenderBitmap.close(); } catch (_) {}
      }
      pendingRenderBitmap = bitmap;
      scheduleRenderFrame();
    } catch (err) {
      // Decode error / corrupt frame
    }
  }

  isDecodingJpeg = false;
}

// Periodic FPS heartbeat (drops to 0 when screen is static)
setInterval(() => {
  const now = performance.now();
  const elapsed = now - lastFpsUpdateTime;
  if (elapsed >= 1000) {
    lastReportedFps = Math.round((frameCount * 1000) / elapsed);
    frameCount = 0;
    lastFpsUpdateTime = now;
    self.postMessage({
      type: 'fps',
      fps: lastReportedFps
    });
  }
}, 1000);

self.onmessage = function(e) {
  const data = e.data;
  if (!data) return;

  switch (data.type) {
    case 'init': {
      canvas = data.canvas;
      try {
        ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
      } catch (err) {
        ctx = canvas.getContext('2d');
      }
      console.log('[Worker] OffscreenCanvas initialized successfully');
      break;
    }

    case 'frame': {
      if (isMacAsleep) return;
      let buffer = data.buffer;
      if (!buffer || buffer.byteLength < 2) return;
      const view = new DataView(buffer);
      if (view.getUint8(0) === 0x01) {
        buffer = buffer.slice(1);
      }
      latestPendingJpegBuffer = buffer;
      decodePendingJpeg();
      break;
    }

    case 'resize': {
      if (canvas && data.width && data.height) {
        if (canvas.width !== data.width || canvas.height !== data.height) {
          canvas.width = data.width;
          canvas.height = data.height;
        }
      }
      if (data.scaleMode) scaleMode = data.scaleMode;
      if (data.renderMetrics) renderMetrics = data.renderMetrics;
      if (data.remoteWidth) remoteWidth = data.remoteWidth;
      if (data.remoteHeight) remoteHeight = data.remoteHeight;

      // Re-draw last frame on resize
      if (lastRenderedBitmap && ctx && canvas) {
        if (scaleMode === 'fill') {
          updateImageSmoothing(canvas.width, canvas.height, lastRenderedBitmap.width, lastRenderedBitmap.height);
          ctx.drawImage(lastRenderedBitmap, 0, 0, canvas.width, canvas.height);
        } else {
          const { renderWidth: rW, renderHeight: rH, offsetX, offsetY } = renderMetrics;
          if (offsetX > 0 || offsetY > 0) {
            ctx.fillStyle = '#000000';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
          }
          updateImageSmoothing(rW, rH, lastRenderedBitmap.width, lastRenderedBitmap.height);
          ctx.drawImage(lastRenderedBitmap, offsetX, offsetY, rW, rH);
        }
      }
      break;
    }

    case 'power': {
      if (data.state === 'sleep') {
        isMacAsleep = true;
        if (ctx && canvas) {
          ctx.fillStyle = '#000000';
          ctx.fillRect(0, 0, canvas.width, canvas.height);
        }
        if (pendingRenderBitmap) {
          try { pendingRenderBitmap.close(); } catch (_) {}
          pendingRenderBitmap = null;
        }
        if (lastRenderedBitmap) {
          try { lastRenderedBitmap.close(); } catch (_) {}
          lastRenderedBitmap = null;
        }
      } else if (data.state === 'wake') {
        isMacAsleep = false;
      }
      break;
    }

    case 'clear': {
      if (ctx && canvas) {
        ctx.fillStyle = '#000000';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
      }
      break;
    }
  }
};
