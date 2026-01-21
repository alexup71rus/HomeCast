import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class LocalWebServer {
  LocalWebServer({this.port = 8080});

  final int port;
  HttpServer? _server;
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

    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleRequest, onError: (_) async => stop());
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

  Future<void> broadcastFrame(Uint8List bytes,
      {String mimeType = 'image/jpeg'}) async {
    if (_clients.isEmpty) return;

    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final payload = jsonEncode({'type': 'frame', 'data': dataUrl});

    for (final client in _clients.toList()) {
      if (client.readyState == WebSocket.open) {
        client.add(payload);
      }
    }
  }

  void _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      _clients.add(socket);
      _clientsCountController.add(_clients.length);

      socket.add(jsonEncode({'type': 'status', 'message': 'Подключено'}));
      _broadcastClientCount();

      socket.listen(
        (_) {},
        onDone: () {
          _clients.remove(socket);
          _clientsCountController.add(_clients.length);
          _broadcastClientCount();
        },
        onError: (_) {
          _clients.remove(socket);
          _clientsCountController.add(_clients.length);
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
