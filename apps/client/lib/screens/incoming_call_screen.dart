import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/device_socket_service.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.profile,
    required this.friend,
    required this.invite,
    required this.api,
    required this.socket,
  });

  final UserProfile profile;
  final FriendUser friend;
  final CallInviteView invite;
  final ApiService api;
  final DeviceSocketService socket;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final invite = await widget.api.respondCallInvite(
        inviteId: widget.invite.inviteId,
        actorPublicId: widget.profile.publicId,
        actorDeviceId: widget.profile.deviceId,
        sessionToken: widget.profile.sessionToken,
        action: 'accept',
      );

      if (!mounted) {
        return;
      }

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            profile: widget.profile,
            friend: widget.friend,
            invite: invite,
            api: widget.api,
            socket: widget.socket,
            isCaller: false,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _reject() async {
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await widget.api.respondCallInvite(
        inviteId: widget.invite.inviteId,
        actorPublicId: widget.profile.publicId,
        actorDeviceId: widget.profile.deviceId,
        sessionToken: widget.profile.sessionToken,
        action: 'reject',
      );

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 44,
                  child: Text(
                    widget.friend.displayName.isEmpty
                        ? '?'
                        : widget.friend.displayName.characters.first.toUpperCase(),
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Входящий звонок',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.friend.displayName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Комната: ${widget.invite.roomId}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white54,
                  ),
                ),
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
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _accept,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.call_rounded),
                      label: const Text('Принять'),
                    ),
                    const SizedBox(width: 14),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _reject,
                      icon: const Icon(Icons.call_end_rounded),
                      label: const Text('Отклонить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}