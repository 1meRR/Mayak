import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/app_models.dart';
import 'mailbox_models.dart';

class MailboxService {
  MailboxService(this.serverUrl);

  final String serverUrl;

  Uri _baseUri() {
    final uri = Uri.parse(serverUrl);
    final scheme = uri.scheme == 'wss'
        ? 'https'
        : uri.scheme == 'ws'
            ? 'http'
            : uri.scheme;

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  Uri _uri(String path, {Map<String, dynamic>? queryParameters}) {
    final base = _baseUri();
    return base.replace(
      path: path,
      queryParameters:
          queryParameters?.map((key, value) => MapEntry(key, value.toString())),
    );
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

  Future<Map<String, dynamic>> _decode(http.Response response) async {
    final body = response.body.trim();
    if (body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(body);
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

    final decoded = await _decode(response);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    final message = decoded['error']?.toString().trim();
    if (message != null && message.isNotEmpty) {
      throw Exception(message);
    }

    throw Exception('HTTP ${response.statusCode}');
  }

  Future<List<MailboxDeviceView>> listDevices(String publicId) async {
    final decoded = await _request(
      'GET',
      _uri('/v1/users/${publicId.trim().toUpperCase()}/devices'),
    );

    if (decoded.isEmpty) {
      return const <MailboxDeviceView>[];
    }

    if (decoded case final Map<String, dynamic> _) {
      if (decoded['items'] is List) {
        final raw = decoded['items'] as List;
        return raw
            .whereType<Map>()
            .map(
              (item) => MailboxDeviceView.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList();
      }
    }

    // сервер этого endpoint сейчас отдаёт просто массив;
    // сюда мы не попадём при нормальном GET через http.get + _decode(Map)
    return const <MailboxDeviceView>[];
  }

  Future<List<MailboxDeviceView>> listDevicesRaw(String publicId) async {
    final response = await http.get(
      _uri('/v1/users/${publicId.trim().toUpperCase()}/devices'),
      headers: _headers(),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final decoded = await _decode(response);
      throw Exception(decoded['error']?.toString() ?? 'HTTP ${response.statusCode}');
    }

    final body = response.body.trim();
    if (body.isEmpty) {
      return const <MailboxDeviceView>[];
    }

    final decoded = jsonDecode(body);
    if (decoded is! List) {
      return const <MailboxDeviceView>[];
    }

    return decoded
        .whereType<Map>()
        .map(
          (item) => MailboxDeviceView.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  Future<ClaimedPrekeyBundle> uploadDeviceKeyPackage({
    required UserProfile profile,
    required DeviceKeyPackagePayload payload,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/devices/key-package'),
      bearerToken: profile.sessionToken,
      body: payload.toJson(),
    );

    return ClaimedPrekeyBundle.fromJson(decoded);
  }

  Future<ClaimedPrekeyBundle> claimPrekey({
    required String targetPublicId,
    required String targetDeviceId,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/prekeys/claim'),
      body: {
        'publicId': targetPublicId.trim().toUpperCase(),
        'deviceId': targetDeviceId.trim().toUpperCase(),
      },
    );

    return ClaimedPrekeyBundle.fromJson(decoded);
  }

  Future<List<StoredEnvelopeView>> sendEncryptedEnvelopes({
    required UserProfile profile,
    required String conversationId,
    required String senderDeviceId,
    required List<RecipientEnvelopePayload> recipients,
    String envelopeGroupId = '',
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/messages/send'),
      bearerToken: profile.sessionToken,
      body: {
        'envelopeGroupId': envelopeGroupId.trim().isEmpty
            ? 'grp_${DateTime.now().millisecondsSinceEpoch}'
            : envelopeGroupId,
        'conversationId': conversationId,
        'senderDeviceId': senderDeviceId.trim().toUpperCase(),
        'recipients': recipients.map((e) => e.toJson()).toList(),
      },
    );

    final rawStored = decoded['stored'];
    if (rawStored is! List) {
      return const <StoredEnvelopeView>[];
    }

    return rawStored
        .whereType<Map>()
        .map(
          (item) => StoredEnvelopeView.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  Future<PendingMailboxResponse> fetchPending({
    required UserProfile profile,
    int? afterServerSeq,
    int limit = 100,
  }) async {
    final decoded = await _request(
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

    return PendingMailboxResponse.fromJson(decoded);
  }

  Future<AckEnvelopeView> ackEnvelope({
    required UserProfile profile,
    required String envelopeId,
    bool markRead = true,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/messages/${envelopeId.trim()}/ack'),
      bearerToken: profile.sessionToken,
      body: {
        'deviceId': profile.deviceId.trim().toUpperCase(),
        'markRead': markRead,
      },
    );

    return AckEnvelopeView.fromJson(decoded);
  }

  Future<FileObjectMailboxView> createFileObject({
    required UserProfile profile,
    required CreateFileObjectPayload payload,
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/files'),
      bearerToken: profile.sessionToken,
      body: payload.toJson(),
    );

    return FileObjectMailboxView.fromJson(decoded);
  }

  Future<FileObjectMailboxView> completeFileObject({
    required UserProfile profile,
    required String fileId,
    String uploadStatus = 'completed',
  }) async {
    final decoded = await _request(
      'POST',
      _uri('/v1/files/${fileId.trim()}/complete'),
      bearerToken: profile.sessionToken,
      deviceIdHeader: profile.deviceId,
      body: {
        'uploadStatus': uploadStatus,
      },
    );

    return FileObjectMailboxView.fromJson(decoded);
  }

  Future<FileLookupMailboxResponse> getFileForDevice({
    required UserProfile profile,
    required String fileId,
  }) async {
    final decoded = await _request(
      'GET',
      _uri('/v1/files/${fileId.trim()}'),
      bearerToken: profile.sessionToken,
      deviceIdHeader: profile.deviceId,
    );

    return FileLookupMailboxResponse.fromJson(decoded);
  }
  Future<void> uploadFileChunk({
    required UserProfile profile,
    required String fileId,
    required int chunkIndex,
    required List<int> bytes,
  }) async {
    final response = await http.post(
      _uri('/v1/files/${fileId.trim()}/chunks/$chunkIndex'),
      headers: _headers(
        json: false,
        bearerToken: profile.sessionToken,
        deviceId: profile.deviceId,
      ),
      body: bytes,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final decoded = await _decode(response);
      throw Exception(decoded['error']?.toString() ?? 'HTTP ${response.statusCode}');
    }
  }

  Future<Uint8List> downloadFileCiphertext({
    required UserProfile profile,
    required String fileId,
  }) async {
    final response = await http.get(
      _uri('/v1/files/${fileId.trim()}/content'),
      headers: _headers(
        json: false,
        bearerToken: profile.sessionToken,
        deviceId: profile.deviceId,
      ),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final decoded = await _decode(response);
      throw Exception(decoded['error']?.toString() ?? 'HTTP ${response.statusCode}');
    }

    return response.bodyBytes;
  }

}
