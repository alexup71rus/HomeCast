const socket = io();

const qrSection = document.getElementById('qr-section');
const viewerSection = document.getElementById('viewer-section');
const statusText = document.querySelector('.status-text');
const statusIndicator = document.querySelector('.status-indicator');

let currentSessionId = null;
let redirectDone = false;
let pollTimer = null;

init();

function init() {
    loadQRCode();
    setupSocketListeners();
}

async function loadQRCode() {
    try {
        const response = await fetch('/api/session');
        const data = await response.json();

        const qrImage = document.getElementById('qr-code');
        qrImage.src = data.qrCode;
        qrImage.classList.add('loaded');

        document.getElementById('server-ip').textContent = data.serverInfo.ip;
        document.getElementById('server-port').textContent = data.serverInfo.port;

        currentSessionId = data.sessionId;
        socket.emit('watch-session', { sessionId: data.sessionId });
        updateStatus('connecting', 'Ожидание подключения устройства...');
        startPolling();
    } catch (error) {
        console.error('Ошибка загрузки QR кода:', error);
        document.querySelector('.qr-loading').textContent = 'Ошибка загрузки QR кода';
        updateStatus('error', 'Не удалось получить QR код');
    }
}

function setupSocketListeners() {
    socket.on('session-ready', (data) => {
        if (data && data.localUrl) {
            redirectToLocal(data.localUrl);
        }
    });

    socket.on('connect_error', () => {
        updateStatus('error', 'Ошибка соединения с сервером');
    });
}

function startPolling() {
    if (pollTimer || !currentSessionId) return;
    pollTimer = setInterval(async () => {
        if (redirectDone) return;
        try {
            const res = await fetch(`/api/session/${currentSessionId}`);
            if (!res.ok) return;
            const data = await res.json();
            if (data && data.localUrl) {
                redirectToLocal(data.localUrl);
            }
        } catch (e) {
            // ignore polling errors
        }
    }, 2000);
}

function redirectToLocal(localUrl) {
    if (redirectDone) return;
    redirectDone = true;
    updateStatus('connected', 'Перенаправление...');
    console.log('Redirect to local url:', localUrl);
    window.location.assign(localUrl);
}

function updateStatus(status, text) {
    if (statusText) statusText.textContent = text;
    if (!statusIndicator) return;
    statusIndicator.className = 'status-indicator';
    if (status === 'connected') {
        statusIndicator.classList.add('connected');
    } else if (status === 'error') {
        statusIndicator.classList.add('error');
    }
}
