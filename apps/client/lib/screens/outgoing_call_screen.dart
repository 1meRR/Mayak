import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/call_controller.dart';
import '../models/app_models.dart';
import '../services/api_service.dart';
import 'call_screen.dart';

class OutgoingCallScreen extends StatefulWidget {
  const OutgoingCallScreen({
    super.key,
    required this.profile,
    required this.friend,
    required this.invite,
    required this.api,
  });

  final UserProfile profile;
  final FriendUser friend;
  final CallInviteView invite;
  final ApiService api;

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  Timer? _pollTimer;

  late final CallController _controller = CallController(
    roomId: widget.invite.roomId,
    displayName: widget.profile.displayName,
    serverUrl: widget.profile.serverUrl,
    isCaller: true,
  );

  bool _startingController = false;
  bool _controllerStarted = false;
  bool _openingCallScreen = false;
  bool _transferredToCallScreen = false;

  String _status = 'pending';
  String? _statusText;

  @override
  void initState() {
    super.initState();
    _startCallerController();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();

    if (!_transferredToCallScreen) {
      unawaited(_disposeControllerSilently());
    }

    super.dispose();
  }

  Future<void> _disposeControllerSilently() async {
    try {
      await _controller.shutdown(notifyServer: true);
    } catch (_) {}
    try {
      _controller.dispose();
    } catch (_) {}
  }

  Future<void> _startCallerController() async {
    if (_startingController || _controllerStarted) return;

    _startingController = true;

    try {
      await _controller.join();
      _controllerStarted = true;

      if (!mounted) return;
      setState(() {
        _statusText = 'Ожидаем, пока ${widget.friend.displayName} примет звонок...';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Не удалось подготовить звонок: $error';
      });
    } finally {
      _startingController = false;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    try {
      final invite = await widget.api.getCallInvite(widget.invite.id);

      if (!mounted) return;

      setState(() {
        _status = invite.status;
      });

      if (invite.status == 'accepted' && !_openingCallScreen) {
        await _openAcceptedCall();
      } else if (invite.status == 'rejected') {
        setState(() {
          _statusText = 'Пользователь отклонил звонок';
        });
      } else if (invite.status == 'expired') {
        setState(() {
          _statusText = 'Время ожидания ответа истекло';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Ошибка проверки статуса звонка: $error';
      });
    }
  }

  Future<void> _openAcceptedCall() async {
    if (_openingCallScreen) return;

    _openingCallScreen = true;

    try {
      if (!_controllerStarted) {
        await _startCallerController();
      }

      if (!_controllerStarted) {
        if (!mounted) return;
        setState(() {
          _statusText = 'Не удалось подготовить соединение';
        });
        return;
      }

      _pollTimer?.cancel();
      _transferredToCallScreen = true;

      if (!mounted) return;

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CallScreen(controller: _controller),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Не удалось открыть звонок: $error';
      });
    } finally {
      _openingCallScreen = false;
    }
  }

  String _buildStatusText() {
    if (_statusText != null) {
      return _statusText!;
    }

    switch (_status) {
      case 'pending':
        return 'Ожидаем, пока ${widget.friend.displayName} примет звонок...';
      case 'accepted':
        return 'Звонок принят. Подключаемся...';
      case 'rejected':
        return 'Звонок отклонён';
      case 'expired':
        return 'Время ожидания истекло';
      default:
        return 'Статус: $_status';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        title: const Text('Исходящий звонок'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.ring_volume_rounded,
                size: 72,
                color: Colors.white,
              ),
              const SizedBox(height: 24),
              Text(
                widget.friend.displayName,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontSize: 34,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                widget.friend.publicId,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              Text(
                _buildStatusText(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 36),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Отменить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}