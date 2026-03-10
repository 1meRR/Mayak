import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_models.dart';

class SignalingService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final StreamController<SignalMessage> _messageController =
      StreamController<SignalMessage>.broadcast();

  Stream<SignalMessage> get messages => _messageController.stream;

  Future<void> connect(String url) async {
    await disconnect();

    final channel = WebSocketChannel.connect(Uri.parse(url));
    _channel = channel;

    _subscription = channel.stream.listen(
      (event) {
        if (event is! String || event.trim().isEmpty) {
          return;
        }

        final decoded = jsonDecode(event);

        if (decoded is Map<String, dynamic>) {
          _messageController.add(SignalMessage.fromJson(decoded));
          return;
        }

        if (decoded is Map) {
          _messageController.add(
            SignalMessage.fromJson(
              decoded.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _messageController.addError(error, stackTrace);
      },
      onDone: () {},
      cancelOnError: false,
    );
  }

  void send(SignalMessage message) {
    final channel = _channel;
    if (channel == null) {
      return;
    }

    channel.sink.add(jsonEncode(message.toJson()));
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _messageController.close();
  }
}