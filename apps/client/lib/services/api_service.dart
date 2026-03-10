import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_models.dart';

class ApiService {
  ApiService(this.serverUrl);

  final String serverUrl;

  Uri _baseUri() {
    final uri = Uri.parse(serverUrl);
    final scheme = uri.scheme == 'wss' ? 'https' : 'http';

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  Uri _uri(String path) {
    final base = _baseUri();
    return base.replace(path: path);
  }

  Future<Map<String, dynamic>> _decode(http.Response response) async {
    final body = response.body.trim();
    final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }

    throw Exception('Некорректный ответ сервера');
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    late http.Response response;

    const headers = {
      'Content-Type': 'application/json',
    };

    if (method == 'GET') {
      response = await http.get(uri, headers: headers);
    } else if (method == 'POST') {
      response = await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? <String, dynamic>{}),
      );
    } else {
      throw Exception('Неподдерживаемый метод $method');
    }

    final decoded = await _decode(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded['error']?.toString() ?? 'Ошибка сервера';
      throw Exception(error);
    }

    return decoded;
  }

  Future<void> health() async {
    await _request('GET', _uri('/health'));
  }

  Future<UserProfile> registerUser(UserProfile profile) async {
    final decoded = await _request(
      'POST',
      _uri('/api/register'),
      body: {
        'publicId': profile.publicId,
        'deviceId': profile.deviceId,
        'firstName': profile.firstName,
        'lastName': profile.lastName,
        'phone': profile.phone,
        'about': profile.about,
        'platform': 'android',
      },
    );

    final userMap = decoded['user'];
    final deviceMap = decoded['device'];

    if (userMap is! Map || deviceMap is! Map) {
      throw Exception('Сервер вернул неполный профиль');
    }

    final user = userMap.map((key, value) => MapEntry(key.toString(), value));
    final device = deviceMap.map((key, value) => MapEntry(key.toString(), value));

    return profile.copyWith(
      publicId: user['publicId']?.toString() ?? profile.publicId,
      deviceId: device['deviceId']?.toString() ?? profile.deviceId,
      firstName: user['firstName']?.toString() ?? profile.firstName,
      lastName: user['lastName']?.toString() ?? profile.lastName,
      phone: user['phone']?.toString() ?? profile.phone,
      about: user['about']?.toString() ?? profile.about,
      registered: true,
    );
  }

  Future<void> heartbeat({
    required String publicId,
    required String deviceId,
  }) async {
    await _request(
      'POST',
      _uri('/api/presence/heartbeat'),
      body: {
        'publicId': publicId,
        'deviceId': deviceId,
      },
    );
  }

  Future<FriendUser> lookupUserByPublicId(String publicId) async {
    final normalized = publicId.trim().toUpperCase();

    final decoded = await _request(
      'GET',
      _uri('/api/users/by-public-id/$normalized'),
    );

    final userMap = decoded['user'];
    if (userMap is! Map) {
      throw Exception('Пользователь не найден');
    }

    final user = userMap.map((key, value) => MapEntry(key.toString(), value));

    return FriendUser(
      publicId: user['publicId']?.toString() ?? normalized,
      displayName: user['displayName']?.toString() ?? 'Пользователь',
      about: user['about']?.toString() ?? '',
      createdAt: DateTime.now(),
      isOnline: false,
      lastSeenAt: null,
    );
  }

  Future<FriendsBundle> fetchFriends(String publicId) async {
    final normalized = publicId.trim().toUpperCase();

    final decoded = await _request(
      'GET',
      _uri('/api/friends/$normalized'),
    );

    return FriendsBundle.fromJson(decoded);
  }

  Future<FriendRequestView> createFriendRequest({
    required String fromPublicId,
    required String toPublicId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/api/friends/request'),
      body: {
        'fromPublicId': fromPublicId.trim().toUpperCase(),
        'toPublicId': toPublicId.trim().toUpperCase(),
      },
    );

    return FriendRequestView.fromJson(decoded);
  }

  Future<FriendRequestView> respondFriendRequest({
    required String requestId,
    required String actorPublicId,
    required String action,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/api/friends/respond'),
      body: {
        'requestId': requestId,
        'actorPublicId': actorPublicId.trim().toUpperCase(),
        'action': action,
      },
    );

    return FriendRequestView.fromJson(decoded);
  }

  Future<List<DirectMessage>> fetchMessages({
    required String chatId,
    required String myPublicId,
  }) async {
    final decoded = await _request(
      'GET',
      _uri('/api/chats/$chatId/messages'),
    );

    final rawItems = decoded['items'];
    if (rawItems is! List) {
      return [];
    }

    final items = rawItems
        .whereType<Map>()
        .map(
          (item) => DirectMessage.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            myPublicId: myPublicId,
          ),
        )
        .toList();

    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  Future<DirectMessage> sendMessage({
    required String fromPublicId,
    required String toPublicId,
    required String text,
    required String authorDisplayName,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/api/messages/send'),
      body: {
        'fromPublicId': fromPublicId.trim().toUpperCase(),
        'toPublicId': toPublicId.trim().toUpperCase(),
        'text': text.trim(),
      },
    );

    final messageMap = decoded['message'];
    final chatId = decoded['chatId']?.toString() ?? '';

    if (messageMap is! Map) {
      throw Exception('Сервер не вернул сообщение');
    }

    final data = messageMap.map((key, value) => MapEntry(key.toString(), value));
    final message = DirectMessage.fromJson(
      {
        ...data,
        'authorDisplayName': authorDisplayName,
        'chatId': chatId,
      },
      myPublicId: fromPublicId,
    );

    return message;
  }

  Future<CallInviteView> createCallInvite({
    required String callerPublicId,
    required String calleePublicId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/api/calls/invite'),
      body: {
        'callerPublicId': callerPublicId.trim().toUpperCase(),
        'calleePublicId': calleePublicId.trim().toUpperCase(),
      },
    );

    return CallInviteView.fromJson(decoded);
  }

  Future<CallInviteView> getCallInvite(String inviteId) async {
    final decoded = await _request(
      'GET',
      _uri('/api/calls/$inviteId'),
    );

    return CallInviteView.fromJson(decoded);
  }

  Future<List<CallInviteView>> fetchIncomingCalls(String publicId) async {
    final decoded = await _request(
      'GET',
      _uri('/api/calls/incoming/${publicId.trim().toUpperCase()}'),
    );

    final rawItems = decoded['items'];
    if (rawItems is! List) {
      return [];
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
    required String action,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/api/calls/respond'),
      body: {
        'inviteId': inviteId,
        'actorPublicId': actorPublicId.trim().toUpperCase(),
        'action': action,
      },
    );

    return CallInviteView.fromJson(decoded);
  }
}