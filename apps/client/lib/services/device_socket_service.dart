import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_models.dart';

class DeviceSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  final StreamController<DeviceSignalMessage> _messagesController =
      StreamController<DeviceSignalMessage>.broadcast();
  final StreamController<bool> _connectedController =
      StreamController<bool>.broadcast();

  String? _activeUrl;
  bool _connected = false;

  Stream<DeviceSignalMessage> get messages => _messagesController.stream;
  Stream<bool> get connectionState => _connectedController.stream;
  bool get isConnected => _connected;

  Uri _buildMailboxWsUri(UserProfile profile) {
    final base = Uri.parse(profile.serverUrl);
    final scheme =
        base.scheme == 'https' || base.scheme == 'wss' ? 'wss' : 'ws';

    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/v1/ws',
      queryParameters: {
        'deviceId': profile.deviceId.trim().toUpperCase(),
        'token': profile.sessionToken.trim(),
      },
    );
  }

  Future<void> connect(UserProfile profile) async {
    if (!profile.hasActiveSession) {
      throw Exception('Нельзя открыть device websocket без активной сессии');
    }

    final mailboxUri = _buildMailboxWsUri(profile);
    final mailboxUrl = mailboxUri.toString();

    if (_connected && _activeUrl == mailboxUrl) {
      return;
    }

    await disconnect();

    final mailboxHeaders = <String, dynamic>{
      'authorization': 'Bearer ${profile.sessionToken.trim()}',
      'x-device-id': profile.deviceId.trim().toUpperCase(),
    };

    await _connectInternal(mailboxUri, headers: mailboxHeaders);
    _activeUrl = mailboxUrl;
  }

  Future<void> _connectInternal(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
    );
    _channel = channel;

    final ready = Completer<void>();
    var firstEventSeen = false;

    _connected = true;
    _connectedController.add(true);

    _subscription = channel.stream.listen(
      (event) {
        firstEventSeen = true;

        if (!ready.isCompleted) {
          ready.complete();
        }

        if (event is! String || event.trim().isEmpty) {
          return;
        }

        final decoded = jsonDecode(event);

        if (decoded is Map<String, dynamic>) {
          _messagesController.add(DeviceSignalMessage.fromJson(decoded));
          return;
        }

        if (decoded is Map) {
          _messagesController.add(
            DeviceSignalMessage.fromJson(
              decoded.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_connected) {
          _connected = false;
          _connectedController.add(false);
        }
        if (!ready.isCompleted) {
          ready.completeError(error, stackTrace);
        }
        _messagesController.addError(error, stackTrace);
      },
      onDone: () {
        if (_connected) {
          _connected = false;
          _connectedController.add(false);
        }
        if (!ready.isCompleted && !firstEventSeen) {
          ready.complete();
        }
      },
      cancelOnError: false,
    );

    await Future.any<void>([
      ready.future,
      Future<void>.delayed(const Duration(seconds: 2)),
    ]);
  }

  bool send(DeviceSignalMessage message) {
    final channel = _channel;
    if (channel == null || !_connected) {
      return false;
    }

    channel.sink.add(jsonEncode(message.toJson()));
    return true;
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;

    try {
      await _channel?.sink.close();
    } catch (_) {
      // ignore
    }

    _channel = null;
    _activeUrl = null;
    if (_connected) {
      _connected = false;
      _connectedController.add(false);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _messagesController.close();
    await _connectedController.close();
  }
}
