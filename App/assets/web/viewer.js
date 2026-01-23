const viewer = document.getElementById('viewer');
const statusDot = document.getElementById('status-dot');
const canvas = document.getElementById('screen');
const controls = document.getElementById('controls');
const fullscreenBtn = document.getElementById('fullscreen-btn');
const ctx = canvas.getContext('2d');

let ws;
let reconnectTimer;
let reconnectDelay = 1000;
let lastImage = null;
let lastMeta = null;
let controlsTimer = null;

// Audio
let audioCtx;
let nextAudioTime = 0;
let bufferMs = 150; // default cache

// Precompute u-Law table
const ulawTable = new Float32Array(256);
(function generateUlawTable() {
    for (let i = 0; i < 256; i++) {
        let u_val = ~i;
        let t = ((u_val & 0x0F) << 3) + 0x84;
        t <<= (u_val & 0x70) >> 4;
        ulawTable[i] = ((u_val & 0x80) ? (0x84 - t) : (t - 0x84)) / 32768.0;
    }
})();

function initAudio() {
  if (!audioCtx) {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  }
  if (audioCtx.state === 'suspended') {
    audioCtx.resume();
  }
}

document.addEventListener('click', initAudio);
document.addEventListener('touchstart', initAudio);

function setConnected(isConnected) {
  statusDot.classList.toggle('connected', isConnected);
}

function connect() {
  const protocol = location.protocol === 'https:' ? 'wss' : 'ws';
  const wsUrl = `${protocol}://${location.host}/ws`;

  ws = new WebSocket(wsUrl);
  ws.binaryType = 'arraybuffer';

  ws.onopen = () => {
    setConnected(true);
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    reconnectDelay = 1000;
  };

  ws.onmessage = (event) => {
    try {
      if (event.data instanceof ArrayBuffer) {
         handleBinary(event.data);
      } else if (typeof event.data === 'string') {
         // Legacy text messages (status etc, though we moved major stuff to binary)
         // Keeping for debug logs if any
         console.log('Text msg:', event.data);
      }
    } catch (e) {
      console.warn('Message error', e);
    }
  };

  ws.onclose = () => {
    setConnected(false);
    scheduleReconnect();
  };

  ws.onerror = () => {
    setConnected(false);
    scheduleReconnect();
  };
}

function handleBinary(buffer) {
    const view = new DataView(buffer);
    const type = view.getUint8(0);

    if (type === 0x01) { // AUDIO
        // Payload starts at 1
        // We need to slice it to remove header? 
        // Or playAudio can accept offset. 
        // Making a copy for now to be safe with Web Audio API expectation
        const audioData = buffer.slice(1); 
        playAudio(audioData);
    } else if (type === 0x02) { // VIDEO
        // [1: Type][1-4: MetaLen][Meta][JPEG]
        const metaLen = view.getUint32(1, true); // little endian
        const metaStart = 5;
        const jpgStart = 5 + metaLen;
        
        let meta = {};
        if (metaLen > 0) {
            const metaBytes = new Uint8Array(buffer, metaStart, metaLen);
            const decoder = new TextDecoder();
            try {
                meta = JSON.parse(decoder.decode(metaBytes));
            } catch(e) {}
        }
        
        // Create Blob from the rest
        const jpgBytes = new Uint8Array(buffer, jpgStart);
        const blob = new Blob([jpgBytes], {type: 'image/jpeg'});
        
        drawFrameBlob(blob, meta);
    } else if (type === 0x03) { // CONFIG
        const configBytes = new Uint8Array(buffer, 1);
        const decoder = new TextDecoder();
        try {
            const config = JSON.parse(decoder.decode(configBytes));
            if (config.bufferMs !== undefined) {
                bufferMs = config.bufferMs;
                console.log('Buffer updated to:', bufferMs);
            }
        } catch(e) {}
    }
}

