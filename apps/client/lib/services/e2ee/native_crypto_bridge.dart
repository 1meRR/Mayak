@'
import 'dart:async';

import 'package:flutter/services.dart';

import '../../models/app_models.dart';
import 'crypto_bridge.dart';
import 'crypto_models.dart';
import 'mailbox_models.dart';

class NativeCryptoBridge implements CryptoBridge {
  NativeCryptoBridge({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('mayak.crypto_bridge');

  final MethodChannel _channel;

  static const _backendName = 'native_method_channel';

  @override
  Future<CryptoBridgeStatus> getStatus() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getStatus');
      if (raw is Map) {
        final map =
            raw.map((key, value) => MapEntry(key.toString(), value));
        return CryptoBridgeStatus(
          available: map['available'] == true,
          backend: map['backend']?.toString() ?? _backendName,
          reason: map['reason']?.toString(),
        );
      }

      return const CryptoBridgeStatus(
        available: false,
        backend: _backendName,
        reason: 'crypto bridge returned invalid status payload',
      );
    } on MissingPluginException {
      return const CryptoBridgeStatus(
        available: false,
        backend: _backendName,
        reason: 'native crypto bridge plugin is not installed',
      );
    } catch (e) {
      return CryptoBridgeStatus(
        available: false,
        backend: _backendName,
        reason: e.toString(),
      );
    }
  }

  @override
  Future<CryptoDeviceKeyPackage> ensureLocalDeviceIdentity(
    UserProfile profile,
  ) async {
    final raw = await _invokeRequiredMap(
      'ensureLocalDeviceIdentity',
      <String, dynamic>{
        'publicId': profile.publicId,
        'deviceId': profile.deviceId,
      },
    );

    return CryptoDeviceKeyPackage.fromJson(raw);
  }

  @override
  Future<List<CryptoOutgoingEnvelopeDraft>> encryptTextMessage({
    required UserProfile senderProfile,
    required String conversationId,
    required String plaintext,
    required String clientMessageId,
    required List<CryptoRemotePrekeyBundle> recipientBundles,
  }) async {
    final raw = await _invokeRequiredList(
      'encryptTextMessage',
      <String, dynamic>{
        'senderPublicId': senderProfile.publicId,
        'senderDeviceId': senderProfile.deviceId,
        'conversationId': conversationId,
        'plaintext': plaintext,
        'clientMessageId': clientMessageId,
        'recipientBundles': recipientBundles.map((e) => e.toJson()).toList(),
      },
    );

    return raw
        .whereType<Map>()
        .map(
          (item) => CryptoOutgoingEnvelopeDraft.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  @override
  Future<CryptoDecryptedEnvelope?> decryptEnvelope({
    required UserProfile localProfile,
    required StoredEnvelopeView envelope,
  }) async {
    final raw = await _invokeNullableMap(
      'decryptEnvelope',
      <String, dynamic>{
        'localPublicId': localProfile.publicId,
        'localDeviceId': localProfile.deviceId,
        'envelope': <String, dynamic>{
          'envelopeId': envelope.envelopeId,
          'conversationId': envelope.conversationId,
          'senderPublicId': envelope.senderPublicId,
          'senderDeviceId': envelope.senderDeviceId,
          'recipientPublicId': envelope.recipientPublicId,
          'recipientDeviceId': envelope.recipientDeviceId,
          'messageKind': envelope.messageKind,
          'protocol': envelope.protocol,
          'headerB64': envelope.headerB64,
          'ciphertextB64': envelope.ciphertextB64,
          'metadata': envelope.metadata,
          'createdAt': envelope.createdAt,
          'serverSeq': envelope.serverSeq,
        },
      },
    );

    if (raw == null) {
      return null;
    }

    return CryptoDecryptedEnvelope.fromJson(raw);
  }

  Future<Map<String, dynamic>> _invokeRequiredMap(
    String method,
    Map<String, dynamic> args,
  ) async {
    final raw = await _invokeNullableMap(method, args);
    if (raw == null) {
      throw CryptoBridgeUnavailableException(
        'crypto bridge method $method returned null',
      );
    }
    return raw;
  }

  Future<List<dynamic>> _invokeRequiredList(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(method, args);
      if (raw is List) {
        return raw;
      }
      throw CryptoBridgeUnavailableException(
        'crypto bridge method $method returned invalid list payload',
      );
    } on MissingPluginException {
      throw CryptoBridgeUnavailableException(
        'native crypto bridge plugin is not installed',
      );
    } on PlatformException catch (e) {
      throw CryptoBridgeUnavailableException(
        'crypto bridge platform error [$method]: ${e.message ?? e.code}',
      );
    }
  }

  Future<Map<String, dynamic>?> _invokeNullableMap(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>(method, args);
      if (raw == null) {
        return null;
      }
      if (raw is Map<String, dynamic>) {
        return raw;
      }
      if (raw is Map) {
        return raw.map((key, value) => MapEntry(key.toString(), value));
      }
      throw CryptoBridgeUnavailableException(
        'crypto bridge method $method returned invalid map payload',
      );
    } on MissingPluginException {
      throw CryptoBridgeUnavailableException(
        'native crypto bridge plugin is not installed',
      );
    } on PlatformException catch (e) {
      throw CryptoBridgeUnavailableException(
        'crypto bridge platform error [$method]: ${e.message ?? e.code}',
      );
    }
  }
}
'@ | Set-Content -Path "E:\VSCODE\decentra_call_messenger\apps\client\lib\services\e2ee\native_crypto_bridge.dart" -Encoding UTF8