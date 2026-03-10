import 'dart:math';

import 'package:flutter/material.dart';

import '../controllers/call_controller.dart';
import '../services/settings_repository.dart';
import '../widgets/glass_panel.dart';
import 'call_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _nameController = TextEditingController();
  final _roomController = TextEditingController();
  final _serverController = TextEditingController();

  final _settings = SettingsRepository();

  bool _isBusy = false;
  List<String> _recentRooms = const [];

  @override
  void initState() {
    super.initState();
    _restoreState();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roomController.dispose();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _restoreState() async {
    final displayName = await _settings.getDisplayName();
    final serverUrl = await _settings.getServerUrl();
    final recentRooms = await _settings.getRecentRooms();

    if (!mounted) {
      return;
    }

    setState(() {
      _nameController.text = displayName;
      _serverController.text = serverUrl;
      _roomController.text = _generateRoomCode();
      _recentRooms = recentRooms;
    });
  }

  String _generateRoomCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(
      6,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  Future<void> _joinRoom() async {
    final name = _nameController.text.trim();
    final room = _roomController.text.trim().toUpperCase();
    final serverUrl = _serverController.text.trim();

    if (name.isEmpty || room.isEmpty || serverUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заполни имя, комнату и URL signaling server.')),
      );
      return;
    }

    setState(() {
      _isBusy = true;
    });

    final controller = CallController(
      roomId: room,
      displayName: name,
      serverUrl: serverUrl,
      isCaller: true
    );

    try {
      await controller.join();
      await _settings.saveBaseSettings(
        displayName: name,
        serverUrl: serverUrl,
      );
      await _settings.saveRecentRoom(room);

      if (!mounted) {
        await controller.shutdown(notifyServer: false);
        controller.dispose();
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(controller: controller),
        ),
      );

      final updatedRecentRooms = await _settings.getRecentRooms();
      if (mounted) {
        setState(() {
          _recentRooms = updatedRecentRooms;
          _roomController.text = _generateRoomCode();
        });
      }
    } catch (error) {
      await controller.shutdown(notifyServer: false);
      controller.dispose();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось подключиться: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Widget _buildFeatureCard(IconData icon, String title, String subtitle) {
    return GlassPanel(
      padding: const EdgeInsets.all(18),
      borderRadius: 24,
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    final theme = Theme.of(context);

    return GlassPanel(
      borderRadius: 32,
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Flutter + Rust + WebRTC',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Decentra Call',
            style: theme.textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          Text(
            'Мессенджер с фокусом на видеозвонки: быстрые комнаты, P2P-потоки, адаптивный desktop/mobile интерфейс.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _isBusy ? null : _joinRoom,
                icon: const Icon(Icons.video_call_rounded),
                label: Text(_isBusy ? 'Подключение...' : 'Войти в комнату'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _roomController.text = _generateRoomCode();
                  });
                },
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('Сгенерировать код'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return GlassPanel(
      borderRadius: 32,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Параметры входа', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 18),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Твоё имя',
              hintText: 'Например, Nikita',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _roomController,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Код комнаты',
              hintText: 'Например, ABCD23',
              suffixIcon: IconButton(
                onPressed: () {
                  setState(() {
                    _roomController.text = _generateRoomCode();
                  });
                },
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _serverController,
            decoration: const InputDecoration(
              labelText: 'Signaling server URL',
              hintText: 'ws://127.0.0.1:8080/ws',
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _isBusy ? null : _joinRoom,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(_isBusy ? 'Подключаемся...' : 'Подключиться'),
          ),
          if (_recentRooms.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              'Недавние комнаты',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _recentRooms
                  .map(
                    (room) => ActionChip(
                      label: Text(room),
                      onPressed: () {
                        setState(() {
                          _roomController.text = room;
                        });
                      },
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final horizontalPadding = width >= 1300
        ? 72.0
        : width >= 900
            ? 40.0
            : 20.0;

    final isWide = width >= 1000;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.6,
            colors: [
              Color(0xFF18223A),
              Color(0xFF0B0E14),
              Color(0xFF06080D),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              24,
              horizontalPadding,
              32,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF7C5CFF), Color(0xFF35C2FF)],
                        ),
                      ),
                      child: const Icon(Icons.hub_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Decentra Call',
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(
                          'Видео-first messenger MVP',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                if (isWide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: _buildHero()),
                      const SizedBox(width: 22),
                      Expanded(flex: 5, child: _buildForm()),
                    ],
                  )
                else ...[
                  _buildHero(),
                  const SizedBox(height: 18),
                  _buildForm(),
                ],
                const SizedBox(height: 24),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: width >= 1100
                      ? 3
                      : width >= 650
                          ? 2
                          : 1,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: width >= 650 ? 2.3 : 2.0,
                  children: [
                    _buildFeatureCard(
                      Icons.videocam_rounded,
                      'P2P video',
                      'Прямые WebRTC-потоки между участниками без медиасервера.',
                    ),
                    _buildFeatureCard(
                      Icons.devices_rounded,
                      'Desktop + mobile',
                      'Один Flutter-код для Windows, macOS, Linux, Android и iPhone.',
                    ),
                    _buildFeatureCard(
                      Icons.speed_rounded,
                      'Rust signaling',
                      'Быстрый и компактный signaling server на WebSocket.',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
