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

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      var profile = await _settings.ensureProfile();

      if (profile.registered && profile.firstName.trim().isNotEmpty) {
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

  Future<void> _backgroundSync() async {
    final profile = _profile;
    if (!mounted || profile == null) return;
    if (!profile.registered || profile.firstName.trim().isEmpty) return;
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

  Future<void> _completeRegistration({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    var profile = await _settings.completeRegistration(
      firstName: firstName,
      lastName: lastName,
      phone: phone,
    );

    profile = await _apiFor(profile).registerUser(profile);
    await _settings.saveProfile(profile);
    await _reload();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Регистрация завершена и отправлена на сервер')),
    );
  }

  Future<void> _saveProfile(UserProfile updated) async {
    await _settings.saveProfile(updated);

    final synced = await _apiFor(updated).registerUser(updated);
    await _settings.saveProfile(synced);
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

    if (!profile.registered || profile.firstName.trim().isEmpty) {
      return OnboardingScreen(
        profile: profile,
        onComplete: _completeRegistration,
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