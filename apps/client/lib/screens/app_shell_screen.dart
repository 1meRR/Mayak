import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/device_socket_service.dart';
import '../services/e2ee/crypto_bridge.dart';
import '../services/e2ee/e2ee_file_service.dart';
import '../services/e2ee/e2ee_key_backup_service.dart';
import '../services/e2ee/e2ee_message_service.dart';
import '../services/e2ee/file_transfer_state_service.dart';
import '../services/e2ee/identity_verification_service.dart';
import '../services/e2ee/mailbox_service.dart';
import '../services/e2ee/native_crypto_bridge.dart';
import '../services/e2ee/software_crypto_bridge.dart';
import '../services/local_message_store.dart';
import '../services/settings_repository.dart';
import 'add_friend_screen.dart';
import 'chat_screen.dart';
import 'friends_screen.dart';
import 'incoming_call_screen.dart';
import 'onboarding_screen.dart';
import 'profile_screen.dart';

class AppShellScreen extends StatefulWidget {
  const AppShellScreen({super.key});

  @override
  State<AppShellScreen> createState() => _AppShellScreenState();
}

class _AppShellScreenState extends State<AppShellScreen> {
  final SettingsRepository _settings = SettingsRepository();
  final LocalMessageStore _messageStore = LocalMessageStore();
  final DeviceSocketService _deviceSocket = DeviceSocketService();

  bool _loading = true;
  bool _syncing = false;
  String? _errorMessage;
  int _currentIndex = 0;

  UserProfile? _profile;
  FriendsBundle? _bundle;
  ApiService? _api;
  MailboxService? _mailbox;
  E2eeMessageService? _e2ee;
  E2eeFileService? _fileService;
  FileTransferStateService? _fileTransfer;
  final E2eeKeyBackupService _keyBackupService = E2eeKeyBackupService();
  final IdentityVerificationService _identityVerificationService =
      IdentityVerificationService();

  Timer? _pollTimer;
  Timer? _incomingCallTimer;
  StreamSubscription<DeviceSignalMessage>? _deviceMessageSub;

