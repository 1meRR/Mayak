import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

class WebRtcService {
  static const Map<String, dynamic> rtcConfiguration = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  static const Map<String, dynamic> mediaConstraints = {
    'audio': true,
    'video': {
      'facingMode': 'user',
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
      'frameRate': {'ideal': 30},
    },
  };

  Future<rtc.MediaStream> createLocalStream() {
    return rtc.navigator.mediaDevices.getUserMedia(mediaConstraints);
  }

  Future<rtc.RTCPeerConnection> createPeerConnection({
    required void Function(rtc.RTCIceCandidate candidate) onIceCandidate,
    required void Function(rtc.MediaStream stream) onRemoteStream,
    required void Function(rtc.RTCPeerConnectionState state) onConnectionState,
  }) async {
    final pc = await rtc.createPeerConnection(rtcConfiguration);

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onIceCandidate(candidate);
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        onRemoteStream(event.streams.first);
      }
    };

    pc.onConnectionState = onConnectionState;

    return pc;
  }
}