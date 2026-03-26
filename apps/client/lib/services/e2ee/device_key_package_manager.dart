import '../../models/app_models.dart';
import 'mailbox_models.dart';
import 'mailbox_service.dart';
import 'secure_device_storage.dart';

class DeviceKeyPackageManager {
  DeviceKeyPackageManager({
    required this.mailboxService,
    required this.secureStorage,
  });

  final MailboxService mailboxService;
  final SecureDeviceStorage secureStorage;

  static const _devicePackageName = 'device_key_package_v1';

  Future<DeviceKeyPackagePayload?> loadLocalPackage(UserProfile profile) async {
    final raw = await secureStorage.readJson(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      name: _devicePackageName,
    );
    if (raw == null) {
      return null;
    }

    final prekeys = raw['oneTimePrekeys'];
    return DeviceKeyPackagePayload(
      deviceId: raw['deviceId']?.toString() ?? profile.deviceId,
      identityKeyAlg:
          raw['identityKeyAlg']?.toString() ?? 'x25519+ed25519',
      identityKeyB64: raw['identityKeyB64']?.toString() ?? '',
      signedPrekeyB64: raw['signedPrekeyB64']?.toString() ?? '',
      signedPrekeySignatureB64:
          raw['signedPrekeySignatureB64']?.toString() ?? '',
      signedPrekeyKeyId: (raw['signedPrekeyKeyId'] as num?)?.toInt() ?? 1,
      oneTimePrekeys: prekeys is List
          ? prekeys.map((e) => e.toString()).toList()
          : const <String>[],
    );
  }

  Future<void> saveLocalPackage({
    required UserProfile profile,
    required DeviceKeyPackagePayload payload,
  }) async {
    await secureStorage.writeJson(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      name: _devicePackageName,
      value: payload.toJson(),
    );
  }

  Future<DeviceKeyPackagePayload> ensureLocalStubPackage(
    UserProfile profile,
  ) async {
    final existing = await loadLocalPackage(profile);
    if (existing != null) {
      return existing;
    }

    final stub = DeviceKeyPackagePayload(
      deviceId: profile.deviceId.trim().toUpperCase(),
      identityKeyAlg: 'x25519+ed25519',
      identityKeyB64: _fakeB64('${profile.publicId}:${profile.deviceId}:identity'),
      signedPrekeyB64:
          _fakeB64('${profile.publicId}:${profile.deviceId}:signed-prekey'),
      signedPrekeySignatureB64:
          _fakeB64('${profile.publicId}:${profile.deviceId}:signature'),
      signedPrekeyKeyId: 1,
      oneTimePrekeys: List<String>.generate(
        10,
        (index) => _fakeB64(
          '${profile.publicId}:${profile.deviceId}:otk:${index + 1}',
        ),
      ),
    );

    await saveLocalPackage(profile: profile, payload: stub);
    return stub;
  }

  Future<ClaimedPrekeyBundle> publishLocalPackage(UserProfile profile) async {
    final payload = await ensureLocalStubPackage(profile);
    return mailboxService.uploadDeviceKeyPackage(
      profile: profile,
      payload: payload,
    );
  }

  String _fakeB64(String input) {
    final bytes = input.codeUnits;
    return Uri.encodeComponent(String.fromCharCodes(bytes))
        .codeUnits
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}