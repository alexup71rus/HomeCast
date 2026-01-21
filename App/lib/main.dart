import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<int>? _clientSub;
  StreamSubscription<String>? _notificationSub;
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<Uint8List>? _frameSub;

  bool _running = false;
  bool _busy = false;
  String _serverUrl = '-';
  int _clients = 0;
  bool _sharing = false;
  Uri? _backendOverride;
  String? _lastSessionId;
  Uri? _lastBackendUri;
  int _framesReceived = 0;
  double _fps = 0;
  DateTime? _lastFpsTick;
  DateTime? _lastUiUpdate;
  Orientation _deviceOrientation = Orientation.portrait;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateOrientationFromMetrics();

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
    _loadBackendConfig();
    _initDeepLinks();
    Future.microtask(_startServerOnly);
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
    if (state == AppLifecycleState.resumed) {
      if (_busy) return;
      if (!_running) {
        _startServerOnly();
      }
    }
  }

  @override
  void didChangeMetrics() {
    _updateOrientationFromMetrics();
  }

  void _updateOrientationFromMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final size = views.first.physicalSize;
    _deviceOrientation = size.width >= size.height
        ? Orientation.landscape
        : Orientation.portrait;
  }

  Future<void> _ensureServerRunning() async {
    if (_running) return;
    await _server.start();
    final url = await _server.getUrl();
    debugPrint('[HomeCast] Local server started: $url');
    if (!mounted) return;
    setState(() {
      _running = true;
      _serverUrl = url;
    });
  }

  Future<void> _startServerOnly() async {
    if (_busy || _running) return;
    setState(() => _busy = true);
    await _ensureServerRunning();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _startSharing({bool openAfterStart = false}) async {
    if (_busy || _sharing) return;
    setState(() => _busy = true);

    await _ensureServerRunning();
    await WakelockPlus.enable();

    await ScreenCaptureService.start();
    await _frameSub?.cancel();
    _framesReceived = 0;
    _fps = 0;
    _lastFpsTick = DateTime.now();
    _lastUiUpdate = DateTime.now();
    _frameSub = ScreenCaptureService.frames.listen(
      (frame) {
        if (_framesReceived == 0) {
          debugPrint(
            '[HomeCast] First frame received (${frame.lengthInBytes} bytes)',
          );
        }
        _framesReceived++;
        final now = DateTime.now();
        final lastTick = _lastFpsTick;
        if (lastTick != null) {
          final elapsed = now.difference(lastTick);
          if (elapsed.inMilliseconds >= 1000) {
            _fps = _framesReceived / (elapsed.inMilliseconds / 1000.0);
            _framesReceived = 0;
            _lastFpsTick = now;
            final lastUi = _lastUiUpdate ?? now;
            if (now.difference(lastUi).inMilliseconds >= 900 && mounted) {
              setState(() {
                _lastUiUpdate = now;
              });
            }
          }
        }
        _server.broadcastFrame(
          frame,
          meta: {'orientation': _deviceOrientation.name},
        );
      },
      onError: (Object error) {
        debugPrint('[HomeCast] Capture error: $error');
        if (mounted) {
          _stopSharing(); // Clean up generic state
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Трансляция приостановлена (экран был заблокирован)',
              ),
              duration: const Duration(seconds: 10),
              action: SnackBarAction(
                label: 'Возобновить',
                onPressed: () => _startSharing(),
              ),
            ),
          );
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _sharing = true;
      _busy = false;
    });

    await NotificationService.showRunning(url: _serverUrl);

    if (openAfterStart) {
      await _openUrl();
    }
  }

  Future<void> _stopSharing() async {
    if (_busy)
      return; // Allow force stop if not sharing check? removed !_sharing check for internal call validity
    setState(() => _busy = true);

    await _frameSub?.cancel();
    _frameSub = null;
    await ScreenCaptureService.stop();
    await NotificationService.cancelRunning();
    await WakelockPlus.disable();

    if (!mounted) return;
    setState(() {
      _sharing = false;
      _busy = false;
    });
  }

  Future<void> _stopServer() async {
    if (_busy || !_running) return;
    setState(() => _busy = true);

    await _frameSub?.cancel();
    _frameSub = null;
    if (_sharing) {
      await ScreenCaptureService.stop();
    }
    await _server.stop();
    await NotificationService.cancelRunning();

    if (!mounted) return;
    setState(() {
      _running = false;
      _busy = false;
      _serverUrl = '-';
      _clients = 0;
      _sharing = false;
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
      final initial = await _appLinks.getInitialLink();
      await _handleLink(initial);
      _linkSub = _appLinks.uriLinkStream.listen(_handleLink);
    } catch (_) {
      // Игнорируем ошибки deep link на старте
    }
  }

  Future<void> _handleLink(Uri? uri) async {
    if (uri == null || uri.scheme != 'homecast') return;
    final sessionId = uri.queryParameters['session'];
    final backendRaw = uri.queryParameters['backend'];
    debugPrint('[HomeCast] Deep link: $uri');

    if (!_running) {
      await _startServerOnly();
    }

    final localUrl = await _server.getUrl();
    if (mounted) {
      setState(() => _serverUrl = localUrl);
    }

    if (sessionId == null) return;
    _lastSessionId = sessionId;

    Uri? backendUrl;
    if (backendRaw != null) {
      backendUrl = Uri.tryParse(Uri.decodeComponent(backendRaw));
    }
    final backendOverride = _backendOverride;
    final isLocalhost =
        backendUrl != null &&
        (backendUrl.host == 'localhost' || backendUrl.host == '127.0.0.1');

    if (backendOverride != null && (backendUrl == null || isLocalhost)) {
      backendUrl = backendOverride;
    }
    _lastBackendUri = backendUrl;
    debugPrint(
      '[HomeCast] Pairing session=$sessionId backend=${backendUrl ?? 'null'} local=$localUrl',
    );

    if (backendUrl != null) {
      await _pairWithBackend(sessionId, backendUrl, localUrl);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не задан адрес backend сервера')),
      );
    }
  }

  Future<void> _refreshConnection() async {
    if (_busy) return;
    debugPrint('[HomeCast] Refresh requested');
    if (_running) {
      await _stopServer();
    }

    await _startServerOnly();

    if (_lastSessionId == null) return;
    final backendUrl = _lastBackendUri ?? _backendOverride;
    if (backendUrl == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не задан адрес backend сервера')),
      );
      return;
    }

    final localUrl = await _server.getUrl();
    if (mounted) {
      setState(() => _serverUrl = localUrl);
    }
    await _pairWithBackend(_lastSessionId!, backendUrl, localUrl);
  }

  Future<void> _loadBackendConfig() async {
    try {
      final data = await rootBundle.loadString('assets/config.json');
      final json = jsonDecode(data) as Map<String, dynamic>;
      final raw = json['backendBaseUrl'] as String?;
      if (raw != null && raw.isNotEmpty) {
        _backendOverride = Uri.tryParse(raw);
        debugPrint('[HomeCast] Loaded backend override: $raw');
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _pairWithBackend(
    String sessionId,
    Uri backendUrl,
    String localUrl,
  ) async {
    try {
      debugPrint(
        '[HomeCast] POST ${backendUrl.replace(path: '/api/pair')} session=$sessionId local=$localUrl',
      );
      final client = HttpClient();
      final request = await client.postUrl(
        backendUrl.replace(path: '/api/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.add(
        utf8.encode(jsonEncode({'sessionId': sessionId, 'localUrl': localUrl})),
      );
      final response = await request.close();
      await response.drain();
      client.close();
      debugPrint('[HomeCast] Pair response: ${response.statusCode}');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось связаться с сервером')),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Подключено к веб серверу')),
        );
      }
    } catch (e) {
      debugPrint('[HomeCast] Pair error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ошибка связи с сервером')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HomeCast')),
      body: RefreshIndicator(
        onRefresh: _refreshConnection,
        child: ListView(
          padding: const EdgeInsets.all(24),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text(
              _running ? 'Сервер запущен' : 'Сервер остановлен',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(_sharing ? 'Шаринг активен' : 'Шаринг остановлен'),
            if (_sharing) ...[
              const SizedBox(height: 4),
              Text('FPS: ${_fps.toStringAsFixed(1)}'),
            ],
            const SizedBox(height: 12),
            Text('URL: $_serverUrl'),
            const SizedBox(height: 6),
            Text('Подключений: $_clients'),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : (_sharing ? _stopSharing : _startSharing),
                    icon: Icon(_sharing ? Icons.stop : Icons.play_arrow),
                    label: Text(_sharing ? 'Стоп шаринга' : 'Старт шаринга'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Потяните вниз, чтобы перезапустить сервер и переподключиться к облаку.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
