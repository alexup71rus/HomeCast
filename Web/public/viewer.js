const socket = io();

const qrSection = document.getElementById('qr-section');
const viewerSection = document.getElementById('viewer-section');
const statusText = document.querySelector('.status-text');
const statusIndicator = document.querySelector('.status-indicator');

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

        socket.emit('watch-session', { sessionId: data.sessionId });
        updateStatus('connecting', 'Ожидание подключения устройства...');
    } catch (error) {
        console.error('Ошибка загрузки QR кода:', error);
        document.querySelector('.qr-loading').textContent = 'Ошибка загрузки QR кода';
        updateStatus('error', 'Не удалось получить QR код');
    }
}

function setupSocketListeners() {
    socket.on('session-ready', (data) => {
        if (data && data.localUrl) {
            updateStatus('connected', 'Перенаправление...');
            window.location.href = data.localUrl;
        }
    });

    socket.on('connect_error', () => {
        updateStatus('error', 'Ошибка соединения с сервером');
    });
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
