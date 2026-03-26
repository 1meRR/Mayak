import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../models/app_models.dart';
import 'secure_device_storage.dart';

class E2eeKeyBackupService {
  E2eeKeyBackupService({SecureDeviceStorage? secureStorage})
      : _secureStorage = secureStorage ?? SecureDeviceStorage();

  final SecureDeviceStorage _secureStorage;
  final AesGcm _aead = AesGcm.with256bits();
  final Pbkdf2 _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );

  static const _identityKeyName = 'sw_crypto_identity_v3';
  static const _sessionsKeyName = 'sw_crypto_sessions_v3';

  Future<String> createEncryptedBackup({
    required UserProfile profile,
    required String recoveryPassphrase,
  }) async {
    final ref = _normalize(profile);
    final identity = await _secureStorage.readJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _identityKeyName,
    );
    final sessions = await _secureStorage.readJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _sessionsKeyName,
    );

    if (identity == null) {
      throw Exception('Локальные E2EE ключи не найдены для backup');
    }

    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'publicId': ref.publicId,
        'deviceId': ref.deviceId,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'identity': identity,
        'sessions': sessions ?? const <String, dynamic>{},
      }),
    );

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);

    final secret = await _pbkdf2.deriveKeyFromPassword(
      password: recoveryPassphrase,
      nonce: salt,
    );

    final box = await _aead.encrypt(
      payload,
      secretKey: secret,
      nonce: nonce,
      aad: utf8.encode('mayak-key-backup-v1'),
    );

    return base64Encode(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'kdf': 'pbkdf2-hmac-sha256',
          'iters': 210000,
          'saltB64': base64Encode(salt),
          'nonceB64': base64Encode(nonce),
          'cipherB64': base64Encode(box.cipherText),
          'macB64': base64Encode(box.mac.bytes),
        }),
      ),
    );
  }

  Future<void> restoreEncryptedBackup({
    required UserProfile profile,
    required String recoveryPassphrase,
    required String backupBlobB64,
  }) async {
    final envelope = jsonDecode(utf8.decode(base64Decode(backupBlobB64)));
    if (envelope is! Map) {
      throw Exception('Некорректный backup blob');
    }

    final map = envelope.map((key, value) => MapEntry(key.toString(), value));
    final salt = base64Decode(map['saltB64']?.toString() ?? '');
    final nonce = base64Decode(map['nonceB64']?.toString() ?? '');
    final cipher = base64Decode(map['cipherB64']?.toString() ?? '');
    final mac = base64Decode(map['macB64']?.toString() ?? '');

    final secret = await _pbkdf2.deriveKeyFromPassword(
      password: recoveryPassphrase,
      nonce: salt,
    );

    final plain = await _aead.decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: secret,
      aad: utf8.encode('mayak-key-backup-v1'),
    );

    final payload = jsonDecode(utf8.decode(plain));
    if (payload is! Map) {
      throw Exception('Некорректный decrypt payload');
    }

    final obj = payload.map((key, value) => MapEntry(key.toString(), value));
    final identityRaw = obj['identity'];
    final sessionsRaw = obj['sessions'];

    if (identityRaw is! Map) {
      throw Exception('Backup не содержит identity state');
    }

    final ref = _normalize(profile);

    await _secureStorage.writeJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _identityKeyName,
      value: identityRaw.map((k, v) => MapEntry(k.toString(), v)),
    );

    if (sessionsRaw is Map) {
      await _secureStorage.writeJson(
        publicId: ref.publicId,
        deviceId: ref.deviceId,
        name: _sessionsKeyName,
        value: sessionsRaw.map((k, v) => MapEntry(k.toString(), v)),
      );
    }
  }

  _ProfileRef _normalize(UserProfile profile) {
    return _ProfileRef(
      publicId: profile.publicId.trim().toUpperCase(),
      deviceId: profile.deviceId.trim().toUpperCase(),
    );
  }

  Uint8List _randomBytes(int length) {
    final r = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => r.nextInt(256)),
    );
  }
}

class _ProfileRef {
  const _ProfileRef({required this.publicId, required this.deviceId});

  final String publicId;
  final String deviceId;
}
