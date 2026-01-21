import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final StreamController<String> _actions =
      StreamController<String>.broadcast();

  static Stream<String> get actions => _actions.stream;

  static const String actionStop = 'action_stop';
  static const String actionOpen = 'action_open';

  static Future<void> initialize() async {
    final androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final initializationSettings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId != null && response.actionId!.isNotEmpty) {
          _actions.add(response.actionId!);
        }
      },
    );
  }

  static Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showRunning({required String url}) async {
    final androidDetails = AndroidNotificationDetails(
      'homecast_connection',
      'HomeCast connection',
      channelDescription: 'Состояние подключения HomeCast',
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true,
      actions: [
        AndroidNotificationAction(actionOpen, 'Открыть'),
        AndroidNotificationAction(actionStop, 'Отключить'),
      ],
    );

    final details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      1001,
      'HomeCast подключен',
      'Локальный сервер: $url',
      details,
      payload: url,
    );
  }

  static Future<void> cancelRunning() async {
    await _plugin.cancel(1001);
  }
}
