import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../models/app_models.dart';
import 'mailbox_models.dart';
import 'mailbox_service.dart';

class E2eeFileService {
  E2eeFileService({required MailboxService mailboxService})
      : _mailboxService = mailboxService;

  final MailboxService _mailboxService;

  final AesGcm _aead = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final X25519 _x25519 = X25519();
  final Sha256 _sha256 = Sha256();

  Future<PreparedEncryptedFile> encryptForRecipients({
    required UserProfile sender,
    required String fileName,
    required String mediaType,
    required Uint8List plaintext,
    required List<CryptoFileRecipientBundle> recipients,
    int chunkSizeBytes = 64 * 1024,
  }) async {
    if (plaintext.isEmpty) {
      throw Exception('Файл пустой');
    }

    final fileId = 'FILE_${_randomToken(20)}';
    final objectKey = 'objects/${sender.publicId.toUpperCase()}/$fileId.bin';

    final fileKey = _randomBytes(32);

    final encryptedChunks = <EncryptedFileChunk>[];
    final totalChunks = (plaintext.length / chunkSizeBytes).ceil();

    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSizeBytes;
      final end = min(start + chunkSizeBytes, plaintext.length);
      final chunk = plaintext.sublist(start, end);
      final nonce = _randomBytes(12);
      final aad = utf8.encode('file:$fileId:chunk:$i/$totalChunks');

      final secretBox = await _aead.encrypt(
        chunk,
        secretKey: SecretKey(fileKey),
        nonce: nonce,
        aad: aad,
      );

      final encoded = utf8.encode(jsonEncode({
        'i': i,
        'n': _b64(nonce),
        'c': _b64(secretBox.cipherText),
        'm': _b64(secretBox.mac.bytes),
      }));

      encryptedChunks.add(
        EncryptedFileChunk(index: i, bytes: Uint8List.fromList(encoded)),
      );
    }

    final ciphertext = Uint8List.fromList(
      encryptedChunks.expand((c) => c.bytes).toList(growable: false),
    );

    final digest = await _sha256.hash(ciphertext);
    final hashHex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final keyEnvelopes = <FileRecipientKeyEnvelopePayload>[];
    for (final recipient in recipients) {
      final wrapped = await _wrapFileKeyForRecipient(
        fileId: fileId,
        fileKey: fileKey,
        recipient: recipient,
      );

      keyEnvelopes.add(
        FileRecipientKeyEnvelopePayload(
          recipientPublicId: recipient.publicId,
          recipientDeviceId: recipient.deviceId,
          wrappedFileKeyB64: wrapped.wrappedFileKeyB64,
          metadata: wrapped.metadata,
        ),
      );
    }

    final object = CreateFileObjectPayload(
      fileId: fileId,
      uploaderDeviceId: sender.deviceId,
      objectKey: objectKey,
      mediaType: mediaType,
      fileName: fileName,
      ciphertextSize: ciphertext.length,
      chunkSizeBytes: chunkSizeBytes,
      totalChunks: totalChunks,
      ciphertextSha256Hex: hashHex,
      clientMetadata: {
        'crypto': 'file-aesgcm-v1',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      recipientKeyEnvelopes: keyEnvelopes,
    );

    return PreparedEncryptedFile(
      fileId: fileId,
      objectKey: objectKey,
      mediaType: mediaType,
      fileName: fileName,
      ciphertext: ciphertext,
      chunks: encryptedChunks,
      payload: object,
      fileKeyB64: _b64(fileKey),
    );
  }

  Future<FileObjectMailboxView> registerUpload({
    required UserProfile sender,
    required PreparedEncryptedFile prepared,
  }) {
    return _mailboxService.createFileObject(
      profile: sender,
      payload: prepared.payload,
    );
  }

  Future<FileObjectMailboxView> markUploaded({
    required UserProfile sender,
    required String fileId,
  }) {
    return _mailboxService.completeFileObject(
      profile: sender,
      fileId: fileId,
      uploadStatus: 'completed',
    );
  }

  Future<Uint8List> decryptFileChunked({
    required String fileId,
    required Uint8List ciphertext,
    required String wrappedFileKeyB64,
    required CryptoFileRecipientPrivateKey recipientPrivate,
  }) async {
    final fileKey = await _unwrapFileKey(
      wrappedFileKeyB64: wrappedFileKeyB64,
      recipientPrivate: recipientPrivate,
    );

    final decoded = utf8.decode(ciphertext);
    if (decoded.isEmpty) {
      return Uint8List(0);
    }

    final plain = <int>[];
    final chunks = _splitJsonObjects(decoded);
    for (final rawChunk in chunks) {
      final map = rawChunk;
      final nonce = _b64d(map['n']?.toString() ?? '');
      final c = _b64d(map['c']?.toString() ?? '');
      final m = _b64d(map['m']?.toString() ?? '');
      final index = (map['i'] as num?)?.toInt() ?? 0;
      final aad = utf8.encode('file:$fileId:chunk:$index/${chunks.length}');

      final chunk = await _aead.decrypt(
        SecretBox(c, nonce: nonce, mac: Mac(m)),
        secretKey: SecretKey(fileKey),
        aad: aad,
      );

      plain.addAll(chunk);
    }

    return Uint8List.fromList(plain);
  }

