import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:app_links/app_links.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'local_server.dart';
import 'notification_service.dart';
import 'screen_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  // Set status bar to transparent to let app background shine through
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const HomeCastApp());
}

class HomeCastApp extends StatelessWidget {
  const HomeCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Custom "Candy" color scheme based on Web styles
    const primaryColor = Color(0xFFCF956B); // Sandstone
    const secondaryColor = Color(0xFFB77850); // Toasted
    const backgroundColor = Color(0xFF1A1A2E); // Dark Navy
    const surfaceColor = Color(0xFF0F1F2A);
    const surfaceAltColor = Color(0xFF122636);

    return MaterialApp(
      title: 'HomeCast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: const ColorScheme.dark(
          primary: primaryColor,
          secondary: secondaryColor,
          surface: surfaceColor,
          surfaceContainer: surfaceAltColor,
          surfaceContainerHigh: Color(0xFF162A3A),
          surfaceContainerLow: Color(0xFF0C1720),
          outlineVariant: Color(0xFF28404F),
          error: Color(0xFFE94560),
        ),
        useMaterial3: true,
        sliderTheme: SliderThemeData(
          activeTrackColor: primaryColor,
          inactiveTrackColor: primaryColor.withOpacity(0.3),
          thumbColor: secondaryColor,
          overlayColor: secondaryColor.withOpacity(0.2),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
          ),
        ),
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
  StreamSubscription<Uint8List>? _audioSub;

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

  // Settings
  double _targetFps = 30;
  double _quality = 60;
  double _bufferMs = 150; // Reduced default latency

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateOrientationFromMetrics();

    _clientSub = _server.clientCountStream.listen((count) {
      if (!mounted) return;
      setState(() => _clients = count);
      // Send config to new clients
      if (count > 0) _sendConfig();
    });

    // ... rest of initState

    _notificationSub = NotificationService.actions.listen((action) {
      if (action == NotificationService.actionStop) {
        _stopServer();
      } else if (action == NotificationService.actionOpen) {
        _openUrl();
      }
    });

    NotificationService.requestPermission();
    if (!kReleaseMode) {
      _loadBackendConfig();
      _initDeepLinks();
    }
    Future.microtask(_startServerOnly);
  }

  void _sendConfig() {
    _server.broadcastConfig({'bufferMs': _bufferMs.toInt()});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameSub?.cancel();
    _audioSub?.cancel();
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

    final audioPermission = await Permission.microphone.request();
    if (audioPermission != PermissionStatus.granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для передачи звука нужно разрешение')),
      );
      setState(() => _busy = false);
      return;
    }

    await WakelockPlus.enable();

    await ScreenCaptureService.start(
      fps: _targetFps.toInt(),
      quality: _quality.toInt(),
    );
    await _frameSub?.cancel();
    await _audioSub?.cancel();
    _framesReceived = 0;
    _fps = 0;
    _lastFpsTick = DateTime.now();
    _lastUiUpdate = DateTime.now();

    _audioSub = ScreenCaptureService.audioFrames.listen((chunk) {
      _server.broadcastAudio(chunk);
    });

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
    if (_busy) {
      return;
    }
    setState(() => _busy = true);

    await _frameSub?.cancel();
    _frameSub = null;
    await _audioSub?.cancel();
    _audioSub = null;

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
    await _audioSub?.cancel();
    _audioSub = null;

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

  Future<void> _openRepo() async {
    const repoUrl = 'https://github.com/alexup71rus/HomeCast';
    final uri = Uri.parse(repoUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть GitHub')),
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
    if (kReleaseMode) return;
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

    if (kReleaseMode) return;

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
    if (kReleaseMode) return;
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
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Column(
        children: [
          _buildHeader(context),

          // Main Content
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshConnection,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Stats Cards
                    if (_sharing) ...[
                      _buildStatsRow(),
                      const SizedBox(height: 24),
                    ],

                    // Connection Info
                    _buildConnectionCard(context),
                    const SizedBox(height: 24),

                    // Settings Section
                    _buildSettingsCard(context),
                    const SizedBox(height: 24),

                    const SizedBox(height: 80), // Space for bottom bar
                  ],
                ),
              ),
            ),
          ),

          // Bottom Action Bar
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final statusColor = _sharing
        ? Theme.of(context).colorScheme.error
        : (_running ? Colors.greenAccent : Colors.grey);
    // Gradient header to match web style
    return Container(
      padding: const EdgeInsets.only(
        left: 24,
        right: 24,
        bottom: 24,
        top: 60,
      ), // Top padding for status bar
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFCF956B), Color(0xFFB77850)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 54,
              height: 54,
              child: Image.asset('assets/logo.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HomeCast',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _sharing
                        ? 'Эфир идет'
                        : (_running ? 'Готов к работе' : 'Остановлен'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withOpacity(0.9),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.github, color: Colors.white),
            onPressed: _openRepo,
            tooltip: 'GitHub',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _busy ? null : _refreshConnection,
            tooltip: 'Перезагрузить сервер',
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            'FPS',
            _fps.toStringAsFixed(1),
            Icons.speed,
            Colors.blueAccent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            'Клиенты',
            '$_clients',
            Icons.people_outline,
            Colors.orangeAccent,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.4),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          Text(label, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildConnectionCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 12,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.link, size: 20),
              const SizedBox(width: 8),
              Text(
                'Локальный адрес',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _openUrl,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _serverUrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const Icon(Icons.open_in_new, size: 16),
                ],
              ),
            ),
          ),
          if (_lastBackendUri != null) ...[
            const SizedBox(height: 12),
            Text(
              'Подключено к облаку: ${_lastBackendUri?.host}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.greenAccent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsCard(BuildContext context) {
    return Card(
      elevation: 4,
      color: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.settings, size: 20, color: Colors.white70),
                  const SizedBox(width: 12),
                  Text(
                    'Настройки трансляции',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _sharing
                        ? null
                        : () {
                            setState(() {
                              _targetFps = 30;
                              _quality = 60;
                              _bufferMs = 150;
                            });
                            _sendConfig();
                          },
                    child: Text(
                      'Сброс',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _buildSlider(
              'Скорость (FPS)',
              '${_targetFps.toInt()}',
              _targetFps,
              10,
              60,
              5,
              (v) => _sharing ? null : setState(() => _targetFps = v),
            ),
            const Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Colors.white10,
            ),
            _buildSlider(
              'Качество (JPEG)',
              '${_quality.toInt()}%',
              _quality,
              10,
              100,
              9,
              (v) => _sharing ? null : setState(() => _quality = v),
            ),
            const Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Colors.white10,
            ),
            _buildSlider(
              'Буфер (Latency)',
              '${_bufferMs.toInt()} ms',
              _bufferMs,
              0,
              500,
              10,
              (v) {
                setState(() => _bufferMs = v);
                _sendConfig();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(
    String title,
    String valueLabel,
    double value,
    double min,
    double max,
    int divisions,
    Function(double)? onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.white70,
                ),
              ),
              Text(
                valueLabel,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: Theme.of(context).colorScheme.secondary,
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      // No decoration or background
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy ? null : (_sharing ? _stopSharing : _startSharing),
        style: FilledButton.styleFrom(
          backgroundColor: _sharing
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.white, // FORCE WHITE TEXT
          // Added large horizontal padding
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 8,
          shadowColor:
              (_sharing
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary)
                  .withOpacity(0.5),
        ),
        icon: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(_sharing ? Icons.stop_circle_outlined : Icons.sensors),
        label: Text(
          _busy
              ? 'Загрузка...'
              : (_sharing ? 'ОСТАНОВИТЬ ТРАНСЛЯЦИЮ' : 'НАЧАТЬ ТРАНСЛЯЦИЮ'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
