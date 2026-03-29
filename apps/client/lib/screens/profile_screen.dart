import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profile,
    required this.onSave,
    required this.onLogout,
    required this.onCreateKeyBackup,
    required this.onRestoreKeyBackup,
  });

  final UserProfile profile;
  final Future<void> Function(UserProfile updated) onSave;
  final Future<void> Function() onLogout;
  final Future<String> Function(String passphrase) onCreateKeyBackup;
  final Future<void> Function({required String passphrase, required String backupBlob})
      onRestoreKeyBackup;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _aboutController;

  bool _saving = false;
  bool _backupBusy = false;

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

  Future<String?> _askPassphrase(String title) async {
    final ctrl = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Recovery passphrase',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );

    ctrl.dispose();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  Future<void> _createBackup() async {
    if (_backupBusy) return;

    final passphrase = await _askPassphrase('Создать encrypted backup');
    if (passphrase == null) return;

    setState(() => _backupBusy = true);
    try {
      final blob = await widget.onCreateKeyBackup(passphrase);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Backup blob'),
          content: SingleChildScrollView(
            child: SelectableText(blob),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка backup: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _backupBusy = false);
      }
    }
  }

  Future<void> _restoreBackup() async {
    if (_backupBusy) return;

    final passphrase = await _askPassphrase('Восстановить encrypted backup');
    if (passphrase == null) return;
    if (!mounted) return;

    final blobCtrl = TextEditingController();
    final blob = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Вставь backup blob'),
        content: TextField(
          controller: blobCtrl,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Base64 backup blob',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(blobCtrl.text.trim()),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    blobCtrl.dispose();

    if (blob == null || blob.isEmpty) return;

    setState(() => _backupBusy = true);
    try {
      await widget.onRestoreKeyBackup(
        passphrase: passphrase,
        backupBlob: blob,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup успешно восстановлен')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка restore: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _backupBusy = false);
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
                  Text('Backup / Recovery', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  Text(
                    'Создай encrypted backup E2EE ключей и восстанови его на устройстве через recovery passphrase.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _backupBusy ? null : _createBackup,
                        icon: const Icon(Icons.backup_rounded),
                        label: const Text('Создать backup'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _backupBusy ? null : _restoreBackup,
                        icon: const Icon(Icons.restore_rounded),
                        label: const Text('Восстановить'),
                      ),
                    ],
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
