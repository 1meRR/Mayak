import '../../models/app_models.dart';
import 'crypto_models.dart';
import 'mailbox_models.dart';

class CryptoBridgeUnavailableException implements Exception {
  CryptoBridgeUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class CryptoBridge {
  Future<CryptoBridgeStatus> getStatus();

  Future<CryptoDeviceKeyPackage> ensureLocalDeviceIdentity(
    UserProfile profile,
  );

  Future<List<CryptoOutgoingEnvelopeDraft>> encryptTextMessage({
    required UserProfile senderProfile,
    required String conversationId,
    required String plaintext,
    required String clientMessageId,
    required List<CryptoRemotePrekeyBundle> recipientBundles,
  });

  Future<CryptoDecryptedEnvelope?> decryptEnvelope({
    required UserProfile localProfile,
    required StoredEnvelopeView envelope,
  });
}