import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_service.dart';
import '../services/settings_repository.dart';
import '../widgets/glass_panel.dart';
import 'outgoing_call_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.profile,
    required this.friend,
  });

  final UserProfile profile;
  final FriendUser friend;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();

  late final String _chatId;
  late final ApiService _api;

  List<DirectMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  bool _creatingInvite = false;
  String? _error;

  Timer? _pollTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _chatId = SettingsRepository.buildDirectChatId(
      widget.profile.publicId,
      widget.friend.publicId,
    );
    _api = ApiService(widget.profile.serverUrl);

    _loadMessages();

    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _loadMessages(silent: true),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  List<DirectMessage> _mergeMessages(List<DirectMessage> items) {
    final map = <String, DirectMessage>{};

    for (final item in items) {
      map[item.id] = item;
    }

    final result = map.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return result;
  }

  Future<void> _loadMessages({bool silent = false}) async {
    if (_disposed) return;

    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final messages = await _api.fetchMessages(
        chatId: _chatId,
        myPublicId: widget.profile.publicId,
      );

      if (!mounted || _disposed) return;

      setState(() {
        _messages = _mergeMessages(messages);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || _disposed) return;

      if (!silent) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }

    setState(() {
      _sending = true;
    });

    try {
      final sent = await _api.sendMessage(
        fromPublicId: widget.profile.publicId,
        toPublicId: widget.friend.publicId,
        text: text,
        authorDisplayName: widget.profile.displayName,
      );

      if (!mounted || _disposed) return;

      _messageController.clear();
      setState(() {
        _messages = _mergeMessages([..._messages, sent]);
      });

      await _loadMessages(silent: true);
    } catch (error) {
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить сообщение: $error')),
      );
    } finally {
      if (mounted && !_disposed) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _startVideoCall() async {
    if (_creatingInvite) return;

    setState(() {
      _creatingInvite = true;
    });

    try {
      final invite = await _api.createCallInvite(
        callerPublicId: widget.profile.publicId,
        calleePublicId: widget.friend.publicId,
      );

      if (!mounted || _disposed) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(
            profile: widget.profile,
            friend: widget.friend,
            invite: invite,
            api: _api,
          ),
        ),
      );
    } catch (error) {
      if (!mounted || _disposed) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось начать звонок: $error')),
      );
    } finally {
      if (mounted && !_disposed) {
        setState(() {
          _creatingInvite = false;
        });
      }
    }
  }

  String _formatTime(DateTime dateTime) {
    final hh = dateTime.hour.toString().padLeft(2, '0');
    final mm = dateTime.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.friend.displayName),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: () => _loadMessages(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Видео-звонок',
            onPressed: _creatingInvite ? null : _startVideoCall,
            icon: _creatingInvite
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.videocam_rounded),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.9,
            colors: [
              Color(0xFF18233A),
              Color(0xFF0D1220),
              Color(0xFF070B14),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: GlassPanel(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'ID: ${widget.friend.publicId}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _creatingInvite ? null : _startVideoCall,
                        icon: const Icon(Icons.videocam_rounded),
                        label: const Text('Позвонить'),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Text(
                                'Ошибка загрузки сообщений:\n$_error',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          )
                        : _messages.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24),
                                  child: Text(
                                    'Диалог пока пуст. Напиши первое сообщение или позвони.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                reverse: true,
                                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                                itemCount: _messages.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final item =
                                      _messages[_messages.length - 1 - index];
                                  final bubbleColor = item.isMine
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.96)
                                      : const Color(0xFF1A2333);

                                  return Align(
                                    alignment: item.isMine
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxWidth: 320),
                                      child: Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: bubbleColor,
                                          borderRadius:
                                              BorderRadius.circular(18),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.authorDisplayName,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              item.text,
                                              style: theme.textTheme.bodyLarge
                                                  ?.copyWith(
                                                color: Colors.white,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              _formatTime(item.createdAt),
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                color: Colors.white
                                                    .withValues(alpha: 0.72),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        decoration: InputDecoration(
                          hintText: 'Сообщение для ${widget.friend.displayName}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendMessage,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Отправить'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}