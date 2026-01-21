import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class ScreenCaptureService {
  static const MethodChannel _methodChannel =
      MethodChannel('homecast/screencap');
  static const EventChannel _eventChannel =
      EventChannel('homecast/screencap_frames');

  static Stream<Uint8List> get frames {
    return _eventChannel.receiveBroadcastStream().cast<Uint8List>();
  }

  static Future<void> start() async {
    await _methodChannel.invokeMethod('startCapture');
  }

  static Future<void> stop() async {
    await _methodChannel.invokeMethod('stopCapture');
  }
}
