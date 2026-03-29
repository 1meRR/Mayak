import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../models/app_models.dart';
import 'crypto_bridge.dart';
import 'crypto_models.dart';
import 'mailbox_models.dart';
import 'secure_device_storage.dart';

/// Software E2EE bridge:
/// - X3DH-like async bootstrap over X25519 prekey bundles
/// - Double-Ratchet style DH + symmetric ratchet evolution
/// - AES-GCM authenticated encryption
class SoftwareCryptoBridge implements CryptoBridge {
  SoftwareCryptoBridge({SecureDeviceStorage? secureStorage})
      : _secureStorage = secureStorage ?? SecureDeviceStorage();

  final SecureDeviceStorage _secureStorage;

  static const _identityKeyName = 'sw_crypto_identity_v3';
  static const _sessionsKeyName = 'sw_crypto_sessions_v3';
  static const _keyAlgorithm = 'x25519+ed25519';
  static const _maxSkippedMessageKeys = 256;

  final X25519 _x25519 = X25519();
  final Ed25519 _ed25519 = Ed25519();
  final Hkdf _hkdf32 = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Hkdf _hkdf64 = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
  final Hmac _hmac = Hmac.sha256();
  final AesGcm _aead = AesGcm.with256bits();

  @override
  Future<CryptoBridgeStatus> getStatus() async {
    return const CryptoBridgeStatus(
      available: true,
      backend: 'software_signal_double_ratchet_v1',
      reason: null,
    );
  }

  @override
  Future<CryptoDeviceKeyPackage> ensureLocalDeviceIdentity(
    UserProfile profile,
  ) async {
    final ref = _normalizeProfile(profile);
    final existing = await _loadIdentityState(ref);
    if (existing != null) {
      return _toKeyPackage(existing);
    }

    final identity = await _x25519.newKeyPair();
    final identityPub = await identity.extractPublicKey();

    final signing = await _ed25519.newKeyPair();
    final signingPub = await signing.extractPublicKey();

    final signedPrekey = await _x25519.newKeyPair();
    final signedPrekeyPub = await signedPrekey.extractPublicKey();

    final signedPrekeySignature = await _ed25519.sign(
      signedPrekeyPub.bytes,
      keyPair: signing,
    );

    final oneTime = <_OneTimePrivatePrekey>[];
    for (var i = 0; i < 64; i++) {
      final kp = await _x25519.newKeyPair();
      final pub = await kp.extractPublicKey();
      oneTime.add(
        _OneTimePrivatePrekey(
          id: 'otk_${i + 1}_${_randomToken(8)}',
          publicKeyB64: _b64(pub.bytes),
          privateKeyB64: _b64(await kp.extractPrivateKeyBytes()),
          consumedAt: null,
        ),
      );
    }

    final state = _LocalIdentityState(
      deviceId: ref.deviceId,
      identityPublicKeyB64: _b64(identityPub.bytes),
      identityPrivateKeyB64: _b64(await identity.extractPrivateKeyBytes()),
      signingPublicKeyB64: _b64(signingPub.bytes),
      signingPrivateKeyB64: _b64(await signing.extractPrivateKeyBytes()),
      signedPrekeyPublicKeyB64: _b64(signedPrekeyPub.bytes),
      signedPrekeyPrivateKeyB64: _b64(await signedPrekey.extractPrivateKeyBytes()),
      signedPrekeySignatureB64: _b64(signedPrekeySignature.bytes),
      signedPrekeyKeyId: 1,
      oneTimePrekeys: oneTime,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _saveIdentityState(ref, state);
    return _toKeyPackage(state);
  }

  @override
  Future<List<CryptoOutgoingEnvelopeDraft>> encryptTextMessage({
    required UserProfile senderProfile,
    required String conversationId,
    required String plaintext,
    required String clientMessageId,
    required List<CryptoRemotePrekeyBundle> recipientBundles,
  }) async {
    final ref = _normalizeProfile(senderProfile);
    final localState = await _requireIdentityState(ref);
    final sessions = await _loadSessions(ref);

    final out = <CryptoOutgoingEnvelopeDraft>[];

    for (final bundle in recipientBundles) {
      final key = _sessionStorageKey(
        publicId: bundle.publicId,
        deviceId: bundle.deviceId,
      );

      var session = sessions[key];
      _OutboundInit? init;

      if (session == null) {
        init = await _createOutboundSession(localState, bundle);
        session = init.session;
      }

      if (session.pendingSendDhRatchet) {
        session = await _applySendDhRatchet(session);
      }

      final messageKey = await _deriveMessageKey(_b64d(session.sendChainKeyB64));
      final nextSendChain =
          await _deriveNextChainKey(_b64d(session.sendChainKeyB64));

      final messageNo = session.sendChainMessageNo + 1;
      final header = <String, dynamic>{
        'v': 1,
        'type': init == null ? 'msg' : 'init',
        'sessionId': session.sessionId,
        'senderPublicId': ref.publicId,
        'senderDeviceId': ref.deviceId,
        'recipientPublicId': bundle.publicId.trim().toUpperCase(),
        'recipientDeviceId': bundle.deviceId.trim().toUpperCase(),
        'senderRatchetKeyB64': session.selfRatchetPublicKeyB64,
        'pn': session.previousSendingChainLength,
        'n': messageNo,
        'nonceB64': _b64(_randomBytes(12)),
        if (init != null) ...{
          'senderIdentityKeyB64': localState.identityPublicKeyB64,
          'senderHandshakeEphemeralB64': init.handshakeEphemeralPublicKeyB64,
          'recipientSignedPrekeyKeyId': bundle.signedPrekeyKeyId,
          'recipientOneTimePrekeyRef': init.usedOneTimePrekeyRef,
        },
      };

      final aad = utf8.encode(jsonEncode(header));

      final payload = utf8.encode(jsonEncode({
        'v': 1,
        'conversationId': conversationId,
        'clientMessageId': clientMessageId,
        'text': plaintext,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));

      final nonce = _b64d(header['nonceB64']!.toString());

      final secretBox = await _aead.encrypt(
        payload,
        secretKey: SecretKey(messageKey),
        nonce: nonce,
        aad: aad,
      );

      out.add(
        CryptoOutgoingEnvelopeDraft(
          recipientPublicId: bundle.publicId.trim().toUpperCase(),
          recipientDeviceId: bundle.deviceId.trim().toUpperCase(),
          messageKind: 'text',
          protocol: 'signal-double-ratchet-v1',
          headerB64: _b64(utf8.encode(jsonEncode(header))),
          ciphertextB64: _b64(
            utf8.encode(
              jsonEncode({
                'ciphertextB64': _b64(secretBox.cipherText),
                'macB64': _b64(secretBox.mac.bytes),
              }),
            ),
          ),
          metadata: {
            'sessionId': session.sessionId,
            'chain': 'send',
            'n': messageNo,
          },
        ),
      );

      sessions[key] = session.copyWith(
        sendChainKeyB64: _b64(nextSendChain),
        sendChainMessageNo: messageNo,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    await _saveSessions(ref, sessions);
    return out;
  }

  @override
  Future<CryptoDecryptedEnvelope?> decryptEnvelope({
    required UserProfile localProfile,
    required StoredEnvelopeView envelope,
  }) async {
    if (envelope.protocol.trim() != 'signal-double-ratchet-v1') {
      return null;
    }

    final ref = _normalizeProfile(localProfile);
    var localState = await _requireIdentityState(ref);
    final sessions = await _loadSessions(ref);

    final header = _toMap(jsonDecode(utf8.decode(_b64d(envelope.headerB64))));
    final senderPublicId =
        header['senderPublicId']?.toString() ?? envelope.senderPublicId;
    final senderDeviceId =
        header['senderDeviceId']?.toString() ?? envelope.senderDeviceId;

    final key = _sessionStorageKey(
      publicId: senderPublicId,
      deviceId: senderDeviceId,
    );

    var session = sessions[key];
    if (session == null) {
      if ((header['type']?.toString() ?? '') != 'init') {
        return null;
      }
      final created = await _createInboundSession(ref, localState, header);
      session = created.session;
      localState = created.updatedIdentityState;
      await _saveIdentityState(ref, localState);
    }

    final remoteRatchet = header['senderRatchetKeyB64']?.toString() ?? '';
    if (remoteRatchet.isEmpty) {
      return null;
    }

    if (remoteRatchet != session.remoteRatchetPublicKeyB64) {
      session = await _applyReceiveDhRatchet(
        session: session,
        newRemoteRatchetPubB64: remoteRatchet,
      );
    }

    final incomingN = (header['n'] as num?)?.toInt() ?? (session.recvChainMessageNo + 1);
    final skippedId = _skippedKeyId(session.remoteRatchetPublicKeyB64, incomingN);

    Uint8List messageKey;
    Uint8List nextRecvChain;
    int nextRecvNo;
    Map<String, String> nextSkipped = {...session.skippedMessageKeys};

    final skippedExisting = nextSkipped.remove(skippedId);
    if (skippedExisting != null) {
      messageKey = _b64d(skippedExisting);
      nextRecvChain = _b64d(session.recvChainKeyB64);
      nextRecvNo = session.recvChainMessageNo;
    } else if (incomingN <= session.recvChainMessageNo) {
      return null;
    } else {
      final derived = await _deriveSkippedKeys(
        session: session,
        targetMessageNo: incomingN,
      );
      messageKey = derived.messageKey;
      nextRecvChain = derived.nextChainKey;
      nextRecvNo = derived.newRecvMessageNo;
      nextSkipped = derived.skippedMessageKeys;
    }

    final aad = utf8.encode(jsonEncode(header));
    final nonce = _b64d(header['nonceB64']?.toString() ?? '');
    final cipher = _toMap(jsonDecode(utf8.decode(_b64d(envelope.ciphertextB64))));
    final cipherText = _b64d(cipher['ciphertextB64']?.toString() ?? '');
    final mac = Mac(_b64d(cipher['macB64']?.toString() ?? ''));

    final plain = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(messageKey),
      aad: aad,
    );

    final payload = _toMap(jsonDecode(utf8.decode(plain)));

    sessions[key] = session.copyWith(
      recvChainKeyB64: _b64(nextRecvChain),
      recvChainMessageNo: nextRecvNo,
      skippedMessageKeys: nextSkipped,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    await _saveSessions(ref, sessions);

    return CryptoDecryptedEnvelope(
      envelopeId: envelope.envelopeId,
      conversationId:
          payload['conversationId']?.toString() ?? envelope.conversationId,
      senderPublicId: senderPublicId,
      senderDeviceId: senderDeviceId,
      messageKind: envelope.messageKind,
      protocol: envelope.protocol,
      plaintext: payload['text']?.toString() ?? '',
      clientMessageId: payload['clientMessageId']?.toString(),
      createdAt: envelope.createdAt,
      serverSeq: envelope.serverSeq,
    );
  }

  Future<_OutboundInit> _createOutboundSession(
    _LocalIdentityState local,
    CryptoRemotePrekeyBundle bundle,
  ) async {
    final localIdentity =
        _x25519KeyPair(local.identityPrivateKeyB64, local.identityPublicKeyB64);

    final handshakeEphemeral = await _x25519.newKeyPair();
    final handshakeEphemeralPub = await handshakeEphemeral.extractPublicKey();

    final remoteIdentity = _x25519Public(bundle.identityKeyB64);
    final remoteSignedPrekey = _x25519Public(bundle.signedPrekeyB64);

    final dh1 = await _shared(localIdentity, remoteSignedPrekey);
    final dh2 = await _shared(handshakeEphemeral, remoteIdentity);
    final dh3 = await _shared(handshakeEphemeral, remoteSignedPrekey);

    Uint8List? dh4;
    String? usedOneTimeRef;
    final claimedOtk = _parseClaimedOneTimePublic(bundle.claimedOneTimePrekeyB64);
    if (claimedOtk != null) {
      dh4 = await _shared(handshakeEphemeral, _x25519Public(claimedOtk.publicKeyB64));
      usedOneTimeRef = claimedOtk.id;
    }

    final root = await _deriveInitialRoot([dh1, dh2, dh3, if (dh4 != null) dh4]);

    final sendRatchet = await _x25519.newKeyPair();
    final sendRatchetPub = await sendRatchet.extractPublicKey();

    final first = await _kdfRootChain(
      rootKey: root,
      dhOut: await _shared(sendRatchet, remoteSignedPrekey),
      label: 'bootstrap_send',
    );

    final recvInit = await _kdfRootChain(
      rootKey: first.newRootKey,
      dhOut: await _shared(
        _x25519KeyPair(local.signedPrekeyPrivateKeyB64, local.signedPrekeyPublicKeyB64),
        sendRatchetPub,
      ),
      label: 'bootstrap_recv',
    );

    final session = _DeviceSession(
      sessionId: 'sess_${bundle.publicId}_${bundle.deviceId}_${_randomToken(8)}',
      remotePublicId: bundle.publicId.trim().toUpperCase(),
      remoteDeviceId: bundle.deviceId.trim().toUpperCase(),
      rootKeyB64: _b64(recvInit.newRootKey),
      selfRatchetPrivateKeyB64: _b64(await sendRatchet.extractPrivateKeyBytes()),
      selfRatchetPublicKeyB64: _b64(sendRatchetPub.bytes),
      remoteRatchetPublicKeyB64: bundle.signedPrekeyB64,
      sendChainKeyB64: _b64(first.newChainKey),
      recvChainKeyB64: _b64(recvInit.newChainKey),
      sendChainMessageNo: 0,
      recvChainMessageNo: 0,
      previousSendingChainLength: 0,
      pendingSendDhRatchet: false,
      skippedMessageKeys: const <String, String>{},
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    return _OutboundInit(
      session: session,
      handshakeEphemeralPublicKeyB64: _b64(handshakeEphemeralPub.bytes),
      usedOneTimePrekeyRef: usedOneTimeRef,
    );
  }

  Future<_InboundSessionCreation> _createInboundSession(
    _ProfileRef ref,
    _LocalIdentityState local,
    Map<String, dynamic> header,
  ) async {
    final remotePublicId = header['senderPublicId']?.toString() ?? '';
    final remoteDeviceId = header['senderDeviceId']?.toString() ?? '';

    final senderIdentity = _x25519Public(header['senderIdentityKeyB64']?.toString() ?? '');
    final senderHandshakeEphemeral =
        _x25519Public(header['senderHandshakeEphemeralB64']?.toString() ?? '');
    final senderRatchetPubB64 = header['senderRatchetKeyB64']?.toString() ?? '';

    final identity =
        _x25519KeyPair(local.identityPrivateKeyB64, local.identityPublicKeyB64);
    final signedPrekey = _x25519KeyPair(
      local.signedPrekeyPrivateKeyB64,
      local.signedPrekeyPublicKeyB64,
    );

    final dh1 = await _shared(signedPrekey, senderIdentity);
    final dh2 = await _shared(identity, senderHandshakeEphemeral);
    final dh3 = await _shared(signedPrekey, senderHandshakeEphemeral);

    Uint8List? dh4;
    var updated = local;
    final oneTimeRef = header['recipientOneTimePrekeyRef']?.toString();
    if (oneTimeRef != null && oneTimeRef.trim().isNotEmpty) {
      final otk = local.oneTimePrekeys.firstWhere(
        (item) => item.id == oneTimeRef,
        orElse: () => const _OneTimePrivatePrekey.empty(),
      );
      if (otk.id.isNotEmpty && otk.consumedAt == null) {
        final otkPair = _x25519KeyPair(otk.privateKeyB64, otk.publicKeyB64);
        dh4 = await _shared(otkPair, senderHandshakeEphemeral);
        updated = local.consumeOneTimePrekey(
          prekeyId: otk.id,
          consumedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }

    final root = await _deriveInitialRoot([dh1, dh2, dh3, if (dh4 != null) dh4]);

    final recv1 = await _kdfRootChain(
      rootKey: root,
      dhOut: await _shared(signedPrekey, _x25519Public(senderRatchetPubB64)),
      label: 'bootstrap_recv',
    );

    final selfRatchet = await _x25519.newKeyPair();
    final selfRatchetPub = await selfRatchet.extractPublicKey();

    final send1 = await _kdfRootChain(
      rootKey: recv1.newRootKey,
      dhOut: await _shared(selfRatchet, _x25519Public(senderRatchetPubB64)),
      label: 'bootstrap_send',
    );

    final session = _DeviceSession(
      sessionId: 'sess_${remotePublicId}_${remoteDeviceId}_in',
      remotePublicId: remotePublicId.trim().toUpperCase(),
      remoteDeviceId: remoteDeviceId.trim().toUpperCase(),
      rootKeyB64: _b64(send1.newRootKey),
      selfRatchetPrivateKeyB64: _b64(await selfRatchet.extractPrivateKeyBytes()),
      selfRatchetPublicKeyB64: _b64(selfRatchetPub.bytes),
      remoteRatchetPublicKeyB64: senderRatchetPubB64,
      sendChainKeyB64: _b64(send1.newChainKey),
      recvChainKeyB64: _b64(recv1.newChainKey),
      sendChainMessageNo: 0,
      recvChainMessageNo: 0,
      previousSendingChainLength: 0,
      pendingSendDhRatchet: false,
      skippedMessageKeys: const <String, String>{},
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    return _InboundSessionCreation(session: session, updatedIdentityState: updated);
  }

  Future<_DeviceSession> _applyReceiveDhRatchet({
    required _DeviceSession session,
    required String newRemoteRatchetPubB64,
  }) async {
    final selfPair =
        _x25519KeyPair(session.selfRatchetPrivateKeyB64, session.selfRatchetPublicKeyB64);

    final recv = await _kdfRootChain(
      rootKey: _b64d(session.rootKeyB64),
      dhOut: await _shared(selfPair, _x25519Public(newRemoteRatchetPubB64)),
      label: 'recv_dh',
    );

    return session.copyWith(
      rootKeyB64: _b64(recv.newRootKey),
      recvChainKeyB64: _b64(recv.newChainKey),
      recvChainMessageNo: 0,
      remoteRatchetPublicKeyB64: newRemoteRatchetPubB64,
      previousSendingChainLength: session.sendChainMessageNo,
      pendingSendDhRatchet: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<_DeviceSession> _applySendDhRatchet(_DeviceSession session) async {
    final remote = _x25519Public(session.remoteRatchetPublicKeyB64);
    final nextSelf = await _x25519.newKeyPair();
    final nextSelfPub = await nextSelf.extractPublicKey();

    final send = await _kdfRootChain(
      rootKey: _b64d(session.rootKeyB64),
      dhOut: await _shared(nextSelf, remote),
      label: 'send_dh',
    );

    return session.copyWith(
      rootKeyB64: _b64(send.newRootKey),
      selfRatchetPrivateKeyB64: _b64(await nextSelf.extractPrivateKeyBytes()),
      selfRatchetPublicKeyB64: _b64(nextSelfPub.bytes),
      sendChainKeyB64: _b64(send.newChainKey),
      sendChainMessageNo: 0,
      pendingSendDhRatchet: false,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }



  String _skippedKeyId(String ratchetPubB64, int messageNo) {
    return '$ratchetPubB64:$messageNo';
  }

  Future<_SkippedDeriveResult> _deriveSkippedKeys({
    required _DeviceSession session,
    required int targetMessageNo,
  }) async {
    var chainKey = _b64d(session.recvChainKeyB64);
    var cursor = session.recvChainMessageNo;
    final skipped = <String, String>{...session.skippedMessageKeys};

    while (cursor + 1 < targetMessageNo) {
      final mk = await _deriveMessageKey(chainKey);
      final next = await _deriveNextChainKey(chainKey);
      cursor += 1;
      skipped[_skippedKeyId(session.remoteRatchetPublicKeyB64, cursor)] = _b64(mk);
      chainKey = next;
    }

    final messageKey = await _deriveMessageKey(chainKey);
    final nextChain = await _deriveNextChainKey(chainKey);

    if (skipped.length > _maxSkippedMessageKeys) {
      final keys = skipped.keys.toList(growable: false);
      final overflow = skipped.length - _maxSkippedMessageKeys;
      for (var i = 0; i < overflow; i++) {
        skipped.remove(keys[i]);
      }
    }

    return _SkippedDeriveResult(
      messageKey: messageKey,
      nextChainKey: nextChain,
      newRecvMessageNo: targetMessageNo,
      skippedMessageKeys: skipped,
    );
  }

  Future<Uint8List> _deriveInitialRoot(List<Uint8List> sharedParts) async {
    final joined = Uint8List.fromList(sharedParts.expand((e) => e).toList());
    final root = await _hkdf32.deriveKey(
      secretKey: SecretKey(joined),
      nonce: List<int>.filled(32, 0),
      info: utf8.encode('mayak_x3dh_root_v1'),
    );
    return Uint8List.fromList(await root.extractBytes());
  }

  Future<_RootChain> _kdfRootChain({
    required Uint8List rootKey,
    required Uint8List dhOut,
    required String label,
  }) async {
    final key = await _hkdf64.deriveKey(
      secretKey: SecretKey(dhOut),
      nonce: rootKey,
      info: utf8.encode('mayak_dr_$label'),
    );

    final bytes = Uint8List.fromList(await key.extractBytes());
    return _RootChain(
      newRootKey: bytes.sublist(0, 32),
      newChainKey: bytes.sublist(32, 64),
    );
  }

  Future<Uint8List> _deriveMessageKey(Uint8List chainKey) async {
    final mac = await _hmac.calculateMac(
      utf8.encode('msg_key'),
      secretKey: SecretKey(chainKey),
    );
    return Uint8List.fromList(mac.bytes.sublist(0, 32));
  }

  Future<Uint8List> _deriveNextChainKey(Uint8List chainKey) async {
    final mac = await _hmac.calculateMac(
      utf8.encode('next_chain'),
      secretKey: SecretKey(chainKey),
    );
    return Uint8List.fromList(mac.bytes.sublist(0, 32));
  }

  Future<Uint8List> _shared(KeyPair local, SimplePublicKey remote) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: local,
      remotePublicKey: remote,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  SimplePublicKey _x25519Public(String publicKeyB64) {
    return SimplePublicKey(_b64d(publicKeyB64), type: KeyPairType.x25519);
  }

  KeyPair _x25519KeyPair(String privateB64, String publicB64) {
    return SimpleKeyPairData(
      _b64d(privateB64),
      publicKey: _x25519Public(publicB64),
      type: KeyPairType.x25519,
    );
  }

  CryptoDeviceKeyPackage _toKeyPackage(_LocalIdentityState state) {
    return CryptoDeviceKeyPackage(
      deviceId: state.deviceId,
      identityKeyAlg: _keyAlgorithm,
      identityKeyB64: state.identityPublicKeyB64,
      identitySigningKeyB64: state.signingPublicKeyB64,
      signedPrekeyB64: state.signedPrekeyPublicKeyB64,
      signedPrekeySignatureB64: state.signedPrekeySignatureB64,
      signedPrekeyKeyId: state.signedPrekeyKeyId,
      oneTimePrekeys: state.oneTimePrekeys
          .where((otk) => otk.consumedAt == null)
          .map((otk) => '${otk.id}:${otk.publicKeyB64}')
          .toList(growable: false),
    );
  }

  Future<_LocalIdentityState?> _loadIdentityState(_ProfileRef ref) async {
    final raw = await _secureStorage.readJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _identityKeyName,
    );
    return raw == null ? null : _LocalIdentityState.fromJson(raw);
  }

  Future<_LocalIdentityState> _requireIdentityState(_ProfileRef ref) async {
    final state = await _loadIdentityState(ref);
    if (state == null) {
      throw CryptoBridgeUnavailableException(
        'No local crypto identity for ${ref.publicId}:${ref.deviceId}',
      );
    }
    return state;
  }

  Future<void> _saveIdentityState(_ProfileRef ref, _LocalIdentityState state) {
    return _secureStorage.writeJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _identityKeyName,
      value: state.toJson(),
    );
  }

  Future<Map<String, _DeviceSession>> _loadSessions(_ProfileRef ref) async {
    final raw = await _secureStorage.readJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _sessionsKeyName,
    );

    if (raw == null || raw['sessions'] is! Map) {
      return <String, _DeviceSession>{};
    }

    final sessionsRaw = raw['sessions'] as Map;
    return sessionsRaw.map(
      (k, v) => MapEntry(
        k.toString(),
        _DeviceSession.fromJson(_toMap(v)),
      ),
    );
  }

  Future<void> _saveSessions(
    _ProfileRef ref,
    Map<String, _DeviceSession> sessions,
  ) {
    return _secureStorage.writeJson(
      publicId: ref.publicId,
      deviceId: ref.deviceId,
      name: _sessionsKeyName,
      value: {
        'sessions': sessions.map((k, v) => MapEntry(k, v.toJson())),
      },
    );
  }

  _ProfileRef _normalizeProfile(UserProfile profile) {
    return _ProfileRef(
      publicId: profile.publicId.trim().toUpperCase(),
      deviceId: profile.deviceId.trim().toUpperCase(),
    );
  }

  _ClaimedOneTimePublic? _parseClaimedOneTimePublic(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final idx = raw.indexOf(':');
    if (idx <= 0 || idx + 1 >= raw.length) {
      return _ClaimedOneTimePublic(id: 'otk_unknown', publicKeyB64: raw.trim());
    }
    return _ClaimedOneTimePublic(
      id: raw.substring(0, idx).trim(),
      publicKeyB64: raw.substring(idx + 1).trim(),
    );
  }

  String _sessionStorageKey({required String publicId, required String deviceId}) {
    return '${publicId.trim().toUpperCase()}:${deviceId.trim().toUpperCase()}';
  }

  String _b64(List<int> bytes) => base64Encode(bytes);

  Uint8List _b64d(String input) {
    if (input.trim().isEmpty) {
      return Uint8List(0);
    }
    return Uint8List.fromList(base64Decode(input));
  }

  String _randomToken(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    final b = StringBuffer();
    for (var i = 0; i < length; i++) {
      b.write(chars[r.nextInt(chars.length)]);
    }
    return b.toString();
  }

  Uint8List _randomBytes(int length) {
    final r = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => r.nextInt(256)),
    );
  }

  static Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }
}

class _ProfileRef {
  const _ProfileRef({required this.publicId, required this.deviceId});

  final String publicId;
  final String deviceId;
}

class _ClaimedOneTimePublic {
  const _ClaimedOneTimePublic({required this.id, required this.publicKeyB64});

  final String id;
  final String publicKeyB64;
}

class _SkippedDeriveResult {
  const _SkippedDeriveResult({
    required this.messageKey,
    required this.nextChainKey,
    required this.newRecvMessageNo,
    required this.skippedMessageKeys,
  });

  final Uint8List messageKey;
  final Uint8List nextChainKey;
  final int newRecvMessageNo;
  final Map<String, String> skippedMessageKeys;
}

class _RootChain {
  const _RootChain({required this.newRootKey, required this.newChainKey});

  final Uint8List newRootKey;
  final Uint8List newChainKey;
}

class _OutboundInit {
  const _OutboundInit({
    required this.session,
    required this.handshakeEphemeralPublicKeyB64,
    required this.usedOneTimePrekeyRef,
  });

  final _DeviceSession session;
  final String handshakeEphemeralPublicKeyB64;
  final String? usedOneTimePrekeyRef;
}

class _InboundSessionCreation {
  const _InboundSessionCreation({
    required this.session,
    required this.updatedIdentityState,
  });

  final _DeviceSession session;
  final _LocalIdentityState updatedIdentityState;
}

class _OneTimePrivatePrekey {
  const _OneTimePrivatePrekey({
    required this.id,
    required this.publicKeyB64,
    required this.privateKeyB64,
    required this.consumedAt,
  });

  const _OneTimePrivatePrekey.empty()
      : id = '',
        publicKeyB64 = '',
        privateKeyB64 = '',
        consumedAt = null;

  final String id;
  final String publicKeyB64;
  final String privateKeyB64;
  final int? consumedAt;

  _OneTimePrivatePrekey copyWith({int? consumedAt}) {
    return _OneTimePrivatePrekey(
      id: id,
      publicKeyB64: publicKeyB64,
      privateKeyB64: privateKeyB64,
      consumedAt: consumedAt ?? this.consumedAt,
    );
  }

  factory _OneTimePrivatePrekey.fromJson(Map<String, dynamic> json) {
    return _OneTimePrivatePrekey(
      id: json['id']?.toString() ?? '',
      publicKeyB64: json['publicKeyB64']?.toString() ?? '',
      privateKeyB64: json['privateKeyB64']?.toString() ?? '',
      consumedAt: (json['consumedAt'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'publicKeyB64': publicKeyB64,
      'privateKeyB64': privateKeyB64,
      'consumedAt': consumedAt,
    };
  }
}

class _LocalIdentityState {
  const _LocalIdentityState({
    required this.deviceId,
    required this.identityPublicKeyB64,
    required this.identityPrivateKeyB64,
    required this.signingPublicKeyB64,
    required this.signingPrivateKeyB64,
    required this.signedPrekeyPublicKeyB64,
    required this.signedPrekeyPrivateKeyB64,
    required this.signedPrekeySignatureB64,
    required this.signedPrekeyKeyId,
    required this.oneTimePrekeys,
    required this.updatedAt,
  });

  final String deviceId;
  final String identityPublicKeyB64;
  final String identityPrivateKeyB64;
  final String signingPublicKeyB64;
  final String signingPrivateKeyB64;
  final String signedPrekeyPublicKeyB64;
  final String signedPrekeyPrivateKeyB64;
  final String signedPrekeySignatureB64;
  final int signedPrekeyKeyId;
  final List<_OneTimePrivatePrekey> oneTimePrekeys;
  final int updatedAt;

  _LocalIdentityState consumeOneTimePrekey({
    required String prekeyId,
    required int consumedAt,
  }) {
    return _LocalIdentityState(
      deviceId: deviceId,
      identityPublicKeyB64: identityPublicKeyB64,
      identityPrivateKeyB64: identityPrivateKeyB64,
      signingPublicKeyB64: signingPublicKeyB64,
      signingPrivateKeyB64: signingPrivateKeyB64,
      signedPrekeyPublicKeyB64: signedPrekeyPublicKeyB64,
      signedPrekeyPrivateKeyB64: signedPrekeyPrivateKeyB64,
      signedPrekeySignatureB64: signedPrekeySignatureB64,
      signedPrekeyKeyId: signedPrekeyKeyId,
      oneTimePrekeys: oneTimePrekeys
          .map(
            (k) => k.id == prekeyId ? k.copyWith(consumedAt: consumedAt) : k,
          )
          .toList(growable: false),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory _LocalIdentityState.fromJson(Map<String, dynamic> json) {
    final otkRaw = json['oneTimePrekeys'];
    return _LocalIdentityState(
      deviceId: json['deviceId']?.toString() ?? '',
      identityPublicKeyB64: json['identityPublicKeyB64']?.toString() ?? '',
      identityPrivateKeyB64: json['identityPrivateKeyB64']?.toString() ?? '',
      signingPublicKeyB64: json['signingPublicKeyB64']?.toString() ?? '',
      signingPrivateKeyB64: json['signingPrivateKeyB64']?.toString() ?? '',
      signedPrekeyPublicKeyB64:
          json['signedPrekeyPublicKeyB64']?.toString() ?? '',
      signedPrekeyPrivateKeyB64:
          json['signedPrekeyPrivateKeyB64']?.toString() ?? '',
      signedPrekeySignatureB64:
          json['signedPrekeySignatureB64']?.toString() ?? '',
      signedPrekeyKeyId: (json['signedPrekeyKeyId'] as num?)?.toInt() ?? 1,
      oneTimePrekeys: otkRaw is List
          ? otkRaw
              .whereType<Map>()
              .map(
                (item) => _OneTimePrivatePrekey.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList(growable: false)
          : const <_OneTimePrivatePrekey>[],
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'identityPublicKeyB64': identityPublicKeyB64,
      'identityPrivateKeyB64': identityPrivateKeyB64,
      'signingPublicKeyB64': signingPublicKeyB64,
      'signingPrivateKeyB64': signingPrivateKeyB64,
      'signedPrekeyPublicKeyB64': signedPrekeyPublicKeyB64,
      'signedPrekeyPrivateKeyB64': signedPrekeyPrivateKeyB64,
      'signedPrekeySignatureB64': signedPrekeySignatureB64,
      'signedPrekeyKeyId': signedPrekeyKeyId,
      'oneTimePrekeys': oneTimePrekeys.map((k) => k.toJson()).toList(),
      'updatedAt': updatedAt,
    };
  }
}

class _DeviceSession {
  const _DeviceSession({
    required this.sessionId,
    required this.remotePublicId,
    required this.remoteDeviceId,
    required this.rootKeyB64,
    required this.selfRatchetPrivateKeyB64,
    required this.selfRatchetPublicKeyB64,
    required this.remoteRatchetPublicKeyB64,
    required this.sendChainKeyB64,
    required this.recvChainKeyB64,
    required this.sendChainMessageNo,
    required this.recvChainMessageNo,
    required this.previousSendingChainLength,
    required this.pendingSendDhRatchet,
    required this.skippedMessageKeys,
    required this.createdAt,
    required this.updatedAt,
  });

  final String sessionId;
  final String remotePublicId;
  final String remoteDeviceId;
  final String rootKeyB64;
  final String selfRatchetPrivateKeyB64;
  final String selfRatchetPublicKeyB64;
  final String remoteRatchetPublicKeyB64;
  final String sendChainKeyB64;
  final String recvChainKeyB64;
  final int sendChainMessageNo;
  final int recvChainMessageNo;
  final int previousSendingChainLength;
  final bool pendingSendDhRatchet;
  final Map<String, String> skippedMessageKeys;
  final int createdAt;
  final int updatedAt;

  _DeviceSession copyWith({
    String? rootKeyB64,
    String? selfRatchetPrivateKeyB64,
    String? selfRatchetPublicKeyB64,
    String? remoteRatchetPublicKeyB64,
    String? sendChainKeyB64,
    String? recvChainKeyB64,
    int? sendChainMessageNo,
    int? recvChainMessageNo,
    int? previousSendingChainLength,
    bool? pendingSendDhRatchet,
    Map<String, String>? skippedMessageKeys,
    int? updatedAt,
  }) {
    return _DeviceSession(
      sessionId: sessionId,
      remotePublicId: remotePublicId,
      remoteDeviceId: remoteDeviceId,
      rootKeyB64: rootKeyB64 ?? this.rootKeyB64,
      selfRatchetPrivateKeyB64:
          selfRatchetPrivateKeyB64 ?? this.selfRatchetPrivateKeyB64,
      selfRatchetPublicKeyB64:
          selfRatchetPublicKeyB64 ?? this.selfRatchetPublicKeyB64,
      remoteRatchetPublicKeyB64:
          remoteRatchetPublicKeyB64 ?? this.remoteRatchetPublicKeyB64,
      sendChainKeyB64: sendChainKeyB64 ?? this.sendChainKeyB64,
      recvChainKeyB64: recvChainKeyB64 ?? this.recvChainKeyB64,
      sendChainMessageNo: sendChainMessageNo ?? this.sendChainMessageNo,
      recvChainMessageNo: recvChainMessageNo ?? this.recvChainMessageNo,
      previousSendingChainLength:
          previousSendingChainLength ?? this.previousSendingChainLength,
      pendingSendDhRatchet: pendingSendDhRatchet ?? this.pendingSendDhRatchet,
      skippedMessageKeys: skippedMessageKeys ?? this.skippedMessageKeys,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory _DeviceSession.fromJson(Map<String, dynamic> json) {
    return _DeviceSession(
      sessionId: json['sessionId']?.toString() ?? '',
      remotePublicId: json['remotePublicId']?.toString() ?? '',
      remoteDeviceId: json['remoteDeviceId']?.toString() ?? '',
      rootKeyB64: json['rootKeyB64']?.toString() ?? '',
      selfRatchetPrivateKeyB64:
          json['selfRatchetPrivateKeyB64']?.toString() ?? '',
      selfRatchetPublicKeyB64: json['selfRatchetPublicKeyB64']?.toString() ?? '',
      remoteRatchetPublicKeyB64:
          json['remoteRatchetPublicKeyB64']?.toString() ?? '',
      sendChainKeyB64: json['sendChainKeyB64']?.toString() ?? '',
      recvChainKeyB64: json['recvChainKeyB64']?.toString() ?? '',
      sendChainMessageNo: (json['sendChainMessageNo'] as num?)?.toInt() ?? 0,
      recvChainMessageNo: (json['recvChainMessageNo'] as num?)?.toInt() ?? 0,
      previousSendingChainLength:
          (json['previousSendingChainLength'] as num?)?.toInt() ?? 0,
      pendingSendDhRatchet: json['pendingSendDhRatchet'] == true,
      skippedMessageKeys: json['skippedMessageKeys'] is Map
          ? (json['skippedMessageKeys'] as Map).map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            )
          : const <String, String>{},
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'remotePublicId': remotePublicId,
      'remoteDeviceId': remoteDeviceId,
      'rootKeyB64': rootKeyB64,
      'selfRatchetPrivateKeyB64': selfRatchetPrivateKeyB64,
      'selfRatchetPublicKeyB64': selfRatchetPublicKeyB64,
      'remoteRatchetPublicKeyB64': remoteRatchetPublicKeyB64,
      'sendChainKeyB64': sendChainKeyB64,
      'recvChainKeyB64': recvChainKeyB64,
      'sendChainMessageNo': sendChainMessageNo,
      'recvChainMessageNo': recvChainMessageNo,
      'previousSendingChainLength': previousSendingChainLength,
      'pendingSendDhRatchet': pendingSendDhRatchet,
      'skippedMessageKeys': skippedMessageKeys,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}
