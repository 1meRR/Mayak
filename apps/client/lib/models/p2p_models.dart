class PeerDeviceEndpoint {
  final String publicId;
  final String deviceId;
  final bool isOnline;
  final DateTime? lastSeenAt;
  final String platform;
  final String appVersion;
  final String signalingWsUrl;
  final String transportPreference;
  final List<String> stunServers;
  final List<String> turnServers;
  final Map<String, dynamic> capabilities;

  const PeerDeviceEndpoint({
    required this.publicId,
    required this.deviceId,
    required this.isOnline,
    required this.lastSeenAt,
    required this.platform,
    required this.appVersion,
    required this.signalingWsUrl,
    required this.transportPreference,
    required this.stunServers,
    required this.turnServers,
    required this.capabilities,
  });

  factory PeerDeviceEndpoint.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = rawCapabilities is Map
        ? rawCapabilities.map(
            (key, value) => MapEntry(key.toString(), value),
          )
        : <String, dynamic>{};

    return PeerDeviceEndpoint(
      publicId: json['publicId']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      isOnline: json['isOnline'] as bool? ?? false,
      lastSeenAt: _parseNullableDateTime(json['lastSeenAt']),
      platform: json['platform']?.toString() ?? '',
      appVersion: json['appVersion']?.toString() ?? '',
      signalingWsUrl: json['signalingWsUrl']?.toString() ?? '',
      transportPreference:
          json['transportPreference']?.toString() ?? 'webrtc',
      stunServers: _toStringList(json['stunServers']),
      turnServers: _toStringList(json['turnServers']),
      capabilities: capabilities,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
      'deviceId': deviceId,
      'isOnline': isOnline,
      'lastSeenAt': lastSeenAt?.millisecondsSinceEpoch,
      'platform': platform,
      'appVersion': appVersion,
      'signalingWsUrl': signalingWsUrl,
      'transportPreference': transportPreference,
      'stunServers': stunServers,
      'turnServers': turnServers,
      'capabilities': capabilities,
    };
  }
}

class PeerDevicesResponse {
  final String publicId;
  final List<PeerDeviceEndpoint> devices;

  const PeerDevicesResponse({
    required this.publicId,
    required this.devices,
  });

  factory PeerDevicesResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['devices'] ?? json['items'];
    final devices = raw is List
        ? raw
            .whereType<Map>()
            .map(
              (item) => PeerDeviceEndpoint.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList()
        : <PeerDeviceEndpoint>[];

    return PeerDevicesResponse(
      publicId: json['publicId']?.toString() ?? '',
      devices: devices,
    );
  }
}

DateTime? _parseNullableDateTime(dynamic value) {
  if (value == null) {
    return null;
  }

  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  if (value is String) {
    final millis = int.tryParse(value);
    if (millis != null) {
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }

    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }

  return null;
}

List<String> _toStringList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return value.map((item) => item.toString()).toList();
}
