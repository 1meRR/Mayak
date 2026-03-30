import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../models/app_models.dart';
import '../services/e2ee/e2ee_message_service.dart';
import '../services/local_message_store.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.profile,
    required this.friend,
    required this.store,
    required this.e2ee,
    this.onSyncRequested,
    this.onSafetyNumberRequested,
    this.onSendFileRequested,
  });

  final UserProfile profile;
  final FriendUser friend;
  final LocalMessageStore store;
  final E2eeMessageService e2ee;
  final Future<void> Function()? onSyncRequested;
  final Future<String> Function()? onSafetyNumberRequested;
  final Future<void> Function({
    required Uint8List bytes,
    required String fileName,
    required String mediaType,
  })? onSendFileRequested;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Stream<List<DirectMessage>>? _messagesStream;

  bool _isSending = false;
  bool _isSendingFile = false;
  bool _isSyncing = false;
  bool _bridgeReady = false;
  String? _bridgeProblem;

  String get _chatId => _buildChatId(
        widget.profile.publicId,
        widget.friend.publicId,
      );

  @override
  void initState() {
    super.initState();
    _messagesStream = widget.store.watchMessages(chatId: _chatId);
    _initAsync();
  }

  static String _buildChatId(String id1, String id2) {
    final list = [
      id1.trim().toUpperCase(),
      id2.trim().toUpperCase(),
    ]..sort();
    return 'dm_${list.join('_')}';
  }

  Future<void> _initAsync() async {
    await _checkBridge();
    await _syncNow();
  }

  Future<void> _checkBridge() async {
    try {
      final status = await widget.e2ee.getBridgeStatus();
      if (!mounted) return;

      setState(() {
        _bridgeReady = status.available;
        _bridgeProblem = status.available
            ? null
            : (status.reason ?? 'native crypto bridge is unavailable');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bridgeReady = false;
        _bridgeProblem = e.toString();
      });
    }
  }

  Future<void> _syncNow() async {
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
    });

    try {
      if (widget.onSyncRequested != null) {
        await widget.onSyncRequested!.call();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка синхронизации: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }


  Future<void> _showSafetyNumber() async {
    if (widget.onSafetyNumberRequested == null) {
      return;
    }

    try {
      final safety = await widget.onSafetyNumberRequested!.call();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Safety number'),
          content: SelectableText(safety),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось получить safety number: $e')),
      );
    }
  }

  Future<void> _pickAndSendFile() async {
    if (_isSendingFile || widget.onSendFileRequested == null) {
      return;
    }

    setState(() => _isSendingFile = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        return;
      }

      final item = picked.files.first;
      Uint8List? bytes = item.bytes;
      final path = item.path;

      if (bytes == null && path != null && path.isNotEmpty) {
        bytes = await File(path).readAsBytes();
      }

      if (bytes == null || bytes.isEmpty) {
        throw Exception('Не удалось прочитать вложение');
      }

      final fileName = item.name.trim().isEmpty
          ? 'attachment_${DateTime.now().millisecondsSinceEpoch}'
          : item.name.trim();

      final mediaType = lookupMimeType(fileName) ?? 'application/octet-stream';

      await widget.onSendFileRequested!.call(
        bytes: bytes,
        fileName: fileName,
        mediaType: mediaType,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Вложение отправлено: $fileName')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отправки файла: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSendingFile = false);
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    if (!_bridgeReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _bridgeProblem ??
                'E2EE bridge недоступен. Нельзя отправлять plaintext через placeholder transport.',
          ),
        ),
      );
      return;
    }

    _textController.clear();
    setState(() {
      _isSending = true;
    });

    final optimistic = DirectMessage(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      chatId: _chatId,
      authorPublicId: widget.profile.publicId,
      authorDisplayName: widget.profile.displayName,
      text: text,
      createdAt: DateTime.now(),
      isMine: true,
      status: 'queued',
    );

    try {
      await widget.store.upsertMessage(
        peerPublicId: widget.friend.publicId,
        message: optimistic,
      );

      final stored = await widget.e2ee.sendEncryptedText(
        senderProfile: widget.profile,
        friend: widget.friend,
        plaintext: text,
        clientMessageId: optimistic.id,
      );

      if (stored.isEmpty) {
        throw Exception('Сервер не сохранил ни одного envelope');
      }

      final first = stored.first;

      await widget.store.updateMessageStatus(
        messageId: optimistic.id,
        status: 'sent',
        peerDeviceId: first.recipientDeviceId,
        envelopeId: first.envelopeId,
        deliveredAt: DateTime.now(),
      );

      await _syncNow();

      if (!mounted) return;
      _scrollToBottom();
    } catch (e) {
      await widget.store.updateMessageStatus(
        messageId: optimistic.id,
        status: 'failed',
        lastError: e.toString(),
        nextRetryAt: DateTime.now().add(const Duration(seconds: 30)),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка E2EE-отправки: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  String _formatTime(DateTime value) => DateFormat('HH:mm').format(value);

  String _statusLabel(String status) {
    switch (status) {
      case 'queued':
        return 'queued';
      case 'sent':
        return 'sent';
      case 'delivered':
        return 'delivered';
      case 'acknowledged':
        return 'acknowledged';
      case 'failed':
        return 'failed';
      default:
        return status;
    }
  }

  Color _bubbleColor(ThemeData theme, DirectMessage message) {
    if (message.isMine) {
      switch (message.status) {
        case 'failed':
          return Colors.red.shade400;
        case 'queued':
          return Colors.orange.shade400;
        default:
          return theme.colorScheme.primary;
      }
    }

    return const Color(0xFF1A2333);
  }

  Widget _buildBridgeBanner() {
    if (_bridgeReady) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: Colors.green.shade700,
        child: const Text(
          'E2EE bridge active',
          style: TextStyle(color: Colors.white, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.red.shade700,
      child: Text(
        _bridgeProblem ??
            'E2EE bridge unavailable. Chat is fail-closed for sending.',
        style: const TextStyle(color: Colors.white, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
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
            const Text(
              'E2EE mailbox chat',
              style: TextStyle(fontSize: 12, color: Colors.lightGreenAccent),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.verified_user_rounded),
            onPressed: _showSafetyNumber,
            tooltip: 'Safety number',
          ),
          IconButton(
            icon: _isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _isSyncing ? null : _syncNow,
            tooltip: 'Синхронизировать',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildBridgeBanner(),
          Expanded(
            child: StreamBuilder<List<DirectMessage>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <DirectMessage>[];

                if (messages.isEmpty) {
                  return const Center(
                    child: Text('Сообщений пока нет'),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

                return ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final isMine = message.isMine;
                    final bubbleColor = _bubbleColor(theme, message);

                    return Align(
                      alignment:
                          isMine ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: bubbleColor,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!isMine)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    widget.friend.displayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              Text(
                                message.text,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _formatTime(message.createdAt),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                  if (isMine) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _statusLabel(message.status),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      enabled: _bridgeReady && !_isSending,
                      decoration: InputDecoration(
                        hintText:
                            _bridgeReady ? 'Сообщение' : 'E2EE bridge недоступен',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _isSendingFile ? null : _pickAndSendFile,
                    icon: _isSendingFile
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file_rounded),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (!_bridgeReady || _isSending) ? null : _sendMessage,
                    child: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