function playAudio(data) {
  if (!audioCtx) return;
  
  // Create AudioBuffer (1 channel - Mono, 48000Hz)
  // Input data is Uint8Array (u-Law)
  const uint8 = new Uint8Array(data);
  const frameCount = uint8.length; 
  const audioBuffer = audioCtx.createBuffer(1, frameCount, 48000);
  const channel = audioBuffer.getChannelData(0);
  
  // u-Law Uint8 -> Float32 using lookup table
  for (let i = 0; i < frameCount; i++) {
    channel[i] = ulawTable[uint8[i]];
  }
  
  const src = audioCtx.createBufferSource();
  src.buffer = audioBuffer;
  src.connect(audioCtx.destination);
  
  const now = audioCtx.currentTime;
  
  // Logic to prevent "crackling" (gaps)
  
  if (nextAudioTime < now) {
      // Underrun detected (we ran out of audio).
      // If we just play "now", we might run out again immediately (jitter).
      // We must buffer a little bit of time (Pre-buffering) to ensure smooth flow.
      const bufferSafety = 0.04; // 40ms safety buffer on underrun
      nextAudioTime = now + bufferSafety;
  } 
  // Drift correction: if we have buffered too much (> 300ms), slightly speed up or skip
  else if (nextAudioTime > now + 0.3) {
      // We are lagging behind real-time too much. 
      // Reset to near-realtime to catch up.
      nextAudioTime = now + 0.05;
  }
  
  src.start(nextAudioTime);
  nextAudioTime += audioBuffer.duration;
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    reconnectDelay = Math.min(reconnectDelay * 2, 8000);
    connect();
  }, reconnectDelay);
}

function drawFrameBlob(blob, meta) {
  // createImageBitmap is much more efficient than new Image() + src=blobUrl
  createImageBitmap(blob).then(bitmap => {
    // Delay video to match audio buffer
    setTimeout(() => {
        if (lastImage && lastImage.close) lastImage.close(); // Cleanup previous if bitmap
        lastImage = bitmap;
        lastMeta = meta || null;
        renderFrame();
    }, bufferMs);
  }).catch(e => console.warn('Frame drop', e));
}

function drawFrame(dataUrl, meta) {
   // Legacy fallback not used anymore in binary mode
}

function renderFrame() {
  if (!lastImage) return;
  const viewportWidth = viewer.clientWidth;
  const viewportHeight = viewer.clientHeight;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.floor(viewportWidth * dpr));
  canvas.height = Math.max(1, Math.floor(viewportHeight * dpr));
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, viewportWidth, viewportHeight);

  // createBitmap returns ImageBitmap which has width/height props
  const frameWidth = lastImage.width;
  const frameHeight = lastImage.height;
  const framePortrait = frameHeight > frameWidth;
  const metaOrientation = lastMeta?.orientation;
  const metaPortrait =
    metaOrientation === 'portrait'
      ? true
      : metaOrientation === 'landscape'
        ? false
        : framePortrait;
  const rotate = metaPortrait !== framePortrait;

  const effectiveWidth = rotate ? frameHeight : frameWidth;
  const effectiveHeight = rotate ? frameWidth : frameHeight;
  const frameAspect = effectiveWidth / effectiveHeight;
  const viewAspect = viewportWidth / viewportHeight;
  const aspectDiff = Math.abs(frameAspect - viewAspect);

  const preferCover =
    lastMeta?.fit === 'cover' || (!metaPortrait && aspectDiff < 0.22);

  const scale = preferCover
    ? Math.max(
        viewportWidth / effectiveWidth,
        viewportHeight / effectiveHeight,
      )
    : Math.min(
        viewportWidth / effectiveWidth,
        viewportHeight / effectiveHeight,
      );

  ctx.save();
  ctx.translate(viewportWidth / 2, viewportHeight / 2);
  if (rotate) {
    ctx.rotate(Math.PI / 2);
  }
  ctx.scale(scale, scale);
  ctx.drawImage(lastImage, -frameWidth / 2, -frameHeight / 2);
  ctx.restore();
}

function showControls() {
  viewer.classList.add('controls-visible');
  if (controlsTimer) {
    clearTimeout(controlsTimer);
  }
  controlsTimer = setTimeout(() => {
    viewer.classList.remove('controls-visible');
  }, 2200);
}

function toggleFullscreen() {
  if (!document.fullscreenElement) {
    viewer.requestFullscreen?.();
  } else {
    document.exitFullscreen?.();
  }
}

function updateFullscreenState() {
  viewer.classList.toggle('is-fullscreen', Boolean(document.fullscreenElement));
}

viewer.addEventListener('mousemove', showControls);
viewer.addEventListener('mouseleave', () => viewer.classList.remove('controls-visible'));
viewer.addEventListener('touchstart', showControls, { passive: true });
viewer.addEventListener('touchmove', showControls, { passive: true });
fullscreenBtn.addEventListener('click', (event) => {
  event.preventDefault();
  toggleFullscreen();
});
document.addEventListener('fullscreenchange', updateFullscreenState);
window.addEventListener('resize', renderFrame);

setConnected(false);
connect();
