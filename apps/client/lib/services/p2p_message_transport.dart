import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../models/app_models.dart';
import 'signaling_service.dart';
import 'webrtc_service.dart';

class P2PMessageTransport {
  final SignalingService signaling;
  final WebRtcService webrtc = WebRtcService();
  final String myPublicId;
  final String peerPublicId;
  final String roomId;
  
  rtc.RTCPeerConnection? _pc;
  rtc.RTCDataChannel? _dataChannel;
  
  final StreamController<DirectMessage> _onMessageReceived = StreamController.broadcast();
  final StreamController<String> _onMessageAck = StreamController.broadcast();

  Stream<DirectMessage> get onMessageReceived => _onMessageReceived.stream;
  Stream<String> get onMessageAck => _onMessageAck.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  P2PMessageTransport({
    required this.signaling,
    required this.myPublicId,
    required this.peerPublicId,
    required this.roomId,
  });

  Future<void> initializeAsCaller() async {
    _pc = await _setupPeerConnection();
    _dataChannel = await webrtc.createDataChannel(_pc!, 'chat_data');
    _setupDataChannel(_dataChannel!);

    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);

    signaling.send(
      SignalMessage(
        type: 'offer',
        roomId: roomId,
        peerId: myPublicId,
        targetPeerId: peerPublicId,
        sdp: offer.sdp,
        sdpType: offer.type,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> handleOffer(SignalMessage offerMessage) async {
    if (offerMessage.sdp == null) return;

    _pc = await _setupPeerConnection();
    await _pc!.setRemoteDescription(
      rtc.RTCSessionDescription(offerMessage.sdp, offerMessage.sdpType),
    );

    final answer = await _pc!.createAnswer({});
    await _pc!.setLocalDescription(answer);

    signaling.send(
      SignalMessage(
        type: 'answer',
        roomId: roomId,
        peerId: myPublicId,
        targetPeerId: peerPublicId,
        sdp: answer.sdp,
        sdpType: answer.type,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> handleAnswer(SignalMessage answerMessage) async {
    if (_pc == null || answerMessage.sdp == null) return;
    await _pc!.setRemoteDescription(
      rtc.RTCSessionDescription(answerMessage.sdp, answerMessage.sdpType),
    );
  }

  Future<void> handleIceCandidate(SignalMessage iceMessage) async {
    if (_pc == null || iceMessage.candidate == null) return;
    final candidateData = iceMessage.candidate!;
    
    final candidate = rtc.RTCIceCandidate(
      candidateData['candidate']?.toString(),
      candidateData['sdpMid']?.toString(),
      candidateData['sdpMLineIndex'] is int ? candidateData['sdpMLineIndex'] as int : null,
    );
    await _pc!.addCandidate(candidate);
  }

  Future<rtc.RTCPeerConnection> _setupPeerConnection() async {
    return await webrtc.createPeerConnection(
      onIceCandidate: (candidate) {
        signaling.send(
          SignalMessage(
            type: 'ice_candidate',
            roomId: roomId,
            peerId: myPublicId,
            targetPeerId: peerPublicId,
            candidate: {
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            },
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      },
      onConnectionState: (state) {
        if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _isConnected = true;
        } else if (state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                   state == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _isConnected = false;
        }
      },
      onDataChannel: (channel) {
        _dataChannel = channel;
        _setupDataChannel(channel);
      },
    );
  }

  void _setupDataChannel(rtc.RTCDataChannel channel) {
    channel.onMessage = (rtc.RTCDataChannelMessage message) {
      if (message.isBinary) return; // Бинарные данные для файлов добавим позже
      
      try {
        final Map<String, dynamic> data = jsonDecode(message.text);
        
        if (data['type'] == 'message') {
          final dm = DirectMessage.fromJson(data['payload'], myPublicId: myPublicId);
          _onMessageReceived.add(dm);
          
          // Отправляем ACK обратно
          _sendAck(dm.id);
        } else if (data['type'] == 'ack') {
          _onMessageAck.add(data['messageId']);
        }
      } catch (e) {
        debugPrint('Ошибка обработки сообщения из DataChannel: $e');
      }
    };

    channel.onDataChannelState = (rtc.RTCDataChannelState state) {
      if (state == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        _isConnected = true;
      } else {
        _isConnected = false;
      }
    };
  }

  void sendMessage(DirectMessage message) {
    if (_dataChannel != null && _isConnected) {
      final payload = jsonEncode({
        'type': 'message',
        'payload': message.toJson(),
      });
      _dataChannel!.send(rtc.RTCDataChannelMessage(payload));
    } else {
      throw Exception('DataChannel не подключен');
    }
  }

  void _sendAck(String messageId) {
    if (_dataChannel != null && _isConnected) {
      final payload = jsonEncode({
        'type': 'ack',
        'messageId': messageId,
      });
      _dataChannel!.send(rtc.RTCDataChannelMessage(payload));
    }
  }

  Future<void> dispose() async {
    _isConnected = false;
    await _dataChannel?.close();
    await _pc?.close();
    await _onMessageReceived.close();
    await _onMessageAck.close();
  }
}