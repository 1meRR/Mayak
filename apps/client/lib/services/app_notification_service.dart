import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidInit);

    await _plugin.initialize(settings);

    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();

    _initialized = true;
  }

  NotificationDetails _details({
    required String channelId,
    required String channelName,
    required String channelDescription,
    required Importance importance,
    required Priority priority,
    bool playSound = true,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: importance,
        priority: priority,
        playSound: playSound,
      ),
    );
  }

  Future<void> showIncomingMessage({
    required String fromName,
    required String text,
  }) async {
    if (!_initialized) return;
    final preview = text.trim().isEmpty ? 'Новое сообщение' : text.trim();

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch % 2147483647,
      fromName.trim().isEmpty ? 'Новое сообщение' : fromName.trim(),
      preview,
      _details(
        channelId: 'mayak_messages',
        channelName: 'Сообщения',
        channelDescription: 'Уведомления о новых сообщениях',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
  }

  Future<void> showIncomingCall({
    required String fromName,
    required String roomId,
  }) async {
    if (!_initialized) return;

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch % 2147483647,
      'Входящий звонок',
      '${fromName.trim().isEmpty ? 'Неизвестный контакт' : fromName.trim()} • $roomId',
      _details(
        channelId: 'mayak_calls',
        channelName: 'Звонки',
        channelDescription: 'Уведомления о входящих звонках',
        importance: Importance.max,
        priority: Priority.max,
      ),
    );
  }

  void debugLog(Object value) {
    debugPrint('Notification service: $value');
  }
}
