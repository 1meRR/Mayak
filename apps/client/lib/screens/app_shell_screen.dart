import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/call_controller.dart';
import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/settings_repository.dart';
import 'add_friend_screen.dart';
import 'call_screen.dart';
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

  bool _loading = true;
  bool _syncing = false;
  String? _errorMessage;
  int _currentIndex = 0;

  UserProfile? _profile;
  FriendsBundle? _bundle;
  List<CallInviteView> _incomingCalls = const [];

  Timer? _pollTimer;
  String? _activeIncomingInviteId;

  @override
  void initState() {
    super.initState();
    _reload();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _backgroundSync(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  ApiService _apiFor(UserProfile profile) => ApiService(profile.serverUrl);
  ApiService _apiForServer(String serverUrl) => ApiService(serverUrl);

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      var profile = await _settings.ensureProfile();

      if (_isAuthenticated(profile)) {
        final api = _apiFor(profile);
        profile = await api.registerUser(profile);
        await _settings.saveProfile(profile);
        await api.heartbeat(
          publicId: profile.publicId,
          deviceId: profile.deviceId,
        );
        final bundle = await api.fetchFriends(profile.publicId);
        final incomingCalls = await api.fetchIncomingCalls(profile.publicId);

        if (!mounted) return;

        setState(() {
          _profile = profile;
          _bundle = bundle;
          _incomingCalls = incomingCalls;
          _loading = false;
        });

        await _maybeShowIncomingCall();
      } else {
        if (!mounted) return;
        setState(() {
          _profile = profile;
          _bundle = FriendsBundle.empty(profile.publicId);
          _incomingCalls = const [];
          _loading = false;
        });
      }
    } catch (error, stackTrace) {
      debugPrint('AppShell reload error: $error');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = error.toString();
      });
    }
  }

  bool _isAuthenticated(UserProfile profile) {
    return profile.registered &&
        profile.publicId.trim().isNotEmpty &&
        profile.firstName.trim().isNotEmpty;
  }

  Future<void> _backgroundSync() async {
    final profile = _profile;
    if (!mounted || profile == null) return;
    if (!_isAuthenticated(profile)) return;
    if (_syncing) return;

    _syncing = true;

    try {
      final api = _apiFor(profile);
      await api.heartbeat(
        publicId: profile.publicId,
        deviceId: profile.deviceId,
      );
      final bundle = await api.fetchFriends(profile.publicId);
      final incomingCalls = await api.fetchIncomingCalls(profile.publicId);

      if (!mounted) return;

      setState(() {
        _bundle = bundle;
        _incomingCalls = incomingCalls;
      });

      await _maybeShowIncomingCall();
    } catch (error, stackTrace) {
      debugPrint('Background sync error: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _syncing = false;
    }
  }

  Future<AuthRegisterResult> _register({
    required String firstName,
    required String lastName,
    required String phone,
    required String password,
    required String serverUrl,
  }) async {
    final localProfile = await _settings.ensureProfile();
    final api = _apiForServer(serverUrl);

    final result = await api.registerWithPhone(
      deviceId: localProfile.deviceId,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      password: password,
      about: localProfile.about,
    );

    final savedProfile = result.profile.copyWith(
      deviceId: localProfile.deviceId,
      serverUrl: serverUrl,
      createdAt: localProfile.createdAt,
      about: localProfile.about,
      registered: true,
    );

    await _settings.saveProfile(savedProfile);
    await _reload();

    if (!mounted) return AuthRegisterResult(profile: savedProfile, recoveryCodes: result.recoveryCodes);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Аккаунт создан, контакты теперь привязаны к аккаунту')),
    );

    return AuthRegisterResult(
      profile: savedProfile,
      recoveryCodes: result.recoveryCodes,
    );
  }

  Future<void> _login({
    required String phone,
    required String password,
    required String serverUrl,
  }) async {
    final localProfile = await _settings.ensureProfile();
    final api = _apiForServer(serverUrl);

    final profile = await api.loginWithPhone(
      deviceId: localProfile.deviceId,
      phone: phone,
      password: password,
    );

    await _settings.saveProfile(
      profile.copyWith(
        deviceId: localProfile.deviceId,
        serverUrl: serverUrl,
        createdAt: localProfile.createdAt,
        registered: true,
      ),
    );

    await _reload();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Вход выполнен, профиль восстановлен')),
    );
  }

  Future<void> _resetPassword({
    required String phone,
    required String recoveryCode,
    required String newPassword,
    required String serverUrl,
  }) async {
    final api = _apiForServer(serverUrl);
    await api.resetPasswordWithCode(
      phone: phone,
      recoveryCode: recoveryCode,
      newPassword: newPassword,
    );
  }

  Future<void> _logout() async {
    await _settings.clearSession();
    await _reload();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Локальная сессия удалена')),
    );
  }

  Future<void> _saveProfile(UserProfile updated) async {
    await _settings.saveProfile(updated);

    final synced = await _apiFor(updated).registerUser(updated);
    await _settings.saveProfile(synced.copyWith(serverUrl: updated.serverUrl));
    await _reload();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Профиль сохранён и синхронизирован')),
    );
  }

  Future<void> _openChat(FriendUser friend) async {
    final profile = _profile;
    if (profile == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          profile: profile,
          friend: friend,
        ),
      ),
    );

    await _reload();
  }

  Future<void> _onFriendRequestSent() async {
    await _reload();

    if (!mounted) return;
    setState(() {
      _currentIndex = 0;
    });
  }

  Future<void> _acceptRequest(FriendRequestView request) async {
    final profile = _profile;
    if (profile == null) return;

    await _apiFor(profile).respondFriendRequest(
      requestId: request.id,
      actorPublicId: profile.publicId,
      action: 'accept',
    );

    await _reload();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Заявка от ${request.fromDisplayName} принята')),
    );
  }

  Future<void> _rejectRequest(FriendRequestView request) async {
    final profile = _profile;
    if (profile == null) return;

    await _apiFor(profile).respondFriendRequest(
      requestId: request.id,
      actorPublicId: profile.publicId,
      action: 'reject',
    );

    await _reload();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Заявка от ${request.fromDisplayName} отклонена')),
    );
  }

  Future<void> _maybeShowIncomingCall() async {
    final profile = _profile;
    if (!mounted || profile == null) return;
    if (_activeIncomingInviteId != null) return;

    final pending = _incomingCalls.where((item) => item.status == 'pending').toList();
    if (pending.isEmpty) return;

    final invite = pending.first;
    _activeIncomingInviteId = invite.id;

    final action = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => IncomingCallScreen(invite: invite),
      ),
    );

    if (!mounted) return;

    try {
      if (action == 'accept') {
        await _apiFor(profile).respondCallInvite(
          inviteId: invite.id,
          actorPublicId: profile.publicId,
          action: 'accept',
        );

        await _joinAcceptedCall(profile, invite);
      } else {
        await _apiFor(profile).respondCallInvite(
          inviteId: invite.id,
          actorPublicId: profile.publicId,
          action: 'reject',
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка обработки звонка: $error')),
      );
    } finally {
      _activeIncomingInviteId = null;
      await _backgroundSync();
    }
  }

  Future<void> _joinAcceptedCall(UserProfile profile, CallInviteView invite) async {
    final controller = CallController(
      roomId: invite.roomId,
      displayName: profile.displayName,
      serverUrl: profile.serverUrl,
      isCaller: false,
    );

    try {
      await controller.join();

      if (!mounted) {
        await controller.shutdown(notifyServer: false);
        controller.dispose();
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(controller: controller),
        ),
      );
    } catch (error) {
      await controller.shutdown(notifyServer: false);
      controller.dispose();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось подключиться к звонку: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Маяк')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ошибка загрузки',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                SelectableText(_errorMessage!),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _reload,
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final profile = _profile;
    if (profile == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: Text('Профиль не инициализирован')),
        ),
      );
    }

    if (!_isAuthenticated(profile)) {
      return OnboardingScreen(
        profile: profile,
        onRegister: _register,
        onLogin: _login,
        onResetPassword: _resetPassword,
      );
    }

    final bundle = _bundle ?? FriendsBundle.empty(profile.publicId);

    final pages = [
      FriendsScreen(
        profile: profile,
        friends: bundle.friends,
        incomingRequests: bundle.incomingRequests,
        outgoingRequests: bundle.outgoingRequests,
        onOpenChat: _openChat,
        onAcceptRequest: _acceptRequest,
        onRejectRequest: _rejectRequest,
        onRefresh: _reload,
      ),
      AddFriendScreen(
        profile: profile,
        api: _apiFor(profile),
        onFriendRequestSent: _onFriendRequestSent,
      ),
      ProfileScreen(
        profile: profile,
        onSave: _saveProfile,
        onLogout: _logout,
      ),
    ];

    return Scaffold(
      body: pages[_currentIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_alt_outlined),
            selectedIcon: Icon(Icons.people_alt_rounded),
            label: 'Друзья',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_add_alt_1_outlined),
            selectedIcon: Icon(Icons.person_add_alt_1_rounded),
            label: 'Добавить',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle_rounded),
            label: 'Профиль',
          ),
        ],
      ),
    );
  }
}
