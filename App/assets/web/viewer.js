const statusEl = document.getElementById('status');
const clientsEl = document.getElementById('clients');
const canvas = document.getElementById('screen');
const placeholder = document.getElementById('placeholder');
const ctx = canvas.getContext('2d');

let ws;

function setStatus(text, ok = false) {
  statusEl.textContent = text;
  statusEl.style.color = ok ? '#7ee787' : '#9aa3b2';
}

function connect() {
  const protocol = location.protocol === 'https:' ? 'wss' : 'ws';
  const wsUrl = `${protocol}://${location.host}/ws`;

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    setStatus('Подключено', true);
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === 'status') {
        setStatus(msg.message, true);
      }
      if (msg.type === 'clients') {
        clientsEl.textContent = `Клиентов: ${msg.count}`;
      }
      if (msg.type === 'frame' && msg.data) {
        drawFrame(msg.data);
      }
    } catch (e) {
      console.warn('Неверное сообщение', e);
    }
  };

  ws.onclose = () => {
    setStatus('Соединение закрыто');
  };

  ws.onerror = () => {
    setStatus('Ошибка соединения');
  };
}

function drawFrame(dataUrl) {
  const img = new Image();
  img.onload = () => {
    placeholder.style.display = 'none';
    canvas.width = img.width;
    canvas.height = img.height;
    ctx.drawImage(img, 0, 0);
  };
  img.src = dataUrl;
}

connect();
