import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_models.dart';
import '../models/p2p_models.dart';

class ApiService {
  ApiService(this.serverUrl);

  final String serverUrl;

  Uri _baseUri() {
    final uri = Uri.parse(serverUrl);
    final scheme =
        uri.scheme == 'wss' ? 'https' : uri.scheme == 'ws' ? 'http' : uri.scheme;

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  Uri _uri(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    final base = _baseUri();
    return base.replace(
      path: path,
      queryParameters:
          queryParameters?.map((key, value) => MapEntry(key, value.toString())),
    );
  }

  Future<dynamic> _decodeAny(http.Response response) async {
    final body = response.body.trim();
    if (body.isEmpty) {
      return <String, dynamic>{};
    }

    return jsonDecode(body);
  }

  Future<Map<String, dynamic>> _decodeMap(http.Response response) async {
    final decoded = await _decodeAny(response);

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }

    throw Exception('Некорректный ответ сервера');
  }

  Future<List<dynamic>> _decodeList(http.Response response) async {
    final decoded = await _decodeAny(response);
    if (decoded is List) {
      return decoded;
    }
    throw Exception('Некорректный ответ сервера');
  }

  Map<String, String> _headers({
    String? bearerToken,
    bool json = true,
    String? deviceId,
  }) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (bearerToken != null && bearerToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${bearerToken.trim()}',
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'x-device-id': deviceId.trim().toUpperCase(),
    };
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
    String? bearerToken,
    String? deviceIdHeader,
  }) async {
    late http.Response response;

    final headers = _headers(
      bearerToken: bearerToken,
      deviceId: deviceIdHeader,
    );

    if (method == 'GET') {
      response = await http.get(uri, headers: headers);
    } else if (method == 'POST') {
      response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const <String, dynamic>{}),
      );
    } else {
      throw Exception('Неподдерживаемый HTTP-метод: $method');
    }

    final decoded = await _decodeMap(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final message = decoded['error']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      throw Exception(message);
    }

    throw Exception('HTTP ${response.statusCode}');
  }

  Future<List<dynamic>> _requestList(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
    String? bearerToken,
    String? deviceIdHeader,
  }) async {
    late http.Response response;

    final headers = _headers(
      bearerToken: bearerToken,
      deviceId: deviceIdHeader,
    );

    if (method == 'GET') {
      response = await http.get(uri, headers: headers);
    } else if (method == 'POST') {
      response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const <String, dynamic>{}),
      );
    } else {
      throw Exception('Неподдерживаемый HTTP-метод: $method');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return _decodeList(response);
    }

    final decoded = await _decodeMap(response);
    final message = decoded['error']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      throw Exception(message);
    }

    throw Exception('HTTP ${response.statusCode}');
  }

  UserProfile _profileFromV1AuthResponse(
    Map<String, dynamic> decoded, {
    required String serverUrl,
    required String phone,
  }) {
    final profileMap = decoded['profile'];
    if (profileMap is! Map) {
      throw Exception('Сервер вернул неполный профиль');
    }

    final profile =
        profileMap.map((key, value) => MapEntry(key.toString(), value));
    final displayName = profile['displayName']?.toString().trim() ?? '';
    final nameParts = displayName
        .split(RegExp(r'\s+'))
        .where((item) => item.trim().isNotEmpty)
        .toList();

    final firstName = nameParts.isNotEmpty ? nameParts.first : '';
    final lastName =
        nameParts.length > 1 ? nameParts.skip(1).join(' ') : '';

    return UserProfile(
      publicId: profile['publicId']?.toString() ?? '',
      friendCode: profile['friendCode']?.toString() ?? '',
      deviceId: decoded['deviceId']?.toString() ?? '',
      sessionToken: decoded['sessionToken']?.toString() ?? '',
      firstName: firstName,
      lastName: lastName,
      phone: phone.trim(),
      about: profile['about']?.toString() ?? '',
      serverUrl: serverUrl,
      createdAt: _parseDateTime(profile['createdAt']),
      registered: true,
    );
  }

  Future<AuthRegisterResult> registerWithPhone({
    required String deviceId,
    required String firstName,
    required String lastName,
    required String phone,
    required String password,
    required String about,
  }) async {
    await _request(
      'POST',
      _uri('/v1/auth/register'),
      body: {
        'phoneE164': phone.trim(),
        'password': password,
        'firstName': firstName.trim(),
        'lastName': lastName.trim(),
        'about': about.trim(),
      },
    );

    final profile = await loginWithPhone(
      deviceId: deviceId,
      phone: phone,
      password: password,
    );

    return AuthRegisterResult(
      profile: profile,
      recoveryCodes: const [],
    );
  }

  Future<UserProfile> loginWithPhone({
    required String deviceId,
    required String phone,
    required String password,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/auth/login'),
      body: {
        'phoneE164': phone.trim(),
        'password': password,
        'deviceId': deviceId.trim().toUpperCase(),
        'platform': 'android',
      },
    );

    return _profileFromV1AuthResponse(
      decoded,
      serverUrl: serverUrl,
      phone: phone.trim(),
    );
  }

  Future<void> resetPasswordWithCode({
    required String phone,
    required String recoveryCode,
    required String newPassword,
  }) async {
    await _request(
      'POST',
      _uri('/api/auth/reset-password'),
      body: {
        'phone': phone.trim(),
        'recoveryCode': recoveryCode.trim(),
        'newPassword': newPassword,
      },
    );
  }

  Future<void> heartbeat({
    required String publicId,
    required String deviceId,
    required String sessionToken,
  }) async {
    await _request(
      'POST',
      _uri('/api/presence/heartbeat'),
      body: {
        'publicId': publicId.trim().toUpperCase(),
        'deviceId': deviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
      },
    );
  }

  Future<void> announceP2pDevice({
    required String publicId,
    required String deviceId,
    required String sessionToken,
    required String platform,
    required String appVersion,
    required String signalingWsUrl,
    required String transportPreference,
    required List<String> stunServers,
    required List<String> turnServers,
    required Map<String, dynamic> capabilities,
  }) async {
    await _request(
      'POST',
      _uri('/api/p2p/devices/announce'),
      body: {
        'publicId': publicId.trim().toUpperCase(),
        'deviceId': deviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'platform': platform,
        'appVersion': appVersion,
        'signalingWsUrl': signalingWsUrl,
        'transportPreference': transportPreference,
        'stunServers': stunServers,
        'turnServers': turnServers,
        'capabilities': capabilities,
      },
    );
  }

  Future<void> markP2pDeviceOffline({
    required String publicId,
    required String deviceId,
    required String sessionToken,
  }) async {
    await _request(
      'POST',
      _uri('/api/p2p/devices/offline'),
      body: {
        'publicId': publicId.trim().toUpperCase(),
        'deviceId': deviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
      },
    );
  }

  Future<List<PeerDeviceEndpoint>> fetchPeerDevices(String publicId) async {
    final rawList = await _requestList(
      'GET',
      _uri('/v1/users/${publicId.trim().toUpperCase()}/devices'),
    );

    return rawList
        .whereType<Map>()
        .map((item) {
          final json =
              item.map((key, value) => MapEntry(key.toString(), value));
          return PeerDeviceEndpoint(
            publicId: json['publicId']?.toString() ?? '',
            deviceId: json['deviceId']?.toString() ?? '',
            isOnline: json['isOnline'] as bool? ?? false,
            lastSeenAt: _parseNullableDateTime(json['lastSeenAt']),
            platform: json['platform']?.toString() ?? '',
            appVersion: json['appVersion']?.toString() ?? '',
            signalingWsUrl: serverUrl,
            transportPreference: 'mailbox',
            stunServers: const [],
            turnServers: const [],
            capabilities: json['capabilities'] is Map
                ? (json['capabilities'] as Map)
                    .map((key, value) => MapEntry(key.toString(), value))
                : const <String, dynamic>{},
          );
        })
        .toList();
  }

  Future<FriendUser> lookupUser(String codeOrPublicId) async {
    final normalized = codeOrPublicId.trim().toUpperCase();
    if (normalized.isEmpty) {
      throw Exception('Нужно указать ID или friend code');
    }

    return normalized.startsWith('U') || normalized.startsWith('M')
        ? lookupUserByPublicId(normalized)
        : lookupUserByFriendCode(normalized);
  }

  Future<FriendUser> lookupUserByPublicId(String publicId) async {
    final normalized = publicId.trim().toUpperCase();

    final decoded = await _request(
      'GET',
      _uri('/v1/users/by-public-id/$normalized'),
    );

    final userMap = decoded['user'];
    if (userMap is! Map) {
      throw Exception('Пользователь не найден');
    }

    final user = userMap.map((key, value) => MapEntry(key.toString(), value));
    return FriendUser.fromJson(user);
  }

  Future<FriendUser> lookupUserByFriendCode(String friendCode) async {
    final normalized = friendCode.trim().toUpperCase();

    final decoded = await _request(
      'GET',
      _uri('/v1/users/by-friend-code/$normalized'),
    );

    final userMap = decoded['user'];
    if (userMap is! Map) {
      throw Exception('Пользователь не найден');
    }

    final user = userMap.map((key, value) => MapEntry(key.toString(), value));
    return FriendUser.fromJson(user);
  }

  Future<FriendsBundle> fetchFriends(String publicId) async {
    final normalized = publicId.trim().toUpperCase();

    final decoded = await _request(
      'GET',
      _uri('/v1/friends/$normalized'),
    );

    return FriendsBundle.fromJson(decoded);
  }

  Future<FriendRequestView> createFriendRequest({
    required String fromPublicId,
    required String fromDeviceId,
    required String sessionToken,
    required String toPublicId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/friends/request'),
      body: {
        'fromPublicId': fromPublicId.trim().toUpperCase(),
        'fromDeviceId': fromDeviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'toPublicId': toPublicId.trim().toUpperCase(),
      },
    );

    return FriendRequestView.fromJson(decoded);
  }

  Future<FriendRequestView> respondFriendRequest({
    required String requestId,
    required String actorPublicId,
    required String actorDeviceId,
    required String sessionToken,
    required String action,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/friends/respond'),
      body: {
        'requestId': requestId,
        'actorPublicId': actorPublicId.trim().toUpperCase(),
        'actorDeviceId': actorDeviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'action': action,
      },
    );

    return FriendRequestView.fromJson(decoded);
  }

  Future<CallInviteView> createCallInvite({
    required String callerPublicId,
    required String callerDeviceId,
    required String sessionToken,
    required String calleePublicId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/calls/invite'),
      body: {
        'callerPublicId': callerPublicId.trim().toUpperCase(),
        'callerDeviceId': callerDeviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'calleePublicId': calleePublicId.trim().toUpperCase(),
      },
    );

    return CallInviteView.fromJson(decoded);
  }

  Future<CallInviteView> getCallInvite(String inviteId) async {
    final decoded = await _request(
      'GET',
      _uri('/v1/calls/$inviteId'),
    );

    return CallInviteView.fromJson(decoded);
  }

  Future<List<CallInviteView>> fetchIncomingCalls(String publicId) async {
    final decoded = await _request(
      'GET',
      _uri('/v1/calls/incoming/${publicId.trim().toUpperCase()}'),
    );

    final rawItems = decoded['items'];
    if (rawItems is! List) {
      return const <CallInviteView>[];
    }

    return rawItems
        .whereType<Map>()
        .map(
          (item) => CallInviteView.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  Future<CallInviteView> respondCallInvite({
    required String inviteId,
    required String actorPublicId,
    required String actorDeviceId,
    required String sessionToken,
    required String action,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/calls/respond'),
      body: {
        'inviteId': inviteId,
        'actorPublicId': actorPublicId.trim().toUpperCase(),
        'actorDeviceId': actorDeviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'action': action.trim().toLowerCase(),
      },
    );

    return CallInviteView.fromJson(decoded);
  }

  Future<bool> deleteFriend({
    required String actorPublicId,
    required String actorDeviceId,
    required String sessionToken,
    required String friendPublicId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/friends/delete'),
      body: {
        'actorPublicId': actorPublicId.trim().toUpperCase(),
        'actorDeviceId': actorDeviceId.trim().toUpperCase(),
        'sessionToken': sessionToken.trim(),
        'friendPublicId': friendPublicId.trim().toUpperCase(),
      },
    );

    return decoded['removed'] == true;
  }

  Future<Map<String, dynamic>> ensurePlaceholderMailboxKeyPackage({
    required UserProfile profile,
  }) async {
    final body = {
      'deviceId': profile.deviceId.trim().toUpperCase(),
      'identityKeyAlg': 'x25519+ed25519',
      'identityKeyB64': _placeholderOpaque(
        '${profile.publicId}:${profile.deviceId}:identity',
      ),
      'signedPrekeyB64': _placeholderOpaque(
        '${profile.publicId}:${profile.deviceId}:signed-prekey',
      ),
      'signedPrekeySignatureB64': _placeholderOpaque(
        '${profile.publicId}:${profile.deviceId}:signed-signature',
      ),
      'signedPrekeyKeyId': 1,
      'oneTimePrekeys': List.generate(
        20,
        (index) => _placeholderOpaque(
          '${profile.publicId}:${profile.deviceId}:otk:${index + 1}',
        ),
      ),
    };

    return _request(
      'POST',
      _uri('/v1/devices/key-package'),
      bearerToken: profile.sessionToken,
      body: body,
    );
  }

  Future<Map<String, dynamic>> claimPrekey({
    required String publicId,
    required String deviceId,
  }) async {
    return _request(
      'POST',
      _uri('/v1/prekeys/claim'),
      body: {
        'publicId': publicId.trim().toUpperCase(),
        'deviceId': deviceId.trim().toUpperCase(),
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchPendingMailbox({
    required UserProfile profile,
    int limit = 100,
    int? afterServerSeq,
  }) async {
    final raw = await _request(
      'GET',
      _uri(
        '/v1/messages/pending',
        queryParameters: {
          'deviceId': profile.deviceId.trim().toUpperCase(),
          'limit': limit,
          if (afterServerSeq != null) 'afterServerSeq': afterServerSeq,
        },
      ),
      bearerToken: profile.sessionToken,
    );

    final items = raw['items'];
    if (items is! List) {
      return const <Map<String, dynamic>>[];
    }

    return items
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
        .toList();
  }

  Future<Map<String, dynamic>> ackEnvelope({
    required UserProfile profile,
    required String envelopeId,
    bool markRead = true,
  }) async {
    return _request(
      'POST',
      _uri('/v1/messages/${envelopeId.trim()}/ack'),
      bearerToken: profile.sessionToken,
      body: {
        'deviceId': profile.deviceId.trim().toUpperCase(),
        'markRead': markRead,
      },
    );
  }

  Future<List<Map<String, dynamic>>> sendMailboxTextPlaceholder({
    required UserProfile profile,
    required FriendUser friend,
    required String text,
    required String clientMessageId,
  }) async {
    final devices = await fetchPeerDevices(friend.publicId);
    if (devices.isEmpty) {
      throw Exception('У пользователя нет активных устройств для mailbox-доставки');
    }

    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw Exception('Пустое сообщение отправлять нельзя');
    }

    final recipients = <Map<String, dynamic>>[];

    for (final device in devices) {
      await claimPrekey(
        publicId: friend.publicId,
        deviceId: device.deviceId,
      );

      recipients.add({
        'recipientPublicId': friend.publicId.trim().toUpperCase(),
        'recipientDeviceId': device.deviceId.trim().toUpperCase(),
        'messageKind': 'text',
        'protocol': 'mailbox-placeholder-v0',
        'headerB64': base64Encode(
          utf8.encode(
            jsonEncode({
              'clientMessageId': clientMessageId,
              'senderPublicId': profile.publicId,
              'senderDeviceId': profile.deviceId,
              'note': 'transitional-placeholder-payload-not-real-e2ee',
            }),
          ),
        ),
        'ciphertextB64': base64Encode(utf8.encode(normalizedText)),
        'metadata': {
          'clientMessageId': clientMessageId,
          'placeholder': true,
          'encoding': 'base64-utf8',
        },
      });
    }

    final decoded = await _request(
      'POST',
      _uri('/v1/messages/send'),
      bearerToken: profile.sessionToken,
      body: {
        'envelopeGroupId': 'grp_${DateTime.now().millisecondsSinceEpoch}',
        'conversationId': _buildDirectChatId(profile.publicId, friend.publicId),
        'senderDeviceId': profile.deviceId.trim().toUpperCase(),
        'recipients': recipients,
      },
    );

    final stored = decoded['stored'];
    if (stored is! List) {
      return const <Map<String, dynamic>>[];
    }

    return stored
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
        .toList();
  }

  String? tryDecodeMailboxPlaceholderText(Map<String, dynamic> envelope) {
    final protocol = envelope['protocol']?.toString() ?? '';
    if (protocol != 'mailbox-placeholder-v0') {
      return null;
    }

    final metadata = envelope['metadata'];
    final encoding = metadata is Map ? metadata['encoding']?.toString() : null;
    if (encoding != 'base64-utf8') {
      return null;
    }

    final ciphertextB64 = envelope['ciphertextB64']?.toString() ?? '';
    if (ciphertextB64.trim().isEmpty) {
      return null;
    }

    try {
      return utf8.decode(base64Decode(ciphertextB64));
    } catch (_) {
      return null;
    }
  }

  String _placeholderOpaque(String seed) {
    return base64Encode(utf8.encode(seed));
  }

  static String _buildDirectChatId(String id1, String id2) {
    final list = [id1.trim().toUpperCase(), id2.trim().toUpperCase()];
    list.sort();
    return 'dm_${list.join('_')}';
  }
}

DateTime _parseDateTime(dynamic value) {
  if (value == null) {
    return DateTime.fromMillisecondsSinceEpoch(0);
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

  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }

  return DateTime.fromMillisecondsSinceEpoch(0);
}

DateTime? _parseNullableDateTime(dynamic value) {
  if (value == null) {
    return null;
  }
  return _parseDateTime(value);
}
