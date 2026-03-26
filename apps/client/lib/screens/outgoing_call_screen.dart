import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/device_socket_service.dart';
import 'call_screen.dart';

class OutgoingCallScreen extends StatefulWidget {
  const OutgoingCallScreen({
    super.key,
    required this.profile,
    required this.friend,
    required this.api,
    required this.socket,
  });

  final UserProfile profile;
  final FriendUser friend;
  final ApiService api;
  final DeviceSocketService socket;

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  bool _loading = true;
  String? _error;
  CallInviteView? _invite;
  Timer? _pollTimer;
  bool _navigatedToCall = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final invite = await widget.api.createCallInvite(
        callerPublicId: widget.profile.publicId,
        callerDeviceId: widget.profile.deviceId,
        sessionToken: widget.profile.sessionToken,
        calleePublicId: widget.friend.publicId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _invite = invite;
        _loading = false;
      });

      _pollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _pollInviteState(),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _pollInviteState() async {
    final invite = _invite;
    if (invite == null || _navigatedToCall) {
      return;
    }

    try {
      final fresh = await widget.api.getCallInvite(invite.inviteId);
      if (!mounted) {
        return;
      }

      setState(() {
        _invite = fresh;
      });

      if (fresh.status == 'accepted') {
        _navigatedToCall = true;
        _pollTimer?.cancel();

        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => CallScreen(
              profile: widget.profile,
              friend: widget.friend,
              invite: fresh,
              api: widget.api,
              socket: widget.socket,
              isCaller: true,
            ),
          ),
        );
        return;
      }

      if (fresh.status == 'rejected' || fresh.status == 'expired') {
        _pollTimer?.cancel();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = _invite;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Исходящий звонок'),
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _loading
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 42,
                        child: Text(
                          widget.friend.displayName.isEmpty
                              ? '?'
                              : widget.friend.displayName.characters.first.toUpperCase(),
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.friend.displayName,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        invite == null
                            ? 'Создаём invite...'
                            : 'Ожидаем, пока собеседник примет звонок',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                      if (invite != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Статус: ${invite.status}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Invite: ${invite.inviteId}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white54,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Закрыть'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}