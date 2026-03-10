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

int _toMillis(DateTime value) => value.millisecondsSinceEpoch;

class UserProfile {
  final String publicId;
  final String deviceId;
  final String firstName;
  final String lastName;
  final String phone;
  final String about;
  final String serverUrl;
  final DateTime createdAt;
  final bool registered;

  const UserProfile({
    required this.publicId,
    required this.deviceId,
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
    return full.isEmpty ? 'Пользователь' : full;
  }

  UserProfile copyWith({
    String? publicId,
    String? deviceId,
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
      deviceId: deviceId ?? this.deviceId,
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
      deviceId: json['deviceId'] as String? ?? '',
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
      'deviceId': deviceId,
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

class FriendUser {
  final String publicId;
  final String displayName;
  final String about;
  final DateTime createdAt;
  final bool isOnline;
  final DateTime? lastSeenAt;

  const FriendUser({
    required this.publicId,
    required this.displayName,
    required this.about,
    required this.createdAt,
    required this.isOnline,
    required this.lastSeenAt,
  });

  factory FriendUser.fromJson(Map<String, dynamic> json) {
    return FriendUser(
      publicId: json['publicId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'Друг',
      about: json['about'] as String? ?? '',
      createdAt: _parseDateTime(json['createdAt']),
      isOnline: json['isOnline'] as bool? ?? false,
      lastSeenAt:
          json['lastSeenAt'] == null ? null : _parseDateTime(json['lastSeenAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
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
      id: json['id'] as String? ?? '',
      fromPublicId: json['fromPublicId'] as String? ?? '',
      fromDisplayName: json['fromDisplayName'] as String? ?? '',
      toPublicId: json['toPublicId'] as String? ?? '',
      toDisplayName: json['toDisplayName'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: _parseDateTime(json['createdAt']),
      respondedAt:
          json['respondedAt'] == null ? null : _parseDateTime(json['respondedAt']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fromPublicId': fromPublicId,
      'fromDisplayName': fromDisplayName,
      'toPublicId': toPublicId,
      'toDisplayName': toDisplayName,
      'status': status,
      'createdAt': _toMillis(createdAt),
      'respondedAt': respondedAt == null ? null : _toMillis(respondedAt!),
    };
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
  final String id;
  final String callerPublicId;
  final String callerDisplayName;
  final String calleePublicId;
  final String calleeDisplayName;
  final String roomId;
  final String status;
  final DateTime createdAt;
  final DateTime? respondedAt;

  const CallInviteView({
    required this.id,
    required this.callerPublicId,
    required this.callerDisplayName,
    required this.calleePublicId,
    required this.calleeDisplayName,
    required this.roomId,
    required this.status,
    required this.createdAt,
    required this.respondedAt,
  });

  factory CallInviteView.fromJson(Map<String, dynamic> json) {
    return CallInviteView(
      id: json['id'] as String? ?? '',
      callerPublicId: json['callerPublicId'] as String? ?? '',
      callerDisplayName: json['callerDisplayName'] as String? ?? '',
      calleePublicId: json['calleePublicId'] as String? ?? '',
      calleeDisplayName: json['calleeDisplayName'] as String? ?? '',
      roomId: json['roomId'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      createdAt: _parseDateTime(json['createdAt']),
      respondedAt:
          json['respondedAt'] == null ? null : _parseDateTime(json['respondedAt']),
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

class DirectChat {
  final String chatId;
  final String peerPublicId;
  final String peerDisplayName;
  final String previewText;
  final DateTime? updatedAt;
  final int unreadCount;

  const DirectChat({
    required this.chatId,
    required this.peerPublicId,
    required this.peerDisplayName,
    required this.previewText,
    required this.updatedAt,
    required this.unreadCount,
  });
}