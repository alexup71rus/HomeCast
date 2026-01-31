const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');
const path = require('path');
const QRCode = require('qrcode');
const os = require('os');
const fs = require('fs');
const pathFs = require('path');

const app = express();
const server = http.createServer(app);
const io = socketIo(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  },
  maxHttpBufferSize: 1e8 // 100 MB для больших фреймов
});

app.use(cors());
app.use(express.json({ limit: '50mb' }));
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

// Хранилище сессий: sessionId -> { viewerSocketId, localUrl }
const sessions = new Map();

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

    sessions.set(sessionId, { viewerSocketId: null, localUrl: null });

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

  if (session.viewerSocketId) {
    io.to(session.viewerSocketId).emit('session-ready', { localUrl });
  }

  console.log('[pair] ok', { sessionId, localUrl, viewerSocketId: session.viewerSocketId });
  return res.json({ ok: true });
});

// API для проверки статуса сессии
app.get('/api/session/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const session = sessions.get(sessionId);
  if (!session) {
    return res.status(404).json({ error: 'session not found' });
  }

  return res.json({
    sessionId,
    localUrl: session.localUrl || null,
  });
});

// Храним активные стримы
const activeStreams = new Map();

io.on('connection', (socket) => {
  console.log('Новое подключение:', socket.id);

  socket.on('watch-session', (data) => {
    const { sessionId } = data || {};
    if (!sessionId) return;
    const session = sessions.get(sessionId) || { viewerSocketId: null, localUrl: null };
    session.viewerSocketId = socket.id;
    sessions.set(sessionId, session);
    console.log('[watch-session]', { sessionId, viewerSocketId: socket.id, localUrl: session.localUrl });
    if (session.localUrl) {
      socket.emit('session-ready', { localUrl: session.localUrl });
    }
  });

  // Обработка подключения стримера (Android устройство)
  socket.on('streamer-join', (data) => {
    const streamId = data.streamId || socket.id;
    activeStreams.set(streamId, {
      streamerId: socket.id,
      viewers: new Set(),
      info: data
    });
    
    socket.streamId = streamId;
    socket.role = 'streamer';
    
    console.log(`Стример подключен: ${streamId}`);
    socket.emit('streamer-ready', { streamId });
    
    // Уведомляем всех о новом стриме
    io.emit('streams-update', Array.from(activeStreams.keys()));
  });

  // Обработка подключения зрителя
  socket.on('viewer-join', (data) => {
    const { streamId } = data;
    const stream = activeStreams.get(streamId);
    
    if (stream) {
      stream.viewers.add(socket.id);
      socket.streamId = streamId;
      socket.role = 'viewer';
      
      console.log(`Зритель подключен к стриму: ${streamId}`);
      socket.emit('viewer-ready', { streamId, viewerId: socket.id });

      // Сообщаем стримеру, что появился новый зритель (для P2P оффера)
      io.to(stream.streamerId).emit('viewer-joined', {
        streamId,
        viewerId: socket.id
      });
    } else {
      socket.emit('error', { message: 'Стрим не найден' });
    }
  });

  // Получение видео фрейма от стримера (fallback, если WebRTC недоступен)
  socket.on('video-frame', (data) => {
    const stream = activeStreams.get(socket.streamId);
    
    if (stream && socket.role === 'streamer') {
      // Отправляем фрейм всем зрителям этого стрима
      stream.viewers.forEach(viewerId => {
        io.to(viewerId).emit('video-frame', data);
      });
    }
  });

  // WebRTC сигналинг (P2P: оффер на конкретного зрителя)
  socket.on('offer', (data) => {
    const stream = activeStreams.get(socket.streamId);
    const targetViewerId = data.viewerId;
    if (stream && socket.role === 'streamer') {
      if (targetViewerId) {
        io.to(targetViewerId).emit('offer', {
          offer: data.offer,
          streamerId: socket.id,
          viewerId: targetViewerId,
          streamId: socket.streamId
        });
      } else {
        // Совместимость со старым клиентом: отправить всем зрителям
        stream.viewers.forEach(viewerId => {
          io.to(viewerId).emit('offer', {
            offer: data.offer,
            streamerId: socket.id,
            viewerId,
            streamId: socket.streamId
          });
        });
      }
    }
  });

  socket.on('answer', (data) => {
    const stream = activeStreams.get(socket.streamId);
    if (stream && socket.role === 'viewer') {
      io.to(stream.streamerId).emit('answer', {
        answer: data.answer,
        viewerId: socket.id,
        streamId: socket.streamId
      });
    }
  });

  socket.on('ice-candidate', (data) => {
    const stream = activeStreams.get(socket.streamId);
    if (stream) {
      if (socket.role === 'streamer') {
        const targetViewerId = data.viewerId;
        if (targetViewerId) {
          io.to(targetViewerId).emit('ice-candidate', {
            candidate: data.candidate,
            from: 'streamer',
            viewerId: targetViewerId,
            streamId: socket.streamId
          });
        } else {
          // Совместимость со старым клиентом: отправить всем зрителям
          stream.viewers.forEach(viewerId => {
            io.to(viewerId).emit('ice-candidate', {
              candidate: data.candidate,
              from: 'streamer',
              viewerId,
              streamId: socket.streamId
            });
          });
        }
      } else if (socket.role === 'viewer') {
        io.to(stream.streamerId).emit('ice-candidate', {
          candidate: data.candidate,
          from: 'viewer',
          viewerId: socket.id,
          streamId: socket.streamId
        });
      }
    }
  });

  // Отключение
  socket.on('disconnect', () => {
    console.log('Отключение:', socket.id);
    
    if (socket.role === 'streamer' && socket.streamId) {
      // Удаляем стрим и уведомляем зрителей
      const stream = activeStreams.get(socket.streamId);
      if (stream) {
        stream.viewers.forEach(viewerId => {
          io.to(viewerId).emit('stream-ended');
        });
        activeStreams.delete(socket.streamId);
        io.emit('streams-update', Array.from(activeStreams.keys()));
      }
    } else if (socket.role === 'viewer' && socket.streamId) {
      // Удаляем зрителя из списка
      const stream = activeStreams.get(socket.streamId);
      if (stream) {
        stream.viewers.delete(socket.id);
        io.to(stream.streamerId).emit('viewer-left', {
          streamId: socket.streamId,
          viewerId: socket.id
        });
      }
    }
  });

  // Получение списка активных стримов
  socket.on('get-streams', () => {
    socket.emit('streams-update', Array.from(activeStreams.keys()));
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Сервер запущен на порту ${PORT}`);
  console.log(`Откройте http://localhost:${PORT} для просмотра`);
  const ip = getLocalIP();
  const baseUrl = process.env.BACKEND_URL || `http://${ip}:${PORT}`;
  writeFlutterConfig(baseUrl);
});
