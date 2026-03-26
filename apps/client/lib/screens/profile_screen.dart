import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profile,
    required this.onSave,
    required this.onLogout,
  });

  final UserProfile profile;
  final Future<void> Function(UserProfile updated) onSave;
  final Future<void> Function() onLogout;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _aboutController;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.profile.firstName);
    _lastNameController = TextEditingController(text: widget.profile.lastName);
    _aboutController = TextEditingController(text: widget.profile.about);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      final updated = widget.profile.copyWith(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        about: _aboutController.text.trim(),
      );

      await widget.onSave(updated);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён локально на этом устройстве')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить профиль: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
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
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Аккаунт', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SelectableText(widget.profile.publicId),
                  const SizedBox(height: 10),
                  if (widget.profile.friendCode.isNotEmpty) ...[
                    Text('Friend code', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    SelectableText(widget.profile.friendCode),
                    const SizedBox(height: 10),
                  ],
                  Text('ID устройства', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  SelectableText(widget.profile.deviceId),
                ],
              ),
            ),
            const SizedBox(height: 18),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Основные данные', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _firstNameController,
                    decoration: const InputDecoration(labelText: 'Имя'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(labelText: 'Фамилия'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _aboutController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'О себе'),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded),
                    label: const Text('Сохранить'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Сессия', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  Text(
                    'Выход удалит локальную сессию только на этом устройстве. История чатов хранится локально на устройствах участников и не должна находиться на сервере.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.onLogout,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Выйти из аккаунта'),
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