import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/section_header.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.profile,
    required this.onRegister,
    required this.onLogin,
    required this.onResetPassword,
  });

  final UserProfile profile;
  final Future<AuthRegisterResult> Function({
    required String firstName,
    required String lastName,
    required String phone,
    required String password,
    required String serverUrl,
  }) onRegister;
  final Future<void> Function({
    required String phone,
    required String password,
    required String serverUrl,
  }) onLogin;
  final Future<void> Function({
    required String phone,
    required String recoveryCode,
    required String newPassword,
    required String serverUrl,
  }) onResetPassword;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  late final TextEditingController _registerFirstNameController;
  late final TextEditingController _registerLastNameController;
  late final TextEditingController _registerPhoneController;
  late final TextEditingController _registerPasswordController;
  late final TextEditingController _registerPasswordConfirmController;

  late final TextEditingController _loginPhoneController;
  late final TextEditingController _loginPasswordController;

  late final TextEditingController _resetPhoneController;
  late final TextEditingController _resetCodeController;
  late final TextEditingController _resetPasswordController;
  late final TextEditingController _resetPasswordConfirmController;

  bool _registering = false;
  bool _loggingIn = false;
  bool _resettingPassword = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _registerFirstNameController =
        TextEditingController(text: widget.profile.firstName);
    _registerLastNameController =
        TextEditingController(text: widget.profile.lastName);
    _registerPhoneController = TextEditingController(text: widget.profile.phone);
    _registerPasswordController = TextEditingController();
    _registerPasswordConfirmController = TextEditingController();

    _loginPhoneController = TextEditingController(text: widget.profile.phone);
    _loginPasswordController = TextEditingController();

    _resetPhoneController = TextEditingController(text: widget.profile.phone);
    _resetCodeController = TextEditingController();
    _resetPasswordController = TextEditingController();
    _resetPasswordConfirmController = TextEditingController();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _registerFirstNameController.dispose();
    _registerLastNameController.dispose();
    _registerPhoneController.dispose();
    _registerPasswordController.dispose();
    _registerPasswordConfirmController.dispose();
    _loginPhoneController.dispose();
    _loginPasswordController.dispose();
    _resetPhoneController.dispose();
    _resetCodeController.dispose();
    _resetPasswordController.dispose();
    _resetPasswordConfirmController.dispose();
    super.dispose();
  }

  String get _serverUrl => widget.profile.serverUrl.trim();

  Future<void> _handleRegister() async {
    final firstName = _registerFirstNameController.text.trim();
    final lastName = _registerLastNameController.text.trim();
    final phone = _registerPhoneController.text.trim();
    final password = _registerPasswordController.text;
    final confirmPassword = _registerPasswordConfirmController.text;

    if (firstName.isEmpty) {
      _showSnack('Имя обязательно');
      return;
    }
    if (phone.isEmpty) {
      _showSnack('Телефон обязателен');
      return;
    }
    if (password.length < 6) {
      _showSnack('Пароль должен быть не короче 6 символов');
      return;
    }
    if (password != confirmPassword) {
      _showSnack('Пароли не совпадают');
      return;
    }

    setState(() {
      _registering = true;
    });

    try {
      final result = await widget.onRegister(
        firstName: firstName,
        lastName: lastName,
        phone: phone,
        password: password,
        serverUrl: _serverUrl,
      );

      if (!mounted) return;
      await _showRecoveryCodesDialog(result.recoveryCodes);
    } catch (error) {
      if (!mounted) return;
      _showSnack('Ошибка регистрации: $error');
    } finally {
      if (mounted) {
        setState(() {
          _registering = false;
        });
      }
    }
  }

  Future<void> _handleLogin() async {
    final phone = _loginPhoneController.text.trim();
    final password = _loginPasswordController.text;

    if (phone.isEmpty || password.isEmpty) {
      _showSnack('Укажи телефон и пароль');
      return;
    }

    setState(() {
      _loggingIn = true;
    });

    try {
      await widget.onLogin(
        phone: phone,
        password: password,
        serverUrl: _serverUrl,
      );
    } catch (error) {
      if (!mounted) return;
      _showSnack('Ошибка входа: $error');
    } finally {
      if (mounted) {
        setState(() {
          _loggingIn = false;
        });
      }
    }
  }

  Future<void> _handlePasswordReset() async {
    final phone = _resetPhoneController.text.trim();
    final recoveryCode = _resetCodeController.text.trim();
    final newPassword = _resetPasswordController.text;
    final confirmPassword = _resetPasswordConfirmController.text;

    if (phone.isEmpty || recoveryCode.isEmpty) {
      _showSnack('Укажи телефон и код восстановления');
      return;
    }
    if (newPassword.length < 6) {
      _showSnack('Новый пароль должен быть не короче 6 символов');
      return;
    }
    if (newPassword != confirmPassword) {
      _showSnack('Пароли не совпадают');
      return;
    }

    setState(() {
      _resettingPassword = true;
    });

    try {
      await widget.onResetPassword(
        phone: phone,
        recoveryCode: recoveryCode,
        newPassword: newPassword,
        serverUrl: _serverUrl,
      );

      if (!mounted) return;
      _showSnack('Пароль обновлён. Теперь можно войти.');
      _loginPhoneController.text = phone;
      _tabController.animateTo(1);
    } catch (error) {
      if (!mounted) return;
      _showSnack('Ошибка сброса пароля: $error');
    } finally {
      if (mounted) {
        setState(() {
          _resettingPassword = false;
        });
      }
    }
  }

  Future<void> _showRecoveryCodesDialog(List<RecoveryCodeView> items) async {
    final text = items.map((item) => item.code).join('\n');

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('Коды восстановления'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Сохрани эти коды. Они нужны для сброса пароля без SMS. Эти же коды доступны админу на сервере.',
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SelectableText(text),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                _showSnack('Коды скопированы');
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Скопировать'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Я сохранил'),
            ),
          ],
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  InputDecoration _decoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
    );
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
                subtitle: 'Аккаунт по телефону и паролю',
              ),
              const SizedBox(height: 18),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ID устройства', style: theme.textTheme.titleLarge),
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
                  children: [
                    TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabs: const [
                        Tab(text: 'Регистрация'),
                        Tab(text: 'Вход'),
                        Tab(text: 'Сброс пароля'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 430,
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildRegisterTab(),
                          _buildLoginTab(),
                          _buildResetTab(),
                        ],
                      ),
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

  Widget _buildRegisterTab() {
    return ListView(
      children: [
        TextField(
          controller: _registerFirstNameController,
          decoration: _decoration('Имя *', hint: 'Например, Никита'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _registerLastNameController,
          decoration: _decoration('Фамилия'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _registerPhoneController,
          keyboardType: TextInputType.phone,
          decoration: _decoration('Телефон *', hint: '+7 999 123 45 67'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _registerPasswordController,
          obscureText: true,
          decoration: _decoration('Пароль *', hint: 'Минимум 6 символов'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _registerPasswordConfirmController,
          obscureText: true,
          decoration: _decoration('Повтор пароля *'),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _registering ? null : _handleRegister,
          icon: _registering
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Создать аккаунт'),
        ),
      ],
    );
  }

  Widget _buildLoginTab() {
    return ListView(
      children: [
        TextField(
          controller: _loginPhoneController,
          keyboardType: TextInputType.phone,
          decoration: _decoration('Телефон *'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _loginPasswordController,
          obscureText: true,
          decoration: _decoration('Пароль *'),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _loggingIn ? null : _handleLogin,
          icon: _loggingIn
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded),
          label: const Text('Войти'),
        ),
      ],
    );
  }

  Widget _buildResetTab() {
    return ListView(
      children: [
        TextField(
          controller: _resetPhoneController,
          keyboardType: TextInputType.phone,
          decoration: _decoration('Телефон *'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _resetCodeController,
          textCapitalization: TextCapitalization.characters,
          decoration: _decoration(
            'Код восстановления *',
            hint: 'Например, RC-ABCD1234',
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _resetPasswordController,
          obscureText: true,
          decoration: _decoration('Новый пароль *'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _resetPasswordConfirmController,
          obscureText: true,
          decoration: _decoration('Повтор нового пароля *'),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _resettingPassword ? null : _handlePasswordReset,
          icon: _resettingPassword
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_reset_rounded),
          label: const Text('Сбросить пароль'),
        ),
      ],
    );
  }
}