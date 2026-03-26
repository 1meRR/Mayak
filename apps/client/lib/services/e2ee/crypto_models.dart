@'
import '../../models/app_models.dart';
import 'mailbox_models.dart';

class CryptoBridgeStatus {
  const CryptoBridgeStatus({
    required this.available,
    required this.backend,
    required this.reason,
  });

  final bool available;
  final String backend;
  final String? reason;
}

class CryptoDeviceKeyPackage {
  const CryptoDeviceKeyPackage({
    required this.deviceId,
    required this.identityKeyAlg,
    required this.identityKeyB64,
    required this.signedPrekeyB64,
    required this.signedPrekeySignatureB64,
    required this.signedPrekeyKeyId,
    required this.oneTimePrekeys,
  });

  final String deviceId;
  final String identityKeyAlg;
  final String identityKeyB64;
  final String signedPrekeyB64;
  final String signedPrekeySignatureB64;
  final int signedPrekeyKeyId;
  final List<String> oneTimePrekeys;

  DeviceKeyPackagePayload toMailboxPayload() {
    return DeviceKeyPackagePayload(
      deviceId: deviceId,
      identityKeyAlg: identityKeyAlg,
      identityKeyB64: identityKeyB64,
      signedPrekeyB64: signedPrekeyB64,
      signedPrekeySignatureB64: signedPrekeySignatureB64,
      signedPrekeyKeyId: signedPrekeyKeyId,
      oneTimePrekeys: oneTimePrekeys,
    );
  }

  factory CryptoDeviceKeyPackage.fromJson(Map<String, dynamic> json) {
    final rawPrekeys = json['oneTimePrekeys'];
    return CryptoDeviceKeyPackage(
      deviceId: json['deviceId']?.toString() ?? '',
      identityKeyAlg: json['identityKeyAlg']?.toString() ?? '',
      identityKeyB64: json['identityKeyB64']?.toString() ?? '',
      signedPrekeyB64: json['signedPrekeyB64']?.toString() ?? '',
      signedPrekeySignatureB64:
          json['signedPrekeySignatureB64']?.toString() ?? '',
      signedPrekeyKeyId: (json['signedPrekeyKeyId'] as num?)?.toInt() ?? 0,
      oneTimePrekeys: rawPrekeys is List
          ? rawPrekeys.map((e) => e.toString()).toList()
          : const <String>[],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'identityKeyAlg': identityKeyAlg,
      'identityKeyB64': identityKeyB64,
      'signedPrekeyB64': signedPrekeyB64,
      'signedPrekeySignatureB64': signedPrekeySignatureB64,
      'signedPrekeyKeyId': signedPrekeyKeyId,
      'oneTimePrekeys': oneTimePrekeys,
    };
  }
}

class CryptoRemotePrekeyBundle {
  const CryptoRemotePrekeyBundle({
    required this.publicId,
    required this.deviceId,
    required this.identityKeyAlg,
    required this.identityKeyB64,
    required this.signedPrekeyB64,
    required this.signedPrekeySignatureB64,
    required this.signedPrekeyKeyId,
    required this.claimedOneTimePrekeyB64,
    required this.updatedAt,
  });

  final String publicId;
  final String deviceId;
  final String identityKeyAlg;
  final String identityKeyB64;
  final String signedPrekeyB64;
  final String signedPrekeySignatureB64;
  final int signedPrekeyKeyId;
  final String? claimedOneTimePrekeyB64;
  final int updatedAt;

  factory CryptoRemotePrekeyBundle.fromClaimedBundle(
    ClaimedPrekeyBundle bundle,
  ) {
    return CryptoRemotePrekeyBundle(
      publicId: bundle.publicId,
      deviceId: bundle.deviceId,
      identityKeyAlg: bundle.identityKeyAlg,
      identityKeyB64: bundle.identityKeyB64,
      signedPrekeyB64: bundle.signedPrekeyB64,
      signedPrekeySignatureB64: bundle.signedPrekeySignatureB64,
      signedPrekeyKeyId: bundle.signedPrekeyKeyId,
      claimedOneTimePrekeyB64:
          bundle.oneTimePrekeys.isEmpty ? null : bundle.oneTimePrekeys.first,
      updatedAt: bundle.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicId': publicId,
      'deviceId': deviceId,
      'identityKeyAlg': identityKeyAlg,
      'identityKeyB64': identityKeyB64,
      'signedPrekeyB64': signedPrekeyB64,
      'signedPrekeySignatureB64': signedPrekeySignatureB64,
      'signedPrekeyKeyId': signedPrekeyKeyId,
      'claimedOneTimePrekeyB64': claimedOneTimePrekeyB64,
      'updatedAt': updatedAt,
    };
  }
}

