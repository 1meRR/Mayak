import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../services/api_service.dart';
import '../widgets/glass_panel.dart';
import '../widgets/section_header.dart';

class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({
    super.key,
    required this.profile,
    required this.api,
    required this.onFriendRequestSent,
  });

  final UserProfile profile;
  final ApiService api;
  final Future<void> Function() onFriendRequestSent;

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  final TextEditingController _idController = TextEditingController();

  FriendUser? _foundUser;
  bool _searching = false;
  bool _sending = false;
  String? _statusMessage;

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final query = _idController.text.trim().toUpperCase();

    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введи ID пользователя или friend code')),
      );
      return;
    }

    if (query == widget.profile.publicId.toUpperCase() ||
        query == widget.profile.friendCode.toUpperCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нельзя добавить самого себя')),
      );
      return;
    }

    setState(() {
      _searching = true;
      _foundUser = null;
      _statusMessage = null;
    });

    try {
      final user = await widget.api.lookupUser(query);

      if (!mounted) return;
      setState(() {
        _foundUser = user;
        _statusMessage = 'Пользователь найден. Можно отправить заявку.';
      });
    } catch (error) {
      final message = error.toString().contains('HTTP 404')
          ? 'Этот сервер не поддерживает поиск друзей (/v1/users/*). '
              'Нужен backend с friends API.'
          : 'Поиск не удался: $error';
      if (!mounted) return;
      setState(() {
        _statusMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  Future<void> _sendRequest() async {
    final foundUser = _foundUser;
    if (foundUser == null || _sending) {
      return;
    }

    if (!widget.profile.hasActiveSession) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала войди в аккаунт на этом устройстве')),
      );
      return;
    }

    setState(() {
      _sending = true;
      _statusMessage = null;
    });

    try {
      await widget.api.createFriendRequest(
        fromPublicId: widget.profile.publicId,
        fromDeviceId: widget.profile.deviceId,
        sessionToken: widget.profile.sessionToken,
        toPublicId: foundUser.publicId,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Заявка отправлена пользователю ${foundUser.displayName}')),
      );
      setState(() {
        _statusMessage = 'Заявка отправлена.';
      });

      await widget.onFriendRequestSent();
    } catch (error) {
      final message = error.toString().contains('HTTP 404')
          ? 'Этот сервер не поддерживает отправку заявок (/v1/friends/*).'
          : 'Не удалось отправить заявку: $error';
      if (!mounted) return;
      setState(() {
        _statusMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
          children: [
            const SectionHeader(
              title: 'Добавить друга',
              subtitle: 'Ищи по public ID или friend code',
            ),
            const SizedBox(height: 16),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Твой friend code: ${widget.profile.friendCode.isEmpty ? 'будет после входа' : widget.profile.friendCode}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _idController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Public ID или friend code',
                      hintText: 'Например: M8Q3K4P2 или FC7Z91AB',
                    ),
                    onSubmitted: (_) => _lookup(),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _searching ? null : _lookup,
                    icon: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search_rounded),
                    label: const Text('Найти пользователя'),
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _statusMessage!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _statusMessage!.startsWith('Пользователь найден') ||
                                _statusMessage!.startsWith('Заявка отправлена')
                            ? Colors.lightGreenAccent
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_foundUser != null)
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _foundUser!.displayName,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text('ID: ${_foundUser!.publicId}'),
                    if (_foundUser!.friendCode.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('Friend code: ${_foundUser!.friendCode}'),
                    ],
                    if (_foundUser!.about.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_foundUser!.about),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendRequest,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Отправить заявку'),
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
