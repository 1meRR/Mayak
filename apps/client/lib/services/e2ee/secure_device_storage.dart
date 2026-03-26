import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureDeviceStorage {
  SecureDeviceStorage({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _namespace = 'mayak_e2ee';

  String _key(String publicId, String deviceId, String name) {
    final user = publicId.trim().toUpperCase();
    final device = deviceId.trim().toUpperCase();
    return '$_namespace:$user:$device:$name';
  }

  Future<void> writeJson({
    required String publicId,
    required String deviceId,
    required String name,
    required Map<String, dynamic> value,
  }) async {
    await _storage.write(
      key: _key(publicId, deviceId, name),
      value: jsonEncode(value),
    );
  }

  Future<Map<String, dynamic>?> readJson({
    required String publicId,
    required String deviceId,
    required String name,
  }) async {
    final raw = await _storage.read(
      key: _key(publicId, deviceId, name),
    );
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  Future<void> writeString({
    required String publicId,
    required String deviceId,
    required String name,
    required String value,
  }) async {
    await _storage.write(
      key: _key(publicId, deviceId, name),
      value: value,
    );
  }

  Future<String?> readString({
    required String publicId,
    required String deviceId,
    required String name,
  }) async {
    return _storage.read(
      key: _key(publicId, deviceId, name),
    );
  }

  Future<void> delete({
    required String publicId,
    required String deviceId,
    required String name,
  }) async {
    await _storage.delete(
      key: _key(publicId, deviceId, name),
    );
  }

  Future<Map<String, dynamic>> readAllForDevice({
    required String publicId,
    required String deviceId,
    required String prefix,
  }) async {
    final all = await _storage.readAll();
    final scopedPrefix =
        '$_namespace:${publicId.trim().toUpperCase()}:${deviceId.trim().toUpperCase()}:$prefix';

    final result = <String, dynamic>{};
    for (final entry in all.entries) {
      if (!entry.key.startsWith(scopedPrefix)) {
        continue;
      }
      final value = entry.value;
      if (value.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(value);
        result[entry.key] = decoded;
      } catch (_) {
        result[entry.key] = value;
      }
    }

    return result;
  }

  Future<void> deleteAllForDevice({
    required String publicId,
    required String deviceId,
  }) async {
    final all = await _storage.readAll();
    final prefix =
        '$_namespace:${publicId.trim().toUpperCase()}:${deviceId.trim().toUpperCase()}:';

    final futures = <Future<void>>[];
    for (final entry in all.entries) {
      if (entry.key.startsWith(prefix)) {
        futures.add(_storage.delete(key: entry.key));
      }
    }
    await Future.wait(futures);
  }
}