class CryptoRecipientDevice {
  const CryptoRecipientDevice({
    required this.publicId,
    required this.deviceId,
    required this.platform,
    required this.isOnline,
    required this.lastSeenAt,
  });

  final String publicId;
  final String deviceId;
  final String platform;
  final bool isOnline;
  final int lastSeenAt;

  factory CryptoRecipientDevice.fromMailboxDevice(MailboxDeviceView device) {
    return CryptoRecipientDevice(
      publicId: device.publicId,
      deviceId: device.deviceId,
      platform: device.platform,
      isOnline: device.isOnline,
      lastSeenAt: device.lastSeenAt,
    );
  }
}

class CryptoOutgoingEnvelopeDraft {
  const CryptoOutgoingEnvelopeDraft({
    required this.recipientPublicId,
    required this.recipientDeviceId,
    required this.messageKind,
    required this.protocol,
    required this.headerB64,
    required this.ciphertextB64,
    required this.metadata,
  });

  final String recipientPublicId;
  final String recipientDeviceId;
  final String messageKind;
  final String protocol;
  final String headerB64;
  final String ciphertextB64;
  final Map<String, dynamic> metadata;

  RecipientEnvelopePayload toRecipientEnvelopePayload() {
    return RecipientEnvelopePayload(
      recipientPublicId: recipientPublicId,
      recipientDeviceId: recipientDeviceId,
      messageKind: messageKind,
      protocol: protocol,
      headerB64: headerB64,
      ciphertextB64: ciphertextB64,
      metadata: metadata,
    );
  }

  factory CryptoOutgoingEnvelopeDraft.fromJson(Map<String, dynamic> json) {
    return CryptoOutgoingEnvelopeDraft(
      recipientPublicId: json['recipientPublicId']?.toString() ?? '',
      recipientDeviceId: json['recipientDeviceId']?.toString() ?? '',
      messageKind: json['messageKind']?.toString() ?? 'text',
      protocol: json['protocol']?.toString() ?? '',
      headerB64: json['headerB64']?.toString() ?? '',
      ciphertextB64: json['ciphertextB64']?.toString() ?? '',
      metadata: json['metadata'] is Map
          ? (json['metadata'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
    );
  }
}

class CryptoDecryptedEnvelope {
  const CryptoDecryptedEnvelope({
    required this.envelopeId,
    required this.conversationId,
    required this.senderPublicId,
    required this.senderDeviceId,
    required this.messageKind,
    required this.protocol,
    required this.plaintext,
    required this.clientMessageId,
    required this.createdAt,
    required this.serverSeq,
  });

  final String envelopeId;
  final String conversationId;
  final String senderPublicId;
  final String senderDeviceId;
  final String messageKind;
  final String protocol;
  final String plaintext;
  final String? clientMessageId;
  final int createdAt;
  final int serverSeq;

  factory CryptoDecryptedEnvelope.fromJson(Map<String, dynamic> json) {
    return CryptoDecryptedEnvelope(
      envelopeId: json['envelopeId']?.toString() ?? '',
      conversationId: json['conversationId']?.toString() ?? '',
      senderPublicId: json['senderPublicId']?.toString() ?? '',
      senderDeviceId: json['senderDeviceId']?.toString() ?? '',
      messageKind: json['messageKind']?.toString() ?? 'text',
      protocol: json['protocol']?.toString() ?? '',
      plaintext: json['plaintext']?.toString() ?? '',
      clientMessageId: json['clientMessageId']?.toString(),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      serverSeq: (json['serverSeq'] as num?)?.toInt() ?? 0,
    );
  }
}

String buildDirectConversationId(String left, String right) {
  final items = [left.trim().toUpperCase(), right.trim().toUpperCase()]..sort();
  return 'dm_${items.join('_')}';
}

String buildClientMessageId({
  required UserProfile profile,
  required int unixMs,
}) {
  return 'msg_${profile.publicId}_${profile.deviceId}_$unixMs';
}
'@ | Set-Content -Path "E:\VSCODE\decentra_call_messenger\apps\client\lib\services\e2ee\crypto_models.dart" -Encoding UTF8