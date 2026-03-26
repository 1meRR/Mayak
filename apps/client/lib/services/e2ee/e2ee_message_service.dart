@'
import '../../models/app_models.dart';
import 'crypto_bridge.dart';
import 'crypto_models.dart';
import 'mailbox_service.dart';

class E2eeMessageService {
  E2eeMessageService({
    required MailboxService mailboxService,
    required CryptoBridge cryptoBridge,
  })  : _mailboxService = mailboxService,
        _cryptoBridge = cryptoBridge;

  final MailboxService _mailboxService;
  final CryptoBridge _cryptoBridge;

  Future<CryptoBridgeStatus> getBridgeStatus() {
    return _cryptoBridge.getStatus();
  }

  Future<void> ensurePublishedDeviceKeys(UserProfile profile) async {
    final status = await _cryptoBridge.getStatus();
    if (!status.available) {
      throw CryptoBridgeUnavailableException(
        status.reason ?? 'crypto bridge is unavailable',
      );
    }

    final keyPackage = await _cryptoBridge.ensureLocalDeviceIdentity(profile);

    await _mailboxService.uploadDeviceKeyPackage(
      profile: profile,
      payload: keyPackage.toMailboxPayload(),
    );
  }

  Future<List<StoredEnvelopeView>> sendEncryptedText({
    required UserProfile senderProfile,
    required FriendUser friend,
    required String plaintext,
    String? clientMessageId,
  }) async {
    final status = await _cryptoBridge.getStatus();
    if (!status.available) {
      throw CryptoBridgeUnavailableException(
        status.reason ?? 'crypto bridge is unavailable',
      );
    }

    final normalizedText = plaintext.trim();
    if (normalizedText.isEmpty) {
      throw Exception('Пустое сообщение отправлять нельзя');
    }

    await ensurePublishedDeviceKeys(senderProfile);

    final devices = await _mailboxService.listDevicesRaw(friend.publicId);
    final recipientDevices = devices
        .where(
          (device) => device.publicId.trim().toUpperCase() ==
              friend.publicId.trim().toUpperCase(),
        )
        .toList();

    if (recipientDevices.isEmpty) {
      throw Exception('У получателя нет доступных устройств для доставки');
    }

    final remoteBundles = <CryptoRemotePrekeyBundle>[];
    for (final device in recipientDevices) {
      final claimed = await _mailboxService.claimPrekey(
        targetPublicId: friend.publicId,
        targetDeviceId: device.deviceId,
      );
      remoteBundles.add(
        CryptoRemotePrekeyBundle.fromClaimedBundle(claimed),
      );
    }

    final conversationId = buildDirectConversationId(
      senderProfile.publicId,
      friend.publicId,
    );

    final outgoing = await _cryptoBridge.encryptTextMessage(
      senderProfile: senderProfile,
      conversationId: conversationId,
      plaintext: normalizedText,
      clientMessageId: clientMessageId ??
          buildClientMessageId(
            profile: senderProfile,
            unixMs: DateTime.now().millisecondsSinceEpoch,
          ),
      recipientBundles: remoteBundles,
    );

    if (outgoing.isEmpty) {
      throw Exception('crypto bridge did not produce any recipient envelopes');
    }

    return _mailboxService.sendEncryptedEnvelopes(
      profile: senderProfile,
      conversationId: conversationId,
      senderDeviceId: senderProfile.deviceId,
      recipients: outgoing.map((item) => item.toRecipientEnvelopePayload()).toList(),
    );
  }

  Future<List<CryptoDecryptedEnvelope>> fetchAndDecryptPending({
    required UserProfile profile,
    int? afterServerSeq,
    int limit = 100,
    bool ackRead = true,
  }) async {
    final status = await _cryptoBridge.getStatus();
    if (!status.available) {
      throw CryptoBridgeUnavailableException(
        status.reason ?? 'crypto bridge is unavailable',
      );
    }

    final pending = await _mailboxService.fetchPending(
      profile: profile,
      afterServerSeq: afterServerSeq,
      limit: limit,
    );

    final decrypted = <CryptoDecryptedEnvelope>[];

    for (final envelope in pending.items) {
      final item = await _cryptoBridge.decryptEnvelope(
        localProfile: profile,
        envelope: envelope,
      );

      if (item == null) {
        continue;
      }

      decrypted.add(item);

      await _mailboxService.ackEnvelope(
        profile: profile,
        envelopeId: envelope.envelopeId,
        markRead: ackRead,
      );
    }

    return decrypted;
  }
}
'@ | Set-Content -Path "E:\VSCODE\decentra_call_messenger\apps\client\lib\services\e2ee\e2ee_message_service.dart" -Encoding UTF8