import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:uuid/uuid.dart';

import '../models/app_models.dart';
import '../models/p2p_models.dart';
import '../services/api_service.dart';
import '../services/device_socket_service.dart';
import '../services/webrtc_service.dart';

class CallController extends ChangeNotifier {
  CallController({
    required this.profile,
    required this.friend,
    required this.invite,
    required this.api,
    required this.socket,
    required this.isCaller,
    WebRtcService? webrtc,
  }) : _webrtc = webrtc ?? WebRtcService();

  final UserProfile profile;
  final FriendUser friend;
  final CallInviteView invite;
  final ApiService api;
  final DeviceSocketService socket;
  final bool isCaller;
  final WebRtcService _webrtc;

  final rtc.RTCVideoRenderer localRenderer = rtc.RTCVideoRenderer();
  final rtc.RTCVideoRenderer remoteRenderer = rtc.RTCVideoRenderer();
  final Uuid _uuid = const Uuid();

  StreamSubscription<DeviceSignalMessage>? _socketSubscription;
  Timer? _offerRetryTimer;

  rtc.MediaStream? _localStream;
  rtc.MediaStream? _remoteStream;
  rtc.RTCPeerConnection? _peerConnection;
  final List<rtc.RTCIceCandidate> _pendingRemoteCandidates = <rtc.RTCIceCandidate>[];

  PeerDeviceEndpoint? _targetEndpoint;
  String? _targetPublicId;
  String? _targetDeviceId;

  bool _joined = false;
  bool _disposed = false;
  bool _remoteDescriptionSet = false;
  bool _offerSent = false;

  bool _isMicEnabled = true;
  bool get isMicEnabled => _isMicEnabled;

  bool _isCameraEnabled = true;
  bool get isCameraEnabled => _isCameraEnabled;

  bool _isFrontCamera = true;
  bool get isFrontCamera => _isFrontCamera;

  String _connectionText = 'Подготовка звонка...';
  String get connectionText => _connectionText;

  Future<void> join() async {
    if (_joined || _disposed) {
      return;
    }
    _joined = true;

    await localRenderer.initialize();
    await remoteRenderer.initialize();

    if (!socket.isConnected) {
      await socket.connect(profile);
    }

    _socketSubscription = socket.messages.listen(
      (message) async {
        await _handleSignal(message);
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Call socket error: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );

    await _announceOwnDevice();
    await _openLocalMedia();

    if (isCaller) {
      _setConnectionText('Ищем online-устройство собеседника...');
      await _tryStartOffer();
      _offerRetryTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _tryStartOffer(),
      );
    } else {
      _setConnectionText('Ожидаем offer от устройства собеседника...');
    }

    notifyListeners();
  }

  Future<void> _announceOwnDevice() async {
    await api.announceP2pDevice(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      sessionToken: profile.sessionToken,
      platform: defaultTargetPlatform.name,
      appVersion: '0.4.0',
      signalingWsUrl: profile.serverUrl,
      transportPreference: 'webrtc',
      stunServers: WebRtcService.fallbackStunServers,
      turnServers: const <String>[],
      capabilities: const <String, dynamic>{
        'audioCall': true,
        'videoCall': true,
        'directMessages': true,
      },
    );
  }

  Future<void> _openLocalMedia() async {
    _localStream = await _webrtc.createLocalStream(
      audio: true,
      video: true,
    );
    localRenderer.srcObject = _localStream;
  }

