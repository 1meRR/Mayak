import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class IdentityVerificationService {
  final Sha256 _sha256 = Sha256();

  Future<String> buildSafetyNumber({
    required String localPublicId,
    required String localDeviceId,
    required String localIdentityKeyB64,
    required String remotePublicId,
    required String remoteDeviceId,
    required String remoteIdentityKeyB64,
  }) async {
    final participants = [
      '${localPublicId.trim().toUpperCase()}:${localDeviceId.trim().toUpperCase()}:${localIdentityKeyB64.trim()}',
      '${remotePublicId.trim().toUpperCase()}:${remoteDeviceId.trim().toUpperCase()}:${remoteIdentityKeyB64.trim()}',
    ]..sort();

    final digest = await _sha256.hash(utf8.encode(participants.join('|')));
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final groups = <String>[];
    for (var i = 0; i < 60 && i < hex.length; i += 5) {
      groups.add(hex.substring(i, i + 5));
    }

    return groups.join(' ');
  }
}
