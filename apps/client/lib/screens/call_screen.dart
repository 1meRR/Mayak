import 'package:flutter/material.dart';

import '../controllers/call_controller.dart';
import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/device_socket_service.dart';
import '../widgets/participant_tile.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.profile,
    required this.friend,
    required this.invite,
    required this.api,
    required this.socket,
    required this.isCaller,
  });

  final UserProfile profile;
  final FriendUser friend;
  final CallInviteView invite;
  final ApiService api;
  final DeviceSocketService socket;
  final bool isCaller;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallController _controller;
  bool _joining = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = CallController(
      profile: widget.profile,
      friend: widget.friend,
      invite: widget.invite,
      api: widget.api,
      socket: widget.socket,
      isCaller: widget.isCaller,
    )..addListener(_onControllerChanged);
    _join();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.leave();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _join() async {
    try {
      await _controller.join();
      if (!mounted) {
        return;
      }
      setState(() {
        _joining = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _joining = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _hangup() async {
    await _controller.leave();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.friend.displayName),
            Text(
              _controller.connectionText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ParticipantTile(
                  renderer: _controller.remoteRenderer,
                  displayName: widget.friend.displayName,
                  isLocal: false,
                ),
              ),
            ),
            SizedBox(
              height: 164,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: ParticipantTile(
                  renderer: _controller.localRenderer,
                  displayName: widget.profile.displayName,
                  isLocal: true,
                  isCameraEnabled: _controller.isCameraEnabled,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.redAccent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_joining)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: CircularProgressIndicator(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filledTonal(
                    onPressed: _controller.toggleMicrophone,
                    icon: Icon(
                      _controller.isMicEnabled
                          ? Icons.mic_rounded
                          : Icons.mic_off_rounded,
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: _controller.toggleCamera,
                    icon: Icon(
                      _controller.isCameraEnabled
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: _controller.switchCamera,
                    icon: const Icon(Icons.cameraswitch_rounded),
                  ),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _hangup,
                    icon: const Icon(Icons.call_end_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
