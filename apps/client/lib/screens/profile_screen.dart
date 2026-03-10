import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/section_header.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profile,
    required this.onSave,
  });

  final UserProfile profile;
  final ValueChanged<UserProfile> onSave;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _aboutController;
  late final TextEditingController _serverController;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.profile.firstName);
    _lastNameController = TextEditingController(text: widget.profile.lastName);
    _phoneController = TextEditingController(text: widget.profile.phone);
    _aboutController = TextEditingController(text: widget.profile.about);
    _serverController = TextEditingController(text: widget.profile.serverUrl);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _aboutController.dispose();
    _serverController.dispose();
    super.dispose();
  }

  void _save() {
    final firstName = _firstNameController.text.trim();
    if (firstName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Имя обязательно')),
      );
      return;
    }

    final updated = widget.profile.copyWith(
      firstName: firstName,
      lastName: _lastNameController.text.trim(),
      phone: _phoneController.text.trim(),
      about: _aboutController.text.trim(),
      serverUrl: _serverController.text.trim().isEmpty
          ? widget.profile.serverUrl
          : _serverController.text.trim(),
      registered: true,
    );

    widget.onSave(updated);
  }

  Future<void> _copy(String value, String title) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title скопирован')),
    );
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
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            const SectionHeader(
              title: 'Профиль',
              subtitle: 'Пользователь, устройство и сервер',
            ),
            const SizedBox(height: 18),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ID пользователя', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  SelectableText(
                    widget.profile.publicId,
                    style: theme.textTheme.headlineMedium?.copyWith(fontSize: 24),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _copy(widget.profile.publicId, 'ID пользователя'),
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Скопировать ID пользователя'),
                  ),
                  const SizedBox(height: 18),
                  Text('ID устройства', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 10),
                  SelectableText(
                    widget.profile.deviceId,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _copy(widget.profile.deviceId, 'ID устройства'),
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Скопировать ID устройства'),
                  ),
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
                    decoration: const InputDecoration(
                      labelText: 'Имя *',
                      hintText: 'Например, Влад',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(
                      labelText: 'Фамилия',
                      hintText: 'Необязательно',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Телефон',
                      hintText: 'Необязательно',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _aboutController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'О себе',
                      hintText: 'Короткий статус профиля',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _serverController,
                    decoration: const InputDecoration(
                      labelText: 'Signaling server URL',
                      hintText: 'ws://155.212.247.22:8080/ws',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Сохранить профиль'),
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