const qrSection = document.getElementById('qr-section');
const viewerSection = document.getElementById('viewer-section');
const statusText = document.querySelector('.status-text');
const statusIndicator = document.querySelector('.status-indicator');

let currentSessionId = null;
let redirectDone = false;
let pollTimer = null;
let sse = null;

init();

function init() {
    loadQRCode();
}

async function loadQRCode() {
    try {
        const response = await fetch('/api/session');
        const data = await response.json();

        const qrImage = document.getElementById('qr-code');
        qrImage.src = data.qrCode;
        qrImage.classList.add('loaded');

        currentSessionId = data.sessionId;
        updateStatus('connecting', 'Ожидание подключения устройства...');
        startSse();
    } catch (error) {
        console.error('Ошибка загрузки QR кода:', error);
        document.querySelector('.qr-loading').textContent = 'Ошибка загрузки QR кода';
        updateStatus('error', 'Не удалось получить QR код');
    }
}

function startSse() {
    if (!currentSessionId || sse) return;
    sse = new EventSource(`/api/session/${currentSessionId}/stream`);
    sse.addEventListener('ready', (event) => {
        try {
            const data = JSON.parse(event.data);
            if (data && data.localUrl) {
                redirectToLocal(data.localUrl);
            }
        } catch (_) {
            // ignore
        }
    });
    sse.onerror = () => {
        if (sse) {
            sse.close();
            sse = null;
        }
        startPolling();
    };
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
    if (sse) {
        sse.close();
        sse = null;
    }
    if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = null;
    }
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
