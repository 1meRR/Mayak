import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

class WebRtcService {
  static const List<String> fallbackStunServers = <String>[
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
  ];

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

  Map<String, dynamic> buildRtcConfiguration({
    List<String> stunServers = fallbackStunServers,
    List<String> turnServers = const <String>[],
  }) {
    final iceServers = <Map<String, dynamic>>[];

    for (final stun in stunServers) {
      final value = stun.trim();
      if (value.isNotEmpty) {
        iceServers.add({'urls': value});
      }
    }

    for (final turn in turnServers) {
      final value = turn.trim();
      if (value.isNotEmpty) {
        iceServers.add({'urls': value});
      }
    }

    if (iceServers.isEmpty) {
      iceServers.addAll(
        fallbackStunServers.map((value) => {'urls': value}),
      );
    }

    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
  }

  Future<rtc.MediaStream> createLocalStream({
    bool audio = true,
    bool video = true,
  }) {
    final constraints = <String, dynamic>{
      'audio': audio,
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            }
          : false,
    };

    return rtc.navigator.mediaDevices.getUserMedia(constraints);
  }

  Future<rtc.RTCPeerConnection> createPeerConnection({
    required void Function(rtc.RTCIceCandidate candidate) onIceCandidate,
    void Function(rtc.MediaStream stream)? onRemoteStream,
    required void Function(rtc.RTCPeerConnectionState state) onConnectionState,
    void Function(rtc.RTCDataChannel channel)? onDataChannel,
    Map<String, dynamic>? configuration,
  }) async {
    final pc = await rtc.createPeerConnection(
      configuration ?? rtcConfiguration,
    );

    if (onDataChannel != null) {
      pc.onDataChannel = (rtc.RTCDataChannel channel) {
        onDataChannel(channel);
      };
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        onIceCandidate(candidate);
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty && onRemoteStream != null) {
        onRemoteStream(event.streams.first);
      }
    };

    pc.onConnectionState = onConnectionState;

    return pc;
  }

  Future<rtc.RTCDataChannel> createDataChannel(
    rtc.RTCPeerConnection pc,
    String label,
  ) async {
    final rtc.RTCDataChannelInit init = rtc.RTCDataChannelInit()
      ..ordered = true;
    return pc.createDataChannel(label, init);
  }

  Future<void> setMicrophoneEnabled(
    rtc.MediaStream? stream,
    bool enabled,
  ) async {
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = enabled;
    }
  }

  Future<void> setCameraEnabled(
    rtc.MediaStream? stream,
    bool enabled,
  ) async {
    if (stream == null) return;
    for (final track in stream.getVideoTracks()) {
      track.enabled = enabled;
    }
  }

  Future<void> switchCamera(rtc.MediaStream? stream) async {
    if (stream == null) return;
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) return;
    await rtc.Helper.switchCamera(videoTracks.first);
  }

  Future<void> disposeStream(rtc.MediaStream? stream) async {
    if (stream == null) return;

    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {
        // ignore
      }
    }

    try {
      await stream.dispose();
    } catch (_) {
      // ignore
    }
  }
}