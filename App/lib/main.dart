import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uni_links/uni_links.dart';

import 'local_server.dart';
import 'notification_service.dart';
import 'screen_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const HomeCastApp());
}

class HomeCastApp extends StatelessWidget {
  const HomeCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeCast',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeCastHomePage(),
    );
  }
}

class HomeCastHomePage extends StatefulWidget {
  const HomeCastHomePage({super.key});

  @override
  State<HomeCastHomePage> createState() => _HomeCastHomePageState();
}

class _HomeCastHomePageState extends State<HomeCastHomePage>
  with WidgetsBindingObserver {
  final LocalWebServer _server = LocalWebServer(port: 8080);
  StreamSubscription<int>? _clientSub;
  StreamSubscription<String>? _notificationSub;
  StreamSubscription<String?>? _linkSub;
  StreamSubscription<Uint8List>? _frameSub;

  bool _running = false;
  bool _busy = false;
  String _serverUrl = '-';
  int _clients = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _clientSub = _server.clientCountStream.listen((count) {
      if (!mounted) return;
      setState(() => _clients = count);
    });

    _notificationSub = NotificationService.actions.listen((action) {
      if (action == NotificationService.actionStop) {
        _stopServer();
      } else if (action == NotificationService.actionOpen) {
        _openUrl();
      }
    });

    NotificationService.requestPermission();
    _initDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameSub?.cancel();
    _clientSub?.cancel();
    _notificationSub?.cancel();
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _stopServer();
    }
  }

  Future<void> _startServer({bool openAfterStart = false}) async {
    if (_busy || _running) return;
    setState(() => _busy = true);

    await _server.start();
    final url = await _server.getUrl();

    await ScreenCaptureService.start();
    await _frameSub?.cancel();
    _frameSub = ScreenCaptureService.frames.listen((frame) {
      _server.broadcastFrame(frame);
    });

    if (!mounted) return;
    setState(() {
      _running = true;
      _busy = false;
      _serverUrl = url;
    });

    await NotificationService.showRunning(url: url);

    if (openAfterStart) {
      await _openUrl();
    }
  }

  Future<void> _stopServer() async {
    if (_busy || !_running) return;
    setState(() => _busy = true);

    await _frameSub?.cancel();
    _frameSub = null;
    await ScreenCaptureService.stop();
    await _server.stop();
    await NotificationService.cancelRunning();

    if (!mounted) return;
    setState(() {
      _running = false;
      _busy = false;
      _serverUrl = '-';
      _clients = 0;
    });
  }

  Future<void> _openUrl() async {
    if (_serverUrl == '-') return;
    final uri = Uri.parse(_serverUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку')),
      );
    }
  }

  Future<void> _initDeepLinks() async {
    try {
      final initial = await getInitialLink();
      await _handleLink(initial);
      _linkSub = linkStream.listen(_handleLink);
    } catch (_) {
      // Игнорируем ошибки deep link на старте
    }
  }

  Future<void> _handleLink(String? link) async {
    if (link == null) return;
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'homecast') return;
    final sessionId = uri.queryParameters['session'];
    final backendRaw = uri.queryParameters['backend'];

    if (!_running) {
      await _startServer();
    }

    final localUrl = await _server.getUrl();
    if (mounted) {
      setState(() => _serverUrl = localUrl);
    }

    if (sessionId != null && backendRaw != null) {
      final backendUrl = Uri.tryParse(Uri.decodeComponent(backendRaw));
      if (backendUrl != null) {
        await _pairWithBackend(sessionId, backendUrl, localUrl);
      }
    }
  }

  Future<void> _pairWithBackend(
      String sessionId, Uri backendUrl, String localUrl) async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        backendUrl.replace(path: '/api/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(
        jsonEncode({'sessionId': sessionId, 'localUrl': localUrl}),
      ));
      final response = await request.close();
      await response.drain();
      client.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось связаться с сервером')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ошибка связи с сервером')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HomeCast'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _running ? 'Сервер запущен' : 'Сервер остановлен',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text('URL: $_serverUrl'),
            const SizedBox(height: 6),
            Text('Подключений: $_clients'),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy || _running ? null : _startServer,
                    icon: const Icon(Icons.wifi),
                    label: const Text('Подключить'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || !_running ? null : _stopServer,
                    icon: const Icon(Icons.stop),
                    label: const Text('Отключить'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Откройте локальный URL в браузере для просмотра потока.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
