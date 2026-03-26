class MailboxDeviceView {
  final String publicId;
  final String deviceId;
  final String platform;
  final bool isOnline;
  final int lastSeenAt;
  final String? appVersion;
  final Map<String, dynamic> capabilities;

  const MailboxDeviceView({
    required this.publicId,
    required this.deviceId,
    required this.platform,
    required this.isOnline,
    required this.lastSeenAt,
    required this.appVersion,
    required this.capabilities,
  });

  factory MailboxDeviceView.fromJson(Map<String, dynamic> json) {
    return MailboxDeviceView(
      publicId: json['publicId']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      isOnline: json['isOnline'] as bool? ?? false,
      lastSeenAt: (json['lastSeenAt'] as num?)?.toInt() ?? 0,
      appVersion: json['appVersion']?.toString(),
      capabilities: json['capabilities'] is Map
          ? (json['capabilities'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
    );
  }
}

class DeviceKeyPackagePayload {
  final String deviceId;
  final String identityKeyAlg;
  final String identityKeyB64;
  final String signedPrekeyB64;
  final String signedPrekeySignatureB64;
  final int signedPrekeyKeyId;
  final List<String> oneTimePrekeys;

  const DeviceKeyPackagePayload({
    required this.deviceId,
    required this.identityKeyAlg,
    required this.identityKeyB64,
    required this.signedPrekeyB64,
    required this.signedPrekeySignatureB64,
    required this.signedPrekeyKeyId,
    required this.oneTimePrekeys,
  });

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

class ClaimedPrekeyBundle {
  final String publicId;
  final String deviceId;
  final String identityKeyAlg;
  final String identityKeyB64;
  final String signedPrekeyB64;
  final String signedPrekeySignatureB64;
  final int signedPrekeyKeyId;
  final List<String> oneTimePrekeys;
  final int updatedAt;

  const ClaimedPrekeyBundle({
    required this.publicId,
    required this.deviceId,
    required this.identityKeyAlg,
    required this.identityKeyB64,
    required this.signedPrekeyB64,
    required this.signedPrekeySignatureB64,
    required this.signedPrekeyKeyId,
    required this.oneTimePrekeys,
    required this.updatedAt,
  });

  factory ClaimedPrekeyBundle.fromJson(Map<String, dynamic> json) {
    final prekeys = json['oneTimePrekeys'];
    return ClaimedPrekeyBundle(
      publicId: json['publicId']?.toString() ?? '',
      deviceId: json['deviceId']?.toString() ?? '',
      identityKeyAlg: json['identityKeyAlg']?.toString() ?? '',
      identityKeyB64: json['identityKeyB64']?.toString() ?? '',
      signedPrekeyB64: json['signedPrekeyB64']?.toString() ?? '',
      signedPrekeySignatureB64:
          json['signedPrekeySignatureB64']?.toString() ?? '',
      signedPrekeyKeyId: (json['signedPrekeyKeyId'] as num?)?.toInt() ?? 0,
      oneTimePrekeys: prekeys is List
          ? prekeys.map((e) => e.toString()).toList()
          : const <String>[],
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class RecipientEnvelopePayload {
  final String recipientPublicId;
  final String recipientDeviceId;
  final String messageKind;
  final String protocol;
  final String headerB64;
  final String ciphertextB64;
  final Map<String, dynamic> metadata;

  const RecipientEnvelopePayload({
    required this.recipientPublicId,
    required this.recipientDeviceId,
    required this.messageKind,
    required this.protocol,
    required this.headerB64,
    required this.ciphertextB64,
    required this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'recipientPublicId': recipientPublicId,
      'recipientDeviceId': recipientDeviceId,
      'messageKind': messageKind,
      'protocol': protocol,
      'headerB64': headerB64,
      'ciphertextB64': ciphertextB64,
      'metadata': metadata,
    };
  }
}

class StoredEnvelopeView {
  final String envelopeId;
  final String conversationId;
  final String senderPublicId;
  final String senderDeviceId;
  final String recipientPublicId;
  final String recipientDeviceId;
  final String messageKind;
  final String protocol;
  final String headerB64;
  final String ciphertextB64;
  final Map<String, dynamic> metadata;
  final int createdAt;
  final int? deliveredAt;
  final int? ackedAt;
  final int? readAt;
  final int serverSeq;

  const StoredEnvelopeView({
    required this.envelopeId,
    required this.conversationId,
    required this.senderPublicId,
    required this.senderDeviceId,
    required this.recipientPublicId,
    required this.recipientDeviceId,
    required this.messageKind,
    required this.protocol,
    required this.headerB64,
    required this.ciphertextB64,
    required this.metadata,
    required this.createdAt,
    required this.deliveredAt,
    required this.ackedAt,
    required this.readAt,
    required this.serverSeq,
  });

  factory StoredEnvelopeView.fromJson(Map<String, dynamic> json) {
    return StoredEnvelopeView(
      envelopeId: json['envelopeId']?.toString() ?? '',
      conversationId: json['conversationId']?.toString() ?? '',
      senderPublicId: json['senderPublicId']?.toString() ?? '',
      senderDeviceId: json['senderDeviceId']?.toString() ?? '',
      recipientPublicId: json['recipientPublicId']?.toString() ?? '',
      recipientDeviceId: json['recipientDeviceId']?.toString() ?? '',
      messageKind: json['messageKind']?.toString() ?? '',
      protocol: json['protocol']?.toString() ?? '',
      headerB64: json['headerB64']?.toString() ?? '',
      ciphertextB64: json['ciphertextB64']?.toString() ?? '',
      metadata: json['metadata'] is Map
          ? (json['metadata'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      deliveredAt: (json['deliveredAt'] as num?)?.toInt(),
      ackedAt: (json['ackedAt'] as num?)?.toInt(),
      readAt: (json['readAt'] as num?)?.toInt(),
      serverSeq: (json['serverSeq'] as num?)?.toInt() ?? 0,
    );
  }
}

class PendingMailboxResponse {
  final List<StoredEnvelopeView> items;

  const PendingMailboxResponse({
    required this.items,
  });

  factory PendingMailboxResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map(
              (item) => StoredEnvelopeView.fromJson(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList()
        : <StoredEnvelopeView>[];

    return PendingMailboxResponse(items: items);
  }
}

class AckEnvelopeView {
  final String envelopeId;
  final int ackedAt;
  final int? readAt;

  const AckEnvelopeView({
    required this.envelopeId,
    required this.ackedAt,
    required this.readAt,
  });

  factory AckEnvelopeView.fromJson(Map<String, dynamic> json) {
    return AckEnvelopeView(
      envelopeId: json['envelopeId']?.toString() ?? '',
      ackedAt: (json['ackedAt'] as num?)?.toInt() ?? 0,
      readAt: (json['readAt'] as num?)?.toInt(),
    );
  }
}