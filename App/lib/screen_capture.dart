import 'dart:async';

import 'package:flutter/services.dart';

class ScreenCaptureService {
  static const MethodChannel _methodChannel = MethodChannel(
    'homecast/screencap',
  );
  static const EventChannel _eventChannel = EventChannel(
    'homecast/screencap_frames',
  );
  static const EventChannel _audioEventChannel = EventChannel(
    'homecast/screencap_audio',
  );

  static Stream<Uint8List> get frames {
    return _eventChannel.receiveBroadcastStream().cast<Uint8List>();
  }

  static Stream<Uint8List> get audioFrames {
    return _audioEventChannel.receiveBroadcastStream().cast<Uint8List>();
  }

  static Future<void> start({
    int fps = 30,
    int quality = 60,
    int width = 1280,
  }) async {
    await _methodChannel.invokeMethod('startCapture', {
      'fps': fps,
      'quality': quality,
      'width': width,
    });
  }

  static Future<void> stop() async {
    await _methodChannel.invokeMethod('stopCapture');
  }
}
