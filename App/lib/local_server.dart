import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class LocalWebServer {
  LocalWebServer({this.port = 8080});

  final int port;
  HttpServer? _server;
  Future<void>? _starting;
  final Set<WebSocket> _clients = {};
  final StreamController<int> _clientsCountController =
      StreamController<int>.broadcast();

  Stream<int> get clientCountStream => _clientsCountController.stream;

  bool get isRunning => _server != null;

  Future<String> getLocalIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          return address.address;
        }
      }
    }

    return '127.0.0.1';
  }

  Future<String> getUrl() async {
    final ip = await getLocalIp();
    return 'http://$ip:$port';
  }

  Future<void> start() async {
    if (_server != null) return;
    if (_starting != null) {
      await _starting;
      return;
    }

    _starting = () async {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
      debugPrint('[HomeCast] LocalWebServer listening on 0.0.0.0:$port');
      _server!.listen(_handleRequest, onError: (_) async => stop());
    }();

    try {
      await _starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> stop() async {
    for (final client in _clients.toList()) {
      await client.close();
    }
    _clients.clear();
    _clientsCountController.add(_clients.length);

    await _server?.close(force: true);
    _server = null;
  }

  Future<void> broadcastFrame(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
    Map<String, dynamic>? meta,
  }) async {
    if (_clients.isEmpty) return;

    // Protocol: [1 byte Type = 2] [4 bytes Meta Length] [JSON Meta] [JPEG Data]
    // Type 2: Video Frame with Metadata

    final metaJson = jsonEncode(meta ?? {});
    final metaBytes = utf8.encode(metaJson);
    final metaLen = metaBytes.length;

    final packet = Uint8List(1 + 4 + metaLen + bytes.length);
    final view = ByteData.view(packet.buffer);

    packet[0] = 0x02; // VIDEO TYPE
    view.setUint32(1, metaLen, Endian.little);
    packet.setRange(5, 5 + metaLen, metaBytes);
    packet.setRange(5 + metaLen, packet.length, bytes);

    for (final client in _clients.toList()) {
      if (client.readyState == WebSocket.open) {
        client.add(packet);
      }
    }
  }

  Future<void> broadcastAudio(Uint8List bytes) async {
    if (_clients.isEmpty) return;

    // Protocol [1 byte Type] [Payload]
    // Type 1: Audio Chunk
    final packet = Uint8List(1 + bytes.length);
    packet[0] = 0x01; // AUDIO TYPE
    packet.setRange(1, packet.length, bytes);

    for (final client in _clients.toList()) {
      if (client.readyState == WebSocket.open) {
        client.add(packet);
      }
    }
  }

  Future<void> broadcastConfig(Map<String, dynamic> config) async {
    if (_clients.isEmpty) return;

    // Type 3: Config (JSON)
    final jsonBytes = utf8.encode(jsonEncode(config));
    final packet = Uint8List(1 + jsonBytes.length);
    packet[0] = 0x03; // CONFIG TYPE
    packet.setRange(1, packet.length, jsonBytes);

    for (final client in _clients.toList()) {
      if (client.readyState == WebSocket.open) {
        client.add(packet);
      }
    }
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/ws' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      debugPrint('[HomeCast] WS connected from ${socket.hashCode}');
      _clients.add(socket);
      _clientsCountController.add(_clients.length);

      socket.add(jsonEncode({'type': 'status', 'message': 'Подключено'}));
      _broadcastClientCount();

      socket.listen(
        (_) {},
        onDone: () {
          _clients.remove(socket);
          _clientsCountController.add(_clients.length);
          debugPrint('[HomeCast] WS disconnected ${socket.hashCode}');
          _broadcastClientCount();
        },
        onError: (_) {
          _clients.remove(socket);
          _clientsCountController.add(_clients.length);
          debugPrint('[HomeCast] WS error/disconnect ${socket.hashCode}');
          _broadcastClientCount();
        },
      );
      return;
    }

    final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
    await _serveAsset(request, 'assets/web$path');
  }

  Future<void> _serveAsset(HttpRequest request, String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Content-Type', _contentType(assetPath));
      request.response.add(bytes);
    } catch (_) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not found');
    } finally {
      await request.response.close();
    }
  }

  void _broadcastClientCount() {
    if (_clients.isEmpty) return;
    final payload = jsonEncode({'type': 'clients', 'count': _clients.length});
    for (final client in _clients.toList()) {
      if (client.readyState == WebSocket.open) {
        client.add(payload);
      }
    }
  }

  String _contentType(String path) {
    final extension = path.split('.').last.toLowerCase();
    switch (extension) {
      case 'html':
        return 'text/html; charset=utf-8';
      case 'js':
        return 'application/javascript; charset=utf-8';
      case 'css':
        return 'text/css; charset=utf-8';
      case 'svg':
        return 'image/svg+xml';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'ico':
        return 'image/x-icon';
      default:
        return 'application/octet-stream';
    }
  }
}