  Future<_WrappedFileKey> _wrapFileKeyForRecipient({
    required String fileId,
    required Uint8List fileKey,
    required CryptoFileRecipientBundle recipient,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephPub = await ephemeral.extractPublicKey();

    final remote = SimplePublicKey(
      _b64d(recipient.signedPrekeyB64),
      type: KeyPairType.x25519,
    );

    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: remote,
    );

    final wrapKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('mayak-file-wrap-salt-$fileId'),
      info: utf8.encode('mayak-file-wrap-v1'),
    );

    final nonce = _randomBytes(12);
    final secretBox = await _aead.encrypt(
      fileKey,
      secretKey: wrapKey,
      nonce: nonce,
      aad: utf8.encode('file-key-wrap:$fileId'),
    );

    final wrapped = {
      'v': 1,
      'alg': 'x25519+aesgcm',
      'epk': _b64(ephPub.bytes),
      'n': _b64(nonce),
      'c': _b64(secretBox.cipherText),
      'm': _b64(secretBox.mac.bytes),
    };

    return _WrappedFileKey(
      wrappedFileKeyB64: _b64(utf8.encode(jsonEncode(wrapped))),
      metadata: {
        'fileKeyAlg': 'aesgcm-256',
        'wrapAlg': 'x25519-aesgcm',
      },
    );
  }

  Future<Uint8List> _unwrapFileKey({
    required String wrappedFileKeyB64,
    required CryptoFileRecipientPrivateKey recipientPrivate,
  }) async {
    final wrapped = jsonDecode(utf8.decode(_b64d(wrappedFileKeyB64))) as Map;

    final epk = SimplePublicKey(
      _b64d(wrapped['epk']?.toString() ?? ''),
      type: KeyPairType.x25519,
    );

    final local = SimpleKeyPairData(
      _b64d(recipientPrivate.signedPrekeyPrivateB64),
      publicKey: SimplePublicKey(
        _b64d(recipientPrivate.signedPrekeyPublicB64),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    final shared = await _x25519.sharedSecretKey(
      keyPair: local,
      remotePublicKey: epk,
    );

    final wrapKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('mayak-file-wrap-salt-${recipientPrivate.fileId}'),
      info: utf8.encode('mayak-file-wrap-v1'),
    );

    final nonce = _b64d(wrapped['n']?.toString() ?? '');
    final c = _b64d(wrapped['c']?.toString() ?? '');
    final m = _b64d(wrapped['m']?.toString() ?? '');

    final plain = await _aead.decrypt(
      SecretBox(c, nonce: nonce, mac: Mac(m)),
      secretKey: wrapKey,
      aad: utf8.encode('file-key-wrap:${recipientPrivate.fileId}'),
    );

    return Uint8List.fromList(plain);
  }

  List<Map<String, dynamic>> _splitJsonObjects(String input) {
    final result = <Map<String, dynamic>>[];
    var depth = 0;
    var start = 0;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          final obj = jsonDecode(input.substring(start, i + 1));
          if (obj is Map) {
            result.add(
              obj.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
        }
      }
    }

    return result;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  String _randomToken(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(chars[random.nextInt(chars.length)]);
    }
    return buffer.toString();
  }

  String _b64(List<int> bytes) => base64Encode(bytes);

  Uint8List _b64d(String value) => Uint8List.fromList(base64Decode(value));
}

class CryptoFileRecipientBundle {
  const CryptoFileRecipientBundle({
    required this.publicId,
    required this.deviceId,
    required this.signedPrekeyB64,
  });

  final String publicId;
  final String deviceId;
  final String signedPrekeyB64;
}

class CryptoFileRecipientPrivateKey {
  const CryptoFileRecipientPrivateKey({
    required this.fileId,
    required this.signedPrekeyPublicB64,
    required this.signedPrekeyPrivateB64,
  });

  final String fileId;
  final String signedPrekeyPublicB64;
  final String signedPrekeyPrivateB64;
}

class EncryptedFileChunk {
  const EncryptedFileChunk({required this.index, required this.bytes});

  final int index;
  final Uint8List bytes;
}

class PreparedEncryptedFile {
  const PreparedEncryptedFile({
    required this.fileId,
    required this.objectKey,
    required this.mediaType,
    required this.fileName,
    required this.ciphertext,
    required this.chunks,
    required this.payload,
    required this.fileKeyB64,
  });

  final String fileId;
  final String objectKey;
  final String mediaType;
  final String fileName;
  final Uint8List ciphertext;
  final List<EncryptedFileChunk> chunks;
  final CreateFileObjectPayload payload;
  final String fileKeyB64;
}

class _WrappedFileKey {
  const _WrappedFileKey({
    required this.wrappedFileKeyB64,
    required this.metadata,
  });

  final String wrappedFileKeyB64;
  final Map<String, dynamic> metadata;
}