  bool _presentingIncomingCall = false;
  final Set<String> _handledIncomingInviteIds = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _backgroundSync(force: false),
    );
    _incomingCallTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkIncomingCalls(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _incomingCallTimer?.cancel();
    _deviceMessageSub?.cancel();
    _deviceSocket.dispose();
    _messageStore.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final profile = await _settings.ensureProfile();
      final api = ApiService(profile.serverUrl);
      final mailbox = MailboxService(profile.serverUrl);
      final nativeBridge = NativeCryptoBridge();
      final nativeStatus = await nativeBridge.getStatus();
      final cryptoBridge =
          nativeStatus.available ? nativeBridge : SoftwareCryptoBridge();

      final e2ee = E2eeMessageService(
        mailboxService: mailbox,
        cryptoBridge: cryptoBridge,
      );
      final fileService = E2eeFileService(mailboxService: mailbox);
      final fileTransfer = FileTransferStateService(
        fileService: fileService,
        mailboxService: mailbox,
      );

      FriendsBundle? bundle;
      if (profile.registered && profile.publicId.trim().isNotEmpty) {
        bundle = await _safeFetchFriends(api, profile);
      }

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _api = api;
        _mailbox = mailbox;
        _e2ee = e2ee;
        _fileService = fileService;
        _fileTransfer = fileTransfer;
        _bundle = bundle;
        _loading = false;
      });

      await _ensureMailboxBootstrap();
      await _ensureRealtime();
      await _backgroundMailboxSync();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _ensureMailboxBootstrap() async {
    final profile = _profile;
    final e2ee = _e2ee;
    if (profile == null || e2ee == null) return;
    if (!profile.hasActiveSession) return;

    final published = await _settings.isDeviceKeyPackagePublished(
      profile,
      expectedVersion: 1,
    );
    if (published) return;

    try {
      await e2ee.ensurePublishedDeviceKeys(profile);
      await _settings.markDeviceKeyPackagePublished(profile, version: 1);
    } on CryptoBridgeUnavailableException catch (e) {
      debugPrint('Crypto bridge unavailable during bootstrap: $e');
    } catch (e) {
      debugPrint('Mailbox bootstrap failed: $e');
    }
  }

  Future<void> _ensureRealtime() async {
    final profile = _profile;
    if (profile == null || !profile.hasActiveSession) return;

    await _deviceMessageSub?.cancel();

    try {
      await _deviceSocket.connect(profile);
      _deviceMessageSub = _deviceSocket.messages.listen(_handleDeviceSignalMessage);
    } catch (e) {
      debugPrint('Device socket connect failed: $e');
    }
  }

  Future<void> _backgroundSync({required bool force}) async {
    final profile = _profile;
    final api = _api;
    if (profile == null || api == null) return;
    if (!profile.registered) return;
    if (_syncing && !force) return;

    _syncing = true;
    try {
      final nextBundle = await _safeFetchFriends(api, profile);

      if (!mounted) return;
      setState(() {
        _bundle = nextBundle;
      });

      await _backgroundMailboxSync();
    } catch (e) {
      debugPrint('Background sync failed: $e');
    } finally {
      _syncing = false;
    }
  }

  Future<FriendsBundle> _safeFetchFriends(
    ApiService api,
    UserProfile profile,
  ) async {
    try {
      return await api.fetchFriends(profile.publicId);
    } catch (e) {
      if (e.toString().contains('HTTP 404')) {
        debugPrint(
          'Friends API is unavailable on server ${profile.serverUrl}; using empty friend bundle fallback.',
        );
        return FriendsBundle.empty(profile.publicId);
      }
      rethrow;
    }
  }

  Future<void> _backgroundMailboxSync() async {
    final profile = _profile;
    final e2ee = _e2ee;
    final bundle = _bundle;
    if (profile == null || e2ee == null) return;
    if (!profile.hasActiveSession) return;

    try {
      final lastServerSeq = await _settings.getMailboxCursor(profile);
      final decrypted = await e2ee.fetchAndDecryptPending(
        profile: profile,
        afterServerSeq: lastServerSeq,
        limit: 100,
        ackRead: true,
      );

      int? maxSeq = lastServerSeq;

      for (final item in decrypted) {
        final senderPublicId = item.senderPublicId.trim().toUpperCase();

        if (senderPublicId == profile.publicId.trim().toUpperCase()) {
          if (maxSeq == null || item.serverSeq > maxSeq) {
            maxSeq = item.serverSeq;
          }
          continue;
        }

        final friend = bundle?.friends.cast<FriendUser?>().firstWhere(
              (candidate) =>
                  candidate?.publicId.trim().toUpperCase() == senderPublicId,
              orElse: () => null,
            );

        final message = DirectMessage(
          id: item.envelopeId.isEmpty
              ? 'remote_${item.createdAt}'
              : item.envelopeId,
          chatId: item.conversationId,
          authorPublicId: senderPublicId,
          authorDisplayName: friend?.displayName ?? senderPublicId,
          text: item.plaintext,
          createdAt: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
          isMine: false,
          status: 'delivered',
        );

        await _messageStore.upsertMessage(
          peerPublicId: senderPublicId,
          peerDeviceId: item.senderDeviceId,
          envelopeId: item.envelopeId.isEmpty ? null : item.envelopeId,
          deliveredAt: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
          acknowledgedAt: DateTime.now(),
          message: message,
        );

        if (maxSeq == null || item.serverSeq > maxSeq) {
          maxSeq = item.serverSeq;
        }
      }

      if (maxSeq != null) {
        await _settings.saveMailboxCursor(profile, maxSeq);
      }
    } on CryptoBridgeUnavailableException catch (e) {
      debugPrint('Crypto bridge unavailable during mailbox sync: $e');
    } catch (e) {
      debugPrint('Mailbox sync failed: $e');
    }
  }

  void _handleDeviceSignalMessage(DeviceSignalMessage message) {
    if (message.type == 'pending_envelope') {
      unawaited(_backgroundMailboxSync());
      return;
    }
  }

  Future<void> _checkIncomingCalls() async {
    if (_presentingIncomingCall) return;

    final profile = _profile;
    final api = _api;
    final bundle = _bundle;
    if (profile == null || api == null || bundle == null) return;
    if (!profile.hasActiveSession) return;

    try {
      final incoming = await api.fetchIncomingCalls(profile.publicId);
      if (incoming.isEmpty) return;

      final invite = incoming.firstWhere(
        (item) => !_handledIncomingInviteIds.contains(item.id),
        orElse: () => CallInviteView(
          inviteId: '',
          callerPublicId: '',
          callerDisplayName: '',
          calleePublicId: '',
          calleeDisplayName: '',
          roomId: '',
          status: 'pending',
          createdAt: DateTime.now(),
          respondedAt: null,
        ),
      );

      if (invite.id.isEmpty) return;

      final friend = bundle.friends.cast<FriendUser?>().firstWhere(
            (item) => item?.publicId == invite.callerPublicId,
            orElse: () => null,
          ) ??
          FriendUser(
            publicId: invite.callerPublicId,
            friendCode: '',
            displayName: invite.callerDisplayName,
            about: '',
            createdAt: DateTime.now(),
            isOnline: true,
            lastSeenAt: DateTime.now(),
          );

      _presentingIncomingCall = true;
      _handledIncomingInviteIds.add(invite.id);

      if (!mounted) {
        _presentingIncomingCall = false;
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => IncomingCallScreen(
            profile: profile,
            friend: friend,
            invite: invite,
            api: api,
            socket: _deviceSocket,
          ),
        ),
      );

      _presentingIncomingCall = false;
    } catch (e) {
      debugPrint('Incoming call check failed: $e');
    }
  }

  Future<AuthRegisterResult> _register({
    required String firstName,
    required String lastName,
    required String phone,
    required String password,
    required String serverUrl,
  }) async {
    final base = await _settings.ensureProfile();
    final serverProfile = base.copyWith(serverUrl: serverUrl.trim());
    final api = ApiService(serverProfile.serverUrl);

    final result = await api.registerWithPhone(
      deviceId: serverProfile.deviceId,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      password: password,
      about: 'На связи в Маяке',
    );

    await _settings.saveProfile(result.profile);
    await _settings.clearMailboxCursor(result.profile);
    await _settings.clearDeviceKeyPackageState(result.profile);
    await _reload();

    return result;
  }

  Future<void> _login({
    required String phone,
    required String password,
    required String serverUrl,
  }) async {
    final base = await _settings.ensureProfile();
    final nextProfile = base.copyWith(serverUrl: serverUrl.trim());
    final api = ApiService(nextProfile.serverUrl);

    final loggedIn = await api.loginWithPhone(
      deviceId: nextProfile.deviceId,
      phone: phone,
      password: password,
    );

    await _settings.saveProfile(loggedIn);
    await _settings.clearMailboxCursor(loggedIn);
    await _settings.clearDeviceKeyPackageState(loggedIn);
    await _reload();
  }

  Future<void> _resetPassword({
    required String phone,
    required String recoveryCode,
    required String newPassword,
    required String serverUrl,
  }) async {
    final api = ApiService(serverUrl.trim());
    await api.resetPasswordWithCode(
      phone: phone,
      recoveryCode: recoveryCode,
      newPassword: newPassword,
    );
  }

  Future<void> _logout() async {
    await _settings.clearSession();
    await _deviceMessageSub?.cancel();
    _deviceMessageSub = null;
    await _deviceSocket.dispose();
    await _reload();
  }

  Future<void> _acceptRequest(FriendRequestView request) async {
    final profile = _profile;
    final api = _api;
    if (profile == null || api == null) return;

    await api.respondFriendRequest(
      requestId: request.id,
      actorPublicId: profile.publicId,
      actorDeviceId: profile.deviceId,
      sessionToken: profile.sessionToken,
      action: 'accept',
    );

    await _backgroundSync(force: true);
  }

  Future<void> _rejectRequest(FriendRequestView request) async {
    final profile = _profile;
    final api = _api;
    if (profile == null || api == null) return;

    await api.respondFriendRequest(
      requestId: request.id,
      actorPublicId: profile.publicId,
      actorDeviceId: profile.deviceId,
      sessionToken: profile.sessionToken,
      action: 'reject',
    );

    await _backgroundSync(force: true);
  }

  Future<void> _openAddFriend() async {
    final profile = _profile;
    final api = _api;
    if (profile == null || api == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddFriendScreen(
          profile: profile,
          api: api,
          onFriendRequestSent: () => _backgroundSync(force: true),
        ),
      ),
    );

    await _backgroundSync(force: true);
  }

  Future<String> _createEncryptedKeyBackup(String passphrase) async {
    final profile = _profile;
    if (profile == null) {
      throw Exception('Профиль недоступен');
    }

    return _keyBackupService.createEncryptedBackup(
      profile: profile,
      recoveryPassphrase: passphrase,
    );
  }

  Future<void> _restoreEncryptedKeyBackup({
    required String passphrase,
    required String backupBlob,
  }) async {
    final profile = _profile;
    if (profile == null) {
      throw Exception('Профиль недоступен');
    }

    await _keyBackupService.restoreEncryptedBackup(
      profile: profile,
      recoveryPassphrase: passphrase,
      backupBlobB64: backupBlob,
    );
  }

  Future<String> _buildSafetyNumber(FriendUser friend) async {
    final profile = _profile;
    final mailbox = _mailbox;
    if (profile == null || mailbox == null) {
      throw Exception('Нет активной сессии');
    }

    final myClaim = await mailbox.claimPrekey(
      targetPublicId: profile.publicId,
      targetDeviceId: profile.deviceId,
    );

    final peerDevices = await mailbox.listDevicesRaw(friend.publicId);
    if (peerDevices.isEmpty) {
      throw Exception('У собеседника нет устройств');
    }

    final peerClaim = await mailbox.claimPrekey(
      targetPublicId: friend.publicId,
      targetDeviceId: peerDevices.first.deviceId,
    );

    return _identityVerificationService.buildSafetyNumber(
      localPublicId: profile.publicId,
      localDeviceId: profile.deviceId,
      localIdentityKeyB64: myClaim.identityKeyB64,
      remotePublicId: friend.publicId,
      remoteDeviceId: peerClaim.deviceId,
      remoteIdentityKeyB64: peerClaim.identityKeyB64,
    );
  }

  Future<void> _sendDemoEncryptedFile(FriendUser friend, String label) async {
    final profile = _profile;
    final mailbox = _mailbox;
    final transfer = _fileTransfer;

    if (profile == null || mailbox == null || transfer == null) {
      throw Exception('File service недоступен');
    }

    final devices = await mailbox.listDevicesRaw(friend.publicId);
    if (devices.isEmpty) {
      throw Exception('У получателя нет устройств');
    }

    final recipients = <CryptoFileRecipientBundle>[];
    for (final device in devices) {
      final claim = await mailbox.claimPrekey(
        targetPublicId: friend.publicId,
        targetDeviceId: device.deviceId,
      );
      recipients.add(
        CryptoFileRecipientBundle(
          publicId: claim.publicId,
          deviceId: claim.deviceId,
          signedPrekeyB64: claim.signedPrekeyB64,
        ),
      );
    }

    final bytes = Uint8List.fromList(
      utf8.encode('mayak_demo_file:${DateTime.now().toIso8601String()}:$label'),
    );

    final prepared = await transfer.prepareAndPersistUpload(
      sender: profile,
      fileName: 'demo_${DateTime.now().millisecondsSinceEpoch}.txt',
      mediaType: 'text/plain',
      plaintext: bytes,
      recipients: recipients,
    );

    await transfer.registerAndMarkCompleted(
      sender: profile,
      prepared: prepared,
    );
  }

  Future<void> _openChat(FriendUser friend) async {
    final profile = _profile;
    final e2ee = _e2ee;
    if (profile == null || e2ee == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          profile: profile,
          friend: friend,
          store: _messageStore,
          e2ee: e2ee,
          onSyncRequested: _backgroundMailboxSync,
          onSafetyNumberRequested: () => _buildSafetyNumber(friend),
          onSendFileRequested: (label) => _sendDemoEncryptedFile(friend, label),
        ),
      ),
    );

    await _backgroundSync(force: true);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _reload,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _profile;
    if (profile == null) {
      return const Center(child: Text('Профиль недоступен'));
    }

    if (!profile.registered) {
      return OnboardingScreen(
        profile: profile,
        onRegister: _register,
        onLogin: _login,
        onResetPassword: _resetPassword,
      );
    }

    final bundle = _bundle ?? FriendsBundle.empty(profile.publicId);

    switch (_currentIndex) {
      case 0:
        return FriendsScreen(
          profile: profile,
          friends: bundle.friends,
          incomingRequests: bundle.incomingRequests,
          outgoingRequests: bundle.outgoingRequests,
          onOpenChat: _openChat,
          onAcceptRequest: _acceptRequest,
          onRejectRequest: _rejectRequest,
          onRefresh: () => _backgroundSync(force: true),
        );
      case 1:
        return ProfileScreen(
          profile: profile,
          onSave: (updated) async {
            await _settings.saveProfile(updated);
            await _reload();
          },
          onLogout: _logout,
          onCreateKeyBackup: _createEncryptedKeyBackup,
          onRestoreKeyBackup: _restoreEncryptedKeyBackup,
        );
      default:
        return FriendsScreen(
          profile: profile,
          friends: bundle.friends,
          incomingRequests: bundle.incomingRequests,
          outgoingRequests: bundle.outgoingRequests,
          onOpenChat: _openChat,
          onAcceptRequest: _acceptRequest,
          onRejectRequest: _rejectRequest,
          onRefresh: () => _backgroundSync(force: true),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;

    return Scaffold(
      body: _buildBody(),
      bottomNavigationBar: profile == null || !profile.registered
          ? null
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
                if (!mounted) return;
                setState(() {
                  _currentIndex = index;
                });
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.people_alt_rounded),
                  label: 'Друзья',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_rounded),
                  label: 'Профиль',
                ),
              ],
            ),
      floatingActionButton:
          profile != null && profile.registered && _currentIndex == 0
              ? FloatingActionButton(
                  onPressed: _openAddFriend,
                  child: const Icon(Icons.person_add_alt_1_rounded),
                )
              : null,
    );
  }
}
