import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

import '../models/app_models.dart';

class CallController extends ChangeNotifier {
  CallController({
    required this.roomId,
    required this.displayName,
    required this.serverUrl,
    required this.isCaller,
  });

  final String roomId;
  final String displayName;
  final String serverUrl;
  final bool isCaller;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  final List<ChatItem> _chatItems = [];

  List<ChatItem> get chatItems => List.unmodifiable(_chatItems);

  bool _joined = false;
  bool _disposed = false;
  bool _renderersReady = false;

  bool _isMicEnabled = true;
  bool get isMicEnabled => _isMicEnabled;

  bool _isCameraEnabled = true;
  bool get isCameraEnabled => _isCameraEnabled;

  bool _isFrontCamera = true;
  bool get isFrontCamera => _isFrontCamera;

  String _connectionText = 'Подключение...';
  String get connectionText => _connectionText;

  String? _remoteDisplayName;
  String? get remoteDisplayName => _remoteDisplayName;

  String? _peerId;
  String? _remotePeerId;

  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;

  IOWebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;

  bool _creatingOffer = false;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingIce = [];

  Future<void> join() async {
    if (_joined || _disposed) return;
    _joined = true;

    await _initRenderers();
    await _openLocalMedia();
    await _createPeerConnection();
    await _connectSocket();

    _peerId = _buildPeerId();
    _sendSignal(
      SignalMessage(
        type: 'join',
        roomId: roomId,
        peerId: _peerId,
        displayName: displayName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    _setConnectionText(
      isCaller ? 'Ожидаем подключение собеседника...' : 'Ожидаем offer...',
    );
  }

  Future<void> _initRenderers() async {
    if (_renderersReady) return;

    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<void> _openLocalMedia() async {
    final mediaConstraints = <String, dynamic>{
      'audio': <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'googEchoCancellation': true,
        'googNoiseSuppression': true,
        'googAutoGainControl': true,
      },
      'video': <String, dynamic>{
        'facingMode': 'user',
        'width': <String, dynamic>{'ideal': 640},
        'height': <String, dynamic>{'ideal': 480},
        'frameRate': <String, dynamic>{'ideal': 15, 'max': 24},
      },
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      localRenderer.srcObject = _localStream;
      _isCameraEnabled = true;
      _isMicEnabled = true;
    } catch (_) {
      final audioOnlyConstraints = <String, dynamic>{
        'audio': true,
        'video': false,
      };

      _localStream =
          await navigator.mediaDevices.getUserMedia(audioOnlyConstraints);
      localRenderer.srcObject = _localStream;
      _isCameraEnabled = false;
      _isMicEnabled = true;
    }

    notifyListeners();
  }

  Future<void> _createPeerConnection() async {
    final configuration = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    };

    _peerConnection = await createPeerConnection(configuration);

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await _peerConnection!.addTrack(track, stream);
      }
    }

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        _setConnectionText('Соединение установлено');
        notifyListeners();
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_remotePeerId == null) return;
      if (candidate.candidate == null) return;

      _sendSignal(
        SignalMessage(
          type: 'ice_candidate',
          roomId: roomId,
          peerId: _peerId,
          targetPeerId: _remotePeerId,
          candidate: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setConnectionText('Соединение установлено');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _setConnectionText('Соединение...');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setConnectionText('Соединение потеряно');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _setConnectionText('Ошибка соединения');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setConnectionText('Звонок завершён');
          break;
        default:
          break;
      }
      notifyListeners();
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _setConnectionText('Соединение установлено');
      }
      notifyListeners();
    };
  }

  Future<void> _connectSocket() async {
    _channel = IOWebSocketChannel.connect(Uri.parse(serverUrl));

    _socketSubscription = _channel!.stream.listen(
      (dynamic raw) {
        try {
          final decoded = jsonDecode(raw as String);
          if (decoded is! Map) return;

          final message = SignalMessage.fromJson(
            decoded.map((key, value) => MapEntry(key.toString(), value)),
          );

          _handleSignal(message);
        } catch (_) {}
      },
      onDone: () {
        _setConnectionText('Сигналинг отключён');
      },
      onError: (_) {
        _setConnectionText('Ошибка сигналинга');
      },
      cancelOnError: false,
    );
  }

  void _handleSignal(SignalMessage message) {
    if (_disposed) return;

    switch (message.type) {
      case 'existing_peers':
        if (!isCaller) return;
        if (message.peers.isEmpty) return;
        final peer = message.peers.first;
        _remotePeerId = peer.peerId;
        _remoteDisplayName = peer.displayName;
        _maybeCreateOffer();
        break;

      case 'peer_joined':
        if (!isCaller) return;
        if (message.peerId == null || message.peerId == _peerId) return;
        _remotePeerId = message.peerId;
        _remoteDisplayName = message.displayName;
        _maybeCreateOffer();
        break;

      case 'offer':
        _onOffer(message);
        break;

      case 'answer':
        _onAnswer(message);
        break;

      case 'ice_candidate':
        _onIceCandidate(message);
        break;

      case 'chat':
        _onChatMessage(message);
        break;

      case 'peer_left':
        _setConnectionText('Собеседник вышел');
        remoteRenderer.srcObject = null;
        notifyListeners();
        break;
    }
  }

  Future<void> _maybeCreateOffer() async {
    if (_disposed) return;
    if (!isCaller) return;
    if (_creatingOffer) return;
    if (_peerConnection == null) return;
    if (_remotePeerId == null) return;

    try {
      _creatingOffer = true;
      _setConnectionText('Создаём offer...');

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await _peerConnection!.setLocalDescription(offer);

      _sendSignal(
        SignalMessage(
          type: 'offer',
          roomId: roomId,
          peerId: _peerId,
          targetPeerId: _remotePeerId,
          displayName: displayName,
          sdp: offer.sdp,
          sdpType: offer.type,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      _setConnectionText('Offer отправлен');
    } catch (e) {
      _setConnectionText('Ошибка создания offer: $e');
    } finally {
      _creatingOffer = false;
      notifyListeners();
    }
  }

  Future<void> _onOffer(SignalMessage message) async {
    if (_disposed) return;
    if (_peerConnection == null) return;
    if (message.sdp == null || message.sdpType == null) return;

    try {
      _remotePeerId = message.peerId;
      _remoteDisplayName = message.displayName;
      _remoteDescriptionSet = false;

      final description = RTCSessionDescription(
        message.sdp,
        message.sdpType,
      );

      await _peerConnection!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      await _flushPendingIce();

      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      await _peerConnection!.setLocalDescription(answer);

      _sendSignal(
        SignalMessage(
          type: 'answer',
          roomId: roomId,
          peerId: _peerId,
          targetPeerId: _remotePeerId,
          displayName: displayName,
          sdp: answer.sdp,
          sdpType: answer.type,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      _setConnectionText('Answer отправлен');
      notifyListeners();
    } catch (e) {
      _setConnectionText('Ошибка обработки offer: $e');
      notifyListeners();
    }
  }

  Future<void> _onAnswer(SignalMessage message) async {
    if (_disposed) return;
    if (_peerConnection == null) return;
    if (message.sdp == null || message.sdpType == null) return;

    try {
      final current = await _peerConnection!.getRemoteDescription();
      if (current != null && current.sdp == message.sdp) {
        return;
      }

      final description = RTCSessionDescription(
        message.sdp,
        message.sdpType,
      );

      await _peerConnection!.setRemoteDescription(description);
      _remoteDescriptionSet = true;
      await _flushPendingIce();

      _setConnectionText('Answer получен');
      notifyListeners();
    } catch (e) {
      _setConnectionText('Ошибка обработки answer: $e');
      notifyListeners();
    }
  }

  Future<void> _onIceCandidate(SignalMessage message) async {
    if (_disposed) return;
    if (_peerConnection == null) return;
    final data = message.candidate;
    if (data == null) return;

    final candidate = RTCIceCandidate(
      data['candidate']?.toString(),
      data['sdpMid']?.toString(),
      data['sdpMLineIndex'] is int ? data['sdpMLineIndex'] as int : null,
    );

    if (!_remoteDescriptionSet) {
      _pendingIce.add(candidate);
      return;
    }

    try {
      await _peerConnection!.addCandidate(candidate);
    } catch (_) {}
  }

  Future<void> _flushPendingIce() async {
    if (_peerConnection == null) return;
    if (_pendingIce.isEmpty) return;

    for (final candidate in List<RTCIceCandidate>.from(_pendingIce)) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (_) {}
    }
    _pendingIce.clear();
  }

  void _onChatMessage(SignalMessage message) {
    final text = message.text?.trim() ?? '';
    if (text.isEmpty) return;

    final item = ChatItem(
      id: 'remote_${DateTime.now().millisecondsSinceEpoch}',
      peerId: message.peerId ?? '',
      displayName: message.displayName ?? 'Собеседник',
      text: text,
      createdAt: DateTime.now(),
      isLocal: false,
    );

    _chatItems.add(item);
    notifyListeners();
  }

  Future<void> sendChatMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final item = ChatItem(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      peerId: _peerId ?? '',
      displayName: displayName,
      text: trimmed,
      createdAt: DateTime.now(),
      isLocal: true,
    );

    _chatItems.add(item);
    notifyListeners();

    _sendSignal(
      SignalMessage(
        type: 'chat',
        roomId: roomId,
        peerId: _peerId,
        displayName: displayName,
        text: trimmed,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> toggleMicrophone() async {
    final stream = _localStream;
    if (stream == null) return;

    _isMicEnabled = !_isMicEnabled;
    for (final track in stream.getAudioTracks()) {
      track.enabled = _isMicEnabled;
    }
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final stream = _localStream;
    if (stream == null) return;

    _isCameraEnabled = !_isCameraEnabled;
    for (final track in stream.getVideoTracks()) {
      track.enabled = _isCameraEnabled;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null) return;
    final videos = stream.getVideoTracks();
    if (videos.isEmpty) return;

    try {
      await Helper.switchCamera(videos.first);
      _isFrontCamera = !_isFrontCamera;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> shutdown({bool notifyServer = true}) async {
    if (_disposed) return;

    try {
      if (notifyServer) {
        _sendSignal(
          SignalMessage(
            type: 'leave',
            roomId: roomId,
            peerId: _peerId,
            displayName: displayName,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
    } catch (_) {}

    await _socketSubscription?.cancel();
    _socketSubscription = null;

    try {
      await _channel?.sink.close();
    } catch (_) {}

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await stream.dispose();
      } catch (_) {}
    }
    _localStream = null;

    try {
      await _peerConnection?.close();
    } catch (_) {}
    _peerConnection = null;

    remoteRenderer.srcObject = null;
    localRenderer.srcObject = null;

    _setConnectionText('Звонок завершён');
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;

    try {
      localRenderer.dispose();
    } catch (_) {}

    try {
      remoteRenderer.dispose();
    } catch (_) {}

    super.dispose();
  }

  void _sendSignal(SignalMessage message) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(message.toJson()));
  }

  void _setConnectionText(String value) {
    _connectionText = value;
    notifyListeners();
  }

  String _buildPeerId() {
    return 'peer_${DateTime.now().millisecondsSinceEpoch}_${isCaller ? 'caller' : 'callee'}';
  }
}