import '../../models/app_models.dart';
import 'crypto_bridge.dart';
import 'crypto_models.dart';
import 'mailbox_models.dart';
import 'mailbox_service.dart';
import 'software_crypto_bridge.dart';

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

    // ПАТЧ P-8: проверяем, нужна ли ротация signed prekey,
    // и публикуем обновлённый package если нужно
    CryptoDeviceKeyPackage keyPackage;
    if (_cryptoBridge is SoftwareCryptoBridge) {
      keyPackage = await (_cryptoBridge as SoftwareCryptoBridge)
          .rotateSignedPrekeyIfNeeded(profile);
    } else {
      keyPackage = await _cryptoBridge.ensureLocalDeviceIdentity(profile);
    }

    await _mailboxService.uploadDeviceKeyPackage(
      profile: profile,
      payload: keyPackage.toMailboxPayload(),
    );

    // ПАТЧ P-9: после публикации проверяем OTK pool и дополняем если нужно
    await _refillOtkIfNeeded(profile);
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

    // Устройства получателя
    final recipientDevices = await _mailboxService.listDevicesRaw(friend.publicId);
    final filteredRecipient = recipientDevices
        .where(
          (device) =>
              device.publicId.trim().toUpperCase() ==
              friend.publicId.trim().toUpperCase(),
        )
        .toList();

    if (filteredRecipient.isEmpty) {
      throw Exception('У получателя нет доступных устройств для доставки');
    }

    final remoteBundles = <CryptoRemotePrekeyBundle>[];

    // Prekeys для устройств получателя
    for (final device in filteredRecipient) {
      final claimed = await _mailboxService.claimPrekey(
        targetPublicId: friend.publicId,
        targetDeviceId: device.deviceId,
        callerToken: senderProfile.sessionToken, // ПАТЧ P-4: передаём токен
      );
      remoteBundles.add(
        CryptoRemotePrekeyBundle.fromClaimedBundle(claimed),
      );
    }

    // ПАТЧ: Sender sync copy — шифруем для других устройств отправителя
    // чтобы история была видна на всех устройствах Alice
    final senderDevices = await _mailboxService.listDevicesRaw(senderProfile.publicId);
    final otherSenderDevices = senderDevices
        .where(
          (d) =>
              d.publicId.trim().toUpperCase() ==
                  senderProfile.publicId.trim().toUpperCase() &&
              d.deviceId.trim().toUpperCase() !=
                  senderProfile.deviceId.trim().toUpperCase(),
        )
        .toList();

    for (final device in otherSenderDevices) {
      try {
        final claimed = await _mailboxService.claimPrekey(
          targetPublicId: senderProfile.publicId,
          targetDeviceId: device.deviceId,
          callerToken: senderProfile.sessionToken, // ПАТЧ P-4
        );
        remoteBundles.add(
          CryptoRemotePrekeyBundle.fromClaimedBundle(claimed),
        );
      } catch (_) {
        // Не блокируем отправку если sync copy не удалась
      }
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

    final result = await _mailboxService.sendEncryptedEnvelopes(
      profile: senderProfile,
      conversationId: conversationId,
      senderDeviceId: senderProfile.deviceId,
      recipients:
          outgoing.map((item) => item.toRecipientEnvelopePayload()).toList(),
    );

    // ПАТЧ P-9: после отправки проверяем OTK pool
    await _refillOtkIfNeeded(senderProfile);

    return result;
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

    // ПАТЧ P-9: после получения сообщений (OTK могли быть потреблены)
    // проверяем пул
    await _refillOtkIfNeeded(profile);

    return decrypted;
  }

  // ПАТЧ P-9: вспомогательный метод пополнения OTK пула
  Future<void> _refillOtkIfNeeded(UserProfile profile) async {
    if (_cryptoBridge is! SoftwareCryptoBridge) return;

    final bridge = _cryptoBridge as SoftwareCryptoBridge;
    try {
      final needs = await bridge.needsOtkRefill(profile);
      if (!needs) return;

      final newOtks = await bridge.generateAndSaveOtkBatch(profile);
      if (newOtks.isNotEmpty) {
        await _mailboxService.replenishOneTimePrekeys(
          profile: profile,
          oneTimePrekeys: newOtks,
        );
      }
    } catch (_) {
      // OTK refill не должен ронать основной flow
    }
  }
}
