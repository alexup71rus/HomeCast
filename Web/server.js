const express = require('express');
const cors = require('cors');
const QRCode = require('qrcode');
const os = require('os');
const fs = require('fs');
const pathFs = require('path');

const app = express();

app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static('public'));

// Получение локального IP (предпочитаем адреса, доступные телефону в LAN)
function getLocalIP() {
  const interfaces = os.networkInterfaces();
  const candidates = [];

  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family !== 'IPv4' || iface.internal) continue;
      const address = iface.address;
      const lowerName = name.toLowerCase();

      let score = 0;
      if (address.startsWith('192.168.')) score += 30;
      else if (address.startsWith('10.')) score += 20;
      else if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(address)) score += 10;

      if (lowerName.includes('wi-fi') || lowerName.includes('wifi')) score += 5;
      if (lowerName.includes('wlan')) score += 5;
      if (lowerName.includes('ethernet')) score += 3;

      candidates.push({ address, score, name });
    }
  }

  candidates.sort((a, b) => b.score - a.score);
  if (candidates.length > 0) {
    return candidates[0].address;
  }

  return 'localhost';
}

function writeFlutterConfig(baseUrl) {
  try {
    const configPath = pathFs.resolve(__dirname, '..', 'App', 'assets', 'config.json');
    const payload = JSON.stringify({ backendBaseUrl: baseUrl }, null, 2);
    fs.writeFileSync(configPath, payload, 'utf8');
    console.log('Flutter config updated:', configPath);
  } catch (error) {
    console.warn('Failed to write Flutter config:', error.message);
  }
}

function getBackendUrl(req) {
  const override = process.env.BACKEND_URL;
  if (override && override.trim().length > 0) return override.trim();
  const protocol = req.headers['x-forwarded-proto'] || req.protocol;
  const port = process.env.PORT || 3000;
  const ip = getLocalIP();
  return `${protocol}://${ip}:${port}`;
}

function generateSessionId() {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

function sendSse(res, event, data) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

// Хранилище сессий: sessionId -> { localUrl, clients }
const sessions = new Map();

// API для получения QR кода с сессией
app.get('/api/session', async (req, res) => {
  try {
    const sessionId = generateSessionId();
    const backendUrl = getBackendUrl(req);
    const url = `homecast://connect?session=${sessionId}&backend=${encodeURIComponent(backendUrl)}`;
    console.log('[session] create', { sessionId, backendUrl });

    const qrCodeDataURL = await QRCode.toDataURL(url, {
      width: 300,
      margin: 2,
      color: {
        dark: '#CF956B',
        light: '#ffffff'
      }
    });

    const localIP = getLocalIP();
    const port = process.env.PORT || 3000;

    sessions.set(sessionId, { localUrl: null, clients: new Set() });

    res.json({
      sessionId,
      qrCode: qrCodeDataURL,
      url,
      serverInfo: {
        ip: localIP,
        port
      }
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// SSE поток статуса сессии
app.get('/api/session/:sessionId/stream', (req, res) => {
  const sessionId = req.params.sessionId;
  const session = sessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'session not found' });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no'
  });
  res.write('retry: 1500\n\n');

  session.clients.add(res);

  req.on('close', () => {
    session.clients.delete(res);
  });

  if (session.localUrl) {
    sendSse(res, 'ready', { localUrl: session.localUrl });
  }
});

// API для пары: мобильное приложение сообщает локальный URL
app.post('/api/pair', (req, res) => {
  const { sessionId, localUrl } = req.body || {};
  console.log('[pair] request', { sessionId, localUrl });
  if (!sessionId || !localUrl) {
    return res.status(400).json({ error: 'sessionId and localUrl required' });
  }

  const session = sessions.get(sessionId);
  if (!session) {
    console.log('[pair] session not found', sessionId);
    return res.status(404).json({ error: 'session not found' });
  }

  session.localUrl = localUrl;
  sessions.set(sessionId, session);

  for (const client of session.clients) {
    sendSse(client, 'ready', { localUrl });
  }

  console.log('[pair] ok', { sessionId, localUrl });
  return res.json({ ok: true });
});

// API для проверки статуса сессии (fallback)
app.get('/api/session/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const session = sessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'session not found' });
  }

  return res.json({
    sessionId,
    localUrl: session.localUrl || null
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`🚀 Server running on http://localhost:${PORT}`);
  const backendUrl = `http://localhost:${PORT}`;
  writeFlutterConfig(backendUrl);
});
