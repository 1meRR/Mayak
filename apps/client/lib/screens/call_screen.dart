import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../controllers/call_controller.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.controller,
  });

  final CallController controller;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final TextEditingController _chatController = TextEditingController();

  bool _showChat = false;
  bool _swapFeeds = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _chatController.dispose();
    _closeCallIfNeeded();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _closeCallIfNeeded() async {
    if (_ended) return;
    _ended = true;
    await widget.controller.shutdown();
    widget.controller.dispose();
  }

  Future<bool> _onWillPop() async {
    await _closeCallIfNeeded();
    return true;
  }

  void _toggleSwap() {
    setState(() {
      _swapFeeds = !_swapFeeds;
    });
  }

  void _toggleChat() {
    setState(() {
      _showChat = !_showChat;
    });
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _chatController.clear();
    await widget.controller.sendChatMessage(text);
  }

  Widget _buildVideoView({
    required RTCVideoRenderer renderer,
    required bool mirror,
    required bool fullScreen,
  }) {
    final hasStream = renderer.srcObject != null;

    if (!hasStream) {
      return Container(
        color: const Color(0xFF111827),
        child: Center(
          child: Text(
            'Ожидаем видео...',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }

    return RTCVideoView(
      renderer,
      mirror: mirror,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    final RTCVideoRenderer mainRenderer =
        _swapFeeds ? controller.localRenderer : controller.remoteRenderer;
    final bool mainMirror = _swapFeeds;

    final RTCVideoRenderer pipRenderer =
        _swapFeeds ? controller.remoteRenderer : controller.localRenderer;
    final bool pipMirror = !_swapFeeds;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleSwap,
                child: _buildVideoView(
                  renderer: mainRenderer,
                  mirror: mainMirror,
                  fullScreen: true,
                ),
              ),
            ),
            Positioned(
              top: 54,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.34),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              controller.remoteDisplayName ?? 'Звонок',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              controller.connectionText,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: IconButton(
                        onPressed: _toggleChat,
                        icon: Icon(
                          _showChat
                              ? Icons.chat_bubble_rounded
                              : Icons.chat_bubble_outline_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 16,
              top: 120,
              child: GestureDetector(
                onTap: _toggleSwap,
                child: Container(
                  width: 120,
                  height: 180,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 20,
                        color: Colors.black.withValues(alpha: 0.24),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildVideoView(
                    renderer: pipRenderer,
                    mirror: pipMirror,
                    fullScreen: false,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 28,
              child: SafeArea(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundActionButton(
                      icon: controller.isMicEnabled
                          ? Icons.mic_rounded
                          : Icons.mic_off_rounded,
                      onTap: controller.toggleMicrophone,
                    ),
                    const SizedBox(width: 14),
                    _RoundActionButton(
                      icon: controller.isCameraEnabled
                          ? Icons.videocam_rounded
                          : Icons.videocam_off_rounded,
                      onTap: controller.toggleCamera,
                    ),
                    const SizedBox(width: 14),
                    _RoundActionButton(
                      icon: Icons.cameraswitch_rounded,
                      onTap: controller.switchCamera,
                    ),
                    const SizedBox(width: 14),
                    _RoundActionButton(
                      icon: Icons.call_end_rounded,
                      backgroundColor: Colors.redAccent,
                      onTap: () async {
                        await _closeCallIfNeeded();
                        if (mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: _showChat ? 0 : -360,
              child: SafeArea(
                top: false,
                child: Container(
                  height: 340,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1220),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 42,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Чат звонка',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _toggleChat,
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          itemCount: controller.chatItems.length,
                          itemBuilder: (context, index) {
                            final item = controller.chatItems[index];
                            return Align(
                              alignment: item.isLocal
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(12),
                                constraints:
                                    const BoxConstraints(maxWidth: 280),
                                decoration: BoxDecoration(
                                  color: item.isLocal
                                      ? const Color(0xFF4466FF)
                                      : const Color(0xFF1A2333),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.displayName,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      item.text,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _chatController,
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: 'Сообщение во время звонка',
                                  hintStyle:
                                      const TextStyle(color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white.withValues(alpha: 0.06),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(18),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                                onSubmitted: (_) => _sendChat(),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: _sendChat,
                              child: const Icon(Icons.send_rounded),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.onTap,
    this.backgroundColor,
  });

  final IconData icon;
  final Future<void> Function() onTap;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor ?? Colors.black.withValues(alpha: 0.34),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => onTap(),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Icon(
            icon,
            color: Colors.white,
            size: 24,
          ),
        ),
      ),
    );
  }
}