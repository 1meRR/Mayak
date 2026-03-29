class SignalMessage {
  final String type;
  final String? roomId;
  final String? peerId;
  final String? targetPeerId;
  final String? displayName;
  final String? sdp;
  final String? sdpType;
  final Map<String, dynamic>? candidate;
  final String? text;
  final int? timestamp;
  final List<PeerMeta> peers;

  const SignalMessage({
    required this.type,
    this.roomId,
    this.peerId,
    this.targetPeerId,
    this.displayName,
    this.sdp,
    this.sdpType,
    this.candidate,
    this.text,
    this.timestamp,
    this.peers = const [],
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    final rawPeers = json['peers'];
    List<PeerMeta> parsedPeers = const [];

    if (rawPeers is List) {
      parsedPeers = rawPeers
          .whereType<Map>()
          .map(
            (item) => PeerMeta.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList();
    }

    return SignalMessage(
      type: json['type'] as String? ?? '',
      roomId: json['roomId'] as String?,
      peerId: json['peerId'] as String?,
      targetPeerId: json['targetPeerId'] as String?,
      displayName: json['displayName'] as String?,
      sdp: json['sdp'] as String?,
      sdpType: json['sdpType'] as String?,
      candidate: json['candidate'] is Map
          ? (json['candidate'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : null,
      text: json['text'] as String?,
      timestamp: json['timestamp'] as int?,
      peers: parsedPeers,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (roomId != null) 'roomId': roomId,
      if (peerId != null) 'peerId': peerId,
      if (targetPeerId != null) 'targetPeerId': targetPeerId,
      if (displayName != null) 'displayName': displayName,
      if (sdp != null) 'sdp': sdp,
      if (sdpType != null) 'sdpType': sdpType,
      if (candidate != null) 'candidate': candidate,
      if (text != null) 'text': text,
      if (timestamp != null) 'timestamp': timestamp,
      if (peers.isNotEmpty)
        'peers': peers.map((peer) => peer.toJson()).toList(),
    };
  }
}

class PeerMeta {
  final String peerId;
  final String displayName;

  const PeerMeta({
    required this.peerId,
    required this.displayName,
  });

  factory PeerMeta.fromJson(Map<String, dynamic> json) {
    return PeerMeta(
      peerId: json['peerId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'Unknown',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'peerId': peerId,
      'displayName': displayName,
    };
  }
}

class ChatItem {
  final String id;
  final String peerId;
  final String displayName;
  final String text;
  final DateTime createdAt;
  final bool isLocal;

  const ChatItem({
    required this.id,
    required this.peerId,
    required this.displayName,
    required this.text,
    required this.createdAt,
    required this.isLocal,
  });
}

DateTime _parseDateTime(dynamic value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is String) {
    final parsedInt = int.tryParse(value);
    if (parsedInt != null) {
      return DateTime.fromMillisecondsSinceEpoch(parsedInt);
    }
    final parsedDate = DateTime.tryParse(value);
    if (parsedDate != null) {
      return parsedDate;
    }
  }
  return DateTime.now();
}

DateTime? _parseNullableDateTime(dynamic value) {
  if (value == null) {
    return null;
  }
  return _parseDateTime(value);
}

int _toMillis(DateTime value) => value.millisecondsSinceEpoch;

class UserProfile {
  final String publicId;
  final String friendCode;
  final String deviceId;
  final String sessionToken;
  final String firstName;
  final String lastName;
  final String phone;
  final String about;
  final String serverUrl;
  final DateTime createdAt;
  final bool registered;

  const UserProfile({
    required this.publicId,
    required this.friendCode,
    required this.deviceId,
    required this.sessionToken,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.about,
    required this.serverUrl,
    required this.createdAt,
    required this.registered,
  });

  String get displayName {
    final full = [firstName.trim(), lastName.trim()]
        .where((item) => item.isNotEmpty)
        .join(' ')
        .trim();
    if (full.isNotEmpty) {
      return full;
    }
    if (publicId.trim().isNotEmpty) {
      return publicId.trim();
    }
    return 'Пользователь';
  }

  bool get hasActiveSession =>
      registered &&
      publicId.trim().isNotEmpty &&
      deviceId.trim().isNotEmpty &&
      sessionToken.trim().isNotEmpty;

  UserProfile copyWith({
    String? publicId,
    String? friendCode,
    String? deviceId,
    String? sessionToken,
    String? firstName,
    String? lastName,
    String? phone,
    String? about,
    String? serverUrl,
    DateTime? createdAt,
    bool? registered,
  }) {
    return UserProfile(
      publicId: publicId ?? this.publicId,
      friendCode: friendCode ?? this.friendCode,
      deviceId: deviceId ?? this.deviceId,
      sessionToken: sessionToken ?? this.sessionToken,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      phone: phone ?? this.phone,
      about: about ?? this.about,
      serverUrl: serverUrl ?? this.serverUrl,
      createdAt: createdAt ?? this.createdAt,
      registered: registered ?? this.registered,
    );
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      publicId: json['publicId'] as String? ?? '',
      friendCode: json['friendCode'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      sessionToken: json['sessionToken'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      about: json['about'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? '',
      createdAt: _parseDateTime(json['createdAt']),
      registered: json['registered'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
      'friendCode': friendCode,
      'deviceId': deviceId,
      'sessionToken': sessionToken,
      'firstName': firstName,
      'lastName': lastName,
      'phone': phone,
      'about': about,
      'serverUrl': serverUrl,
      'createdAt': _toMillis(createdAt),
      'registered': registered,
    };
  }
}

class RecoveryCodeView {
  final String code;
  final bool isUsed;
  final DateTime createdAt;
  final DateTime? usedAt;

  const RecoveryCodeView({
    required this.code,
    required this.isUsed,
    required this.createdAt,
    required this.usedAt,
  });

  factory RecoveryCodeView.fromJson(Map<String, dynamic> json) {
    return RecoveryCodeView(
      code: json['code'] as String? ?? '',
      isUsed: json['isUsed'] as bool? ?? false,
      createdAt: _parseDateTime(json['createdAt']),
      usedAt: _parseNullableDateTime(json['usedAt']),
    );
  }
}

class AuthRegisterResult {
  final UserProfile profile;
  final List<RecoveryCodeView> recoveryCodes;

  const AuthRegisterResult({
    required this.profile,
    required this.recoveryCodes,
  });
}

class FriendUser {
  final String publicId;
  final String friendCode;
  final String displayName;
  final String about;
  final DateTime createdAt;
  final bool isOnline;
  final DateTime? lastSeenAt;

  const FriendUser({
    required this.publicId,
    required this.friendCode,
    required this.displayName,
    required this.about,
    required this.createdAt,
    required this.isOnline,
    required this.lastSeenAt,
  });

  factory FriendUser.fromJson(Map<String, dynamic> json) {
    return FriendUser(
      publicId: json['publicId'] as String? ?? '',
      friendCode: json['friendCode'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'Друг',
      about: json['about'] as String? ?? '',
      createdAt: _parseDateTime(json['createdAt']),
      isOnline: json['isOnline'] as bool? ?? false,
      lastSeenAt: _parseNullableDateTime(json['lastSeenAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
      'friendCode': friendCode,
      'displayName': displayName,
      'about': about,
      'createdAt': _toMillis(createdAt),
      'isOnline': isOnline,
      'lastSeenAt': lastSeenAt == null ? null : _toMillis(lastSeenAt!),
    };
  }
}

class FriendRequestView {
  final String id;
  final String fromPublicId;
  final String fromDisplayName;
  final String toPublicId;
  final String toDisplayName;
  final String status;
  final DateTime createdAt;
  final DateTime? respondedAt;

  const FriendRequestView({
    required this.id,
    required this.fromPublicId,
    required this.fromDisplayName,
    required this.toPublicId,
    required this.toDisplayName,
    required this.status,
    required this.createdAt,
    required this.respondedAt,
  });

  factory FriendRequestView.fromJson(Map<String, dynamic> json) {
    return FriendRequestView(
      id: json['id'] as String? ?? json['requestId'] as String? ?? '',
      fromPublicId: json['fromPublicId'] as String? ?? '',
      fromDisplayName: json['fromDisplayName'] as String? ?? '',
      toPublicId: json['toPublicId'] as String? ?? '',
      toDisplayName: json['toDisplayName'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: _parseDateTime(json['createdAt']),
      respondedAt: _parseNullableDateTime(json['respondedAt']),
    );
  }
}

class FriendsBundle {
  final String publicId;
  final List<FriendUser> friends;
  final List<FriendRequestView> incomingRequests;
  final List<FriendRequestView> outgoingRequests;

  const FriendsBundle({
    required this.publicId,
    required this.friends,
    required this.incomingRequests,
    required this.outgoingRequests,
  });

  factory FriendsBundle.empty(String publicId) {
    return FriendsBundle(
      publicId: publicId,
      friends: const [],
      incomingRequests: const [],
      outgoingRequests: const [],
    );
  }

  factory FriendsBundle.fromJson(Map<String, dynamic> json) {
    List<FriendUser> friends = const [];
    List<FriendRequestView> incoming = const [];
    List<FriendRequestView> outgoing = const [];

    if (json['friends'] is List) {
      friends = (json['friends'] as List)
          .whereType<Map>()
          .map(
            (item) => FriendUser.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList();
    }

    if (json['incomingRequests'] is List) {
      incoming = (json['incomingRequests'] as List)
          .whereType<Map>()
          .map(
            (item) => FriendRequestView.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList();
    }

    if (json['outgoingRequests'] is List) {
      outgoing = (json['outgoingRequests'] as List)
          .whereType<Map>()
          .map(
            (item) => FriendRequestView.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList();
    }

    return FriendsBundle(
      publicId: json['publicId'] as String? ?? '',
      friends: friends,
      incomingRequests: incoming,
      outgoingRequests: outgoing,
    );
  }
}

class CallInviteView {
  final String inviteId;
  final String callerPublicId;
  final String callerDisplayName;
  final String calleePublicId;
  final String calleeDisplayName;
  final String roomId;
  final String status;
  final DateTime createdAt;
  final DateTime? respondedAt;

  const CallInviteView({
    required this.inviteId,
    required this.callerPublicId,
    required this.callerDisplayName,
    required this.calleePublicId,
    required this.calleeDisplayName,
    required this.roomId,
    required this.status,
    required this.createdAt,
    required this.respondedAt,
  });

  String get id => inviteId;

  factory CallInviteView.fromJson(Map<String, dynamic> json) {
    return CallInviteView(
      inviteId: json['inviteId'] as String? ?? json['id'] as String? ?? '',
      callerPublicId: json['callerPublicId'] as String? ?? '',
      callerDisplayName: json['callerDisplayName'] as String? ?? '',
      calleePublicId: json['calleePublicId'] as String? ?? '',
      calleeDisplayName: json['calleeDisplayName'] as String? ?? '',
      roomId: json['roomId'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: _parseDateTime(json['createdAt']),
      respondedAt: _parseNullableDateTime(json['respondedAt']),
    );
  }
}

class DirectMessage {
  final String id;
  final String chatId;
  final String authorPublicId;
  final String authorDisplayName;
  final String text;
  final DateTime createdAt;
  final bool isMine;
  final String status;

  const DirectMessage({
    required this.id,
    required this.chatId,
    required this.authorPublicId,
    required this.authorDisplayName,
    required this.text,
    required this.createdAt,
    required this.isMine,
    required this.status,
  });

  factory DirectMessage.fromJson(
    Map<String, dynamic> json, {
    String? myPublicId,
  }) {
    final fromPublicId = json['fromPublicId'] as String? ??
        json['authorPublicId'] as String? ??
        '';
    final toPublicId = json['toPublicId'] as String? ?? '';
    final isMine = myPublicId != null && fromPublicId == myPublicId;

    return DirectMessage(
      id: json['id'] as String? ?? '',
      chatId: json['chatId'] as String? ?? '',
      authorPublicId: fromPublicId,
      authorDisplayName: json['authorDisplayName'] as String? ??
          json['fromDisplayName'] as String? ??
          fromPublicId,
      text: json['text'] as String? ?? '',
      createdAt: _parseDateTime(json['createdAt']),
      isMine: json['isMine'] as bool? ?? isMine,
      status: json['status'] as String? ?? (toPublicId.isEmpty ? 'local' : 'sent'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'authorPublicId': authorPublicId,
      'authorDisplayName': authorDisplayName,
      'text': text,
      'createdAt': _toMillis(createdAt),
      'isMine': isMine,
      'status': status,
    };
  }
}

class PendingOutgoingMessage {
  final String messageId;
  final String chatId;
  final String peerPublicId;
  final String? peerDeviceId;
  final String authorPublicId;
  final String authorDisplayName;
  final String text;
  final DateTime createdAt;
  final String status;
  final String? envelopeId;
  final int retryCount;
  final DateTime? nextRetryAt;
  final String? lastError;

  const PendingOutgoingMessage({
    required this.messageId,
    required this.chatId,
    required this.peerPublicId,
    required this.peerDeviceId,
    required this.authorPublicId,
    required this.authorDisplayName,
    required this.text,
    required this.createdAt,
    required this.status,
    required this.envelopeId,
    required this.retryCount,
    required this.nextRetryAt,
    required this.lastError,
  });
}

class DeviceSignalMessage {
  final String type;
  final String? fromPublicId;
  final String? fromDeviceId;
  final String? toPublicId;
  final String? toDeviceId;
  final String? channel;
  final String? envelopeId;
  final String? ackForEnvelopeId;
  final Map<String, dynamic>? payload;
  final int? timestamp;

  const DeviceSignalMessage({
    required this.type,
    this.fromPublicId,
    this.fromDeviceId,
    this.toPublicId,
    this.toDeviceId,
    this.channel,
    this.envelopeId,
    this.ackForEnvelopeId,
    this.payload,
    this.timestamp,
  });

  factory DeviceSignalMessage.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    final payload = rawPayload is Map
        ? rawPayload.map((key, value) => MapEntry(key.toString(), value))
        : null;

    return DeviceSignalMessage(
      type: json['type'] as String? ?? '',
      fromPublicId: json['fromPublicId'] as String?,
      fromDeviceId: json['fromDeviceId'] as String?,
      toPublicId: json['toPublicId'] as String?,
      toDeviceId: json['toDeviceId'] as String?,
      channel: json['channel'] as String?,
      envelopeId: json['envelopeId'] as String?,
      ackForEnvelopeId: json['ackForEnvelopeId'] as String?,
      payload: payload,
      timestamp: json['timestamp'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (fromPublicId != null) 'fromPublicId': fromPublicId,
      if (fromDeviceId != null) 'fromDeviceId': fromDeviceId,
      if (toPublicId != null) 'toPublicId': toPublicId,
      if (toDeviceId != null) 'toDeviceId': toDeviceId,
      if (channel != null) 'channel': channel,
      if (envelopeId != null) 'envelopeId': envelopeId,
      if (ackForEnvelopeId != null) 'ackForEnvelopeId': ackForEnvelopeId,
      if (payload != null) 'payload': payload,
      if (timestamp != null) 'timestamp': timestamp,
    };
  }
}
