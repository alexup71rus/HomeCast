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

function setConnected(isConnected) {
  statusDot.classList.toggle('connected', isConnected);
}

function connect() {
  const protocol = location.protocol === 'https:' ? 'wss' : 'ws';
  const wsUrl = `${protocol}://${location.host}/ws`;

  ws = new WebSocket(wsUrl);

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
      const msg = JSON.parse(event.data);
      if (msg.type === 'frame' && msg.data) {
        drawFrame(msg.data, msg.meta);
      }
    } catch (e) {
      console.warn('Неверное сообщение', e);
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

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    reconnectDelay = Math.min(reconnectDelay * 2, 8000);
    connect();
  }, reconnectDelay);
}

function drawFrame(dataUrl, meta) {
  const img = new Image();
  img.onload = () => {
    lastImage = img;
    lastMeta = meta || null;
    renderFrame();
  };
  img.src = dataUrl;
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
