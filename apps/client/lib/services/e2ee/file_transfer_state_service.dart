import 'dart:convert';
import 'dart:typed_data';

import '../../models/app_models.dart';
import 'e2ee_file_service.dart';
import 'secure_device_storage.dart';

class FileTransferStateService {
  FileTransferStateService({
    required E2eeFileService fileService,
    SecureDeviceStorage? secureStorage,
  })  : _fileService = fileService,
        _secureStorage = secureStorage ?? SecureDeviceStorage();

  final E2eeFileService _fileService;
  final SecureDeviceStorage _secureStorage;

  static const _stateName = 'file_transfer_state_v1';

  Future<PreparedEncryptedFile> prepareAndPersistUpload({
    required UserProfile sender,
    required String fileName,
    required String mediaType,
    required Uint8List plaintext,
    required List<CryptoFileRecipientBundle> recipients,
  }) async {
    final prepared = await _fileService.encryptForRecipients(
      sender: sender,
      fileName: fileName,
      mediaType: mediaType,
      plaintext: plaintext,
      recipients: recipients,
    );

    await _saveState(
      profile: sender,
      transferId: prepared.fileId,
      state: {
        'fileId': prepared.fileId,
        'objectKey': prepared.objectKey,
        'status': 'prepared',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'ciphertextSize': prepared.ciphertext.length,
        'totalChunks': prepared.chunks.length,
      },
    );

    return prepared;
  }

  Future<void> registerAndMarkCompleted({
    required UserProfile sender,
    required PreparedEncryptedFile prepared,
  }) async {
    await _fileService.registerUpload(sender: sender, prepared: prepared);
    await _saveState(
      profile: sender,
      transferId: prepared.fileId,
      state: {
        'fileId': prepared.fileId,
        'status': 'registered',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      merge: true,
    );

    await _fileService.markUploaded(sender: sender, fileId: prepared.fileId);
    await _saveState(
      profile: sender,
      transferId: prepared.fileId,
      state: {
        'fileId': prepared.fileId,
        'status': 'completed',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      merge: true,
    );
  }

  Future<Map<String, dynamic>?> getTransferState({
    required UserProfile profile,
    required String transferId,
  }) {
    return _secureStorage.readJson(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      name: _stateStorageName(transferId),
    );
  }

  Future<void> markFailed({
    required UserProfile profile,
    required String transferId,
    required Object error,
  }) {
    return _saveState(
      profile: profile,
      transferId: transferId,
      state: {
        'status': 'failed',
        'error': error.toString(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      merge: true,
    );
  }

  Future<void> _saveState({
    required UserProfile profile,
    required String transferId,
    required Map<String, dynamic> state,
    bool merge = false,
  }) async {
    final name = _stateStorageName(transferId);
    final current = merge
        ? await _secureStorage.readJson(
            publicId: profile.publicId,
            deviceId: profile.deviceId,
            name: name,
          )
        : null;

    final next = {
      if (current != null) ...current,
      ...state,
    };

    await _secureStorage.writeJson(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      name: name,
      value: next,
    );
  }

  String _stateStorageName(String transferId) =>
      '$_stateName:${transferId.trim().toUpperCase()}';

  Future<String> exportStateJson({required UserProfile profile}) async {
    final all = await _secureStorage.readAllForDevice(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      prefix: _stateName,
    );
    return jsonEncode(all);
  }
}