  Future<void> _tryStartOffer() async {
    if (_disposed || !isCaller || _offerSent) {
      return;
    }

    final devices = await api.fetchPeerDevices(friend.publicId);
    final onlineDevices = devices
        .where((device) => device.isOnline && device.deviceId != profile.deviceId)
        .toList();

    if (onlineDevices.isEmpty) {
      _setConnectionText('Собеседник ещё не объявил online-устройство, повторяем попытку...');
      return;
    }

    final endpoint = onlineDevices.first;
    _targetEndpoint = endpoint;
    _targetPublicId = endpoint.publicId;
    _targetDeviceId = endpoint.deviceId;

    final pc = await _ensurePeerConnection();
    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(offer);

    final sent = await _sendSignal(
      DeviceSignalMessage(
        type: 'rtc_offer',
        fromPublicId: profile.publicId,
        fromDeviceId: profile.deviceId,
        toPublicId: endpoint.publicId,
        toDeviceId: endpoint.deviceId,
        channel: 'call',
        envelopeId: _uuid.v4(),
        payload: <String, dynamic>{
          'inviteId': invite.inviteId,
          'roomId': invite.roomId,
          'sdp': offer.sdp,
          'sdpType': offer.type,
        },
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    if (sent) {
      _offerSent = true;
      _setConnectionText('Offer отправлен, ожидаем answer...');
    } else {
      _setConnectionText('Не удалось отправить offer, повторяем...');
    }
  }

  Future<rtc.RTCPeerConnection> _ensurePeerConnection() async {
    final existing = _peerConnection;
    if (existing != null) {
      return existing;
    }

    final endpoint = _targetEndpoint;

    final pc = await _webrtc.createPeerConnection(
      configuration: _webrtc.buildRtcConfiguration(
        stunServers: endpoint == null || endpoint.stunServers.isEmpty
            ? WebRtcService.fallbackStunServers
            : endpoint.stunServers,
        turnServers: endpoint?.turnServers ?? const <String>[],
      ),
      onIceCandidate: (candidate) {
        unawaited(_sendIceCandidate(candidate));
      },
      onRemoteStream: (stream) {
        _remoteStream = stream;
        remoteRenderer.srcObject = stream;
        notifyListeners();
      },
      onConnectionState: (state) {
        switch (state) {
          case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _offerRetryTimer?.cancel();
            _setConnectionText('Соединение установлено');
            break;
          case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
            _setConnectionText('Устанавливаем прямое соединение...');
            break;
          case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _setConnectionText('Соединение потеряно');
            break;
          case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _setConnectionText('Не удалось установить P2P-соединение');
            break;
          case rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _setConnectionText('Звонок завершён');
            break;
          default:
            _setConnectionText('Состояние: $state');
            break;
        }
      },
    );

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }

    _peerConnection = pc;
    return pc;
  }

  Future<void> _handleSignal(DeviceSignalMessage signal) async {
    if (_disposed) {
      return;
    }

    if (signal.type != 'rtc_offer' &&
        signal.type != 'rtc_answer' &&
        signal.type != 'rtc_ice') {
      return;
    }

    final payload = _payloadMap(signal);

    if ((payload['roomId']?.toString() ?? '') != invite.roomId) {
      return;
    }

    if (signal.fromPublicId != null &&
        signal.fromPublicId != friend.publicId &&
        signal.fromPublicId != invite.callerPublicId &&
        signal.fromPublicId != invite.calleePublicId) {
      return;
    }

    _targetPublicId = signal.fromPublicId;
    _targetDeviceId = signal.fromDeviceId;

    if (signal.type == 'rtc_offer') {
      await _handleOffer(signal);
      return;
    }

    if (signal.type == 'rtc_answer') {
      await _handleAnswer(signal);
      return;
    }

    if (signal.type == 'rtc_ice') {
      await _handleIce(signal);
    }
  }

  Future<void> _handleOffer(DeviceSignalMessage signal) async {
    final payload = _payloadMap(signal);
    final sdp = payload['sdp']?.toString();
    final sdpType = payload['sdpType']?.toString();
    if (sdp == null || sdpType == null) {
      return;
    }

    _setConnectionText('Получен offer, готовим answer...');
    final pc = await _ensurePeerConnection();

    await pc.setRemoteDescription(
      rtc.RTCSessionDescription(sdp, sdpType),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();

    final answer = await pc.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(answer);

    await _sendSignal(
      DeviceSignalMessage(
        type: 'rtc_answer',
        fromPublicId: profile.publicId,
        fromDeviceId: profile.deviceId,
        toPublicId: signal.fromPublicId,
        toDeviceId: signal.fromDeviceId,
        channel: 'call',
        envelopeId: _uuid.v4(),
        payload: <String, dynamic>{
          'inviteId': invite.inviteId,
          'roomId': invite.roomId,
          'sdp': answer.sdp,
          'sdpType': answer.type,
        },
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    _setConnectionText('Answer отправлен, завершаем ICE...');
  }

  Future<void> _handleAnswer(DeviceSignalMessage signal) async {
    final payload = _payloadMap(signal);
    final sdp = payload['sdp']?.toString();
    final sdpType = payload['sdpType']?.toString();
    if (sdp == null || sdpType == null) {
      return;
    }

    final pc = await _ensurePeerConnection();
    await pc.setRemoteDescription(
      rtc.RTCSessionDescription(sdp, sdpType),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    _setConnectionText('Answer получен, завершаем ICE...');
  }

  Future<void> _handleIce(DeviceSignalMessage signal) async {
    final payload = _payloadMap(signal);
    final candidateText = payload['candidate']?.toString();
    if (candidateText == null || candidateText.trim().isEmpty) {
      return;
    }

    final candidate = rtc.RTCIceCandidate(
      candidateText,
      payload['sdpMid']?.toString(),
      payload['sdpMLineIndex'] is int
          ? payload['sdpMLineIndex'] as int
          : int.tryParse(payload['sdpMLineIndex']?.toString() ?? ''),
    );

    if (_remoteDescriptionSet && _peerConnection != null) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingRemoteCandidates.add(candidate);
    }
  }

  Future<void> _flushPendingCandidates() async {
    if (_peerConnection == null || !_remoteDescriptionSet) {
      return;
    }

    for (final candidate in List<rtc.RTCIceCandidate>.from(_pendingRemoteCandidates)) {
      await _peerConnection!.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  Future<void> _sendIceCandidate(rtc.RTCIceCandidate candidate) async {
    final toPublicId = _targetPublicId;
    final toDeviceId = _targetDeviceId;
    if (toPublicId == null || toDeviceId == null) {
      return;
    }

    await _sendSignal(
      DeviceSignalMessage(
        type: 'rtc_ice',
        fromPublicId: profile.publicId,
        fromDeviceId: profile.deviceId,
        toPublicId: toPublicId,
        toDeviceId: toDeviceId,
        channel: 'call',
        envelopeId: _uuid.v4(),
        payload: <String, dynamic>{
          'inviteId': invite.inviteId,
          'roomId': invite.roomId,
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<bool> _sendSignal(DeviceSignalMessage message) async {
    if (!socket.isConnected) {
      await socket.connect(profile);
    }
    return socket.send(message);
  }

  Map<String, dynamic> _payloadMap(DeviceSignalMessage signal) {
    final payload = signal.payload;
    if (payload == null) {
      return const <String, dynamic>{};
    }
    return payload;
  }

  Future<void> toggleMicrophone() async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }

    _isMicEnabled = !_isMicEnabled;
    await _webrtc.setMicrophoneEnabled(stream, _isMicEnabled);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }

    _isCameraEnabled = !_isCameraEnabled;
    await _webrtc.setCameraEnabled(stream, _isCameraEnabled);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final stream = _localStream;
    if (stream == null) {
      return;
    }

    await _webrtc.switchCamera(stream);
    _isFrontCamera = !_isFrontCamera;
    notifyListeners();
  }

  void _setConnectionText(String value) {
    _connectionText = value;
    notifyListeners();
  }

  Future<void> leave() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    _offerRetryTimer?.cancel();
    await _socketSubscription?.cancel();

    final pc = _peerConnection;
    _peerConnection = null;
    if (pc != null) {
      await pc.close();
      await pc.dispose();
    }

    await _webrtc.disposeStream(_localStream);
    await _webrtc.disposeStream(_remoteStream);
    _localStream = null;
    _remoteStream = null;

    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    await localRenderer.dispose();
    await remoteRenderer.dispose();

    notifyListeners();
  }
}