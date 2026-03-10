import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/section_header.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.profile,
    required this.onComplete,
  });

  final UserProfile profile;
  final Future<void> Function({
    required String firstName,
    required String lastName,
    required String phone,
  }) onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(text: widget.profile.firstName);
    _lastNameController = TextEditingController(text: widget.profile.lastName);
    _phoneController = TextEditingController(text: widget.profile.phone);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final phone = _phoneController.text.trim();

    if (firstName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Имя обязательно')),
      );
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await widget.onComplete(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
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

    return Scaffold(
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
            children: [
              const SectionHeader(
                title: 'Маяк',
                subtitle: 'Первый запуск и регистрация устройства',
              ),
              const SizedBox(height: 18),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Твой пользовательский ID',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      widget.profile.publicId,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'ID этого устройства',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      widget.profile.deviceId,
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Регистрация', style: theme.textTheme.titleLarge),
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
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_forward_rounded),
                      label: const Text('Продолжить'),
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