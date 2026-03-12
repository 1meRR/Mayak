import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

class SettingsRepository {
  static const _profileKey = 'mayak_profile';
  static const _recentRoomsKey = 'recent_rooms';

  /// Продовый сервер.
  static const String fixedServerUrl = 'ws://155.212.247.22:8080/ws';

  static const Set<String> _legacyServerUrls = {
    '',
    'ws://127.0.0.1:8080/ws',
    'ws://localhost:8080/ws',
    'ws://10.0.2.2:8080/ws',
  };

  Future<UserProfile> ensureProfile() async {
    final existing = await getProfile();
    if (existing != null) {
      return existing;
    }

    final profile = UserProfile(
      publicId: _generateShortId('M'),
      deviceId: _generateShortId('D'),
      firstName: '',
      lastName: '',
      phone: '',
      about: 'На связи в Маяке',
      serverUrl: fixedServerUrl,
      createdAt: DateTime.now(),
      registered: false,
    );

    await saveProfile(profile);
    return profile;
  }

  Future<UserProfile?> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }

    final profile = UserProfile.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );

    final migrated = _normalizeProfile(profile);

    if (!_sameProfile(profile, migrated)) {
      await saveProfile(migrated);
    }

    return migrated;
  }

  Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeProfile(profile);
    await prefs.setString(_profileKey, jsonEncode(normalized.toJson()));
  }

  Future<void> clearProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_profileKey);
  }

  Future<void> clearSession() async {
    final profile = await getProfile();

    if (profile == null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentRoomsKey);
      return;
    }

    final cleared = profile.copyWith(
      firstName: '',
      lastName: '',
      phone: '',
      about: 'На связи в Маяке',
      serverUrl: fixedServerUrl,
      registered: false,
    );

    await saveProfile(cleared);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentRoomsKey);
  }

  Future<UserProfile> completeRegistration({
    required String firstName,
    required String lastName,
    required String phone,
  }) async {
    final profile = await ensureProfile();

    final updated = profile.copyWith(
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      phone: _normalizePhone(phone),
      registered: true,
      serverUrl: fixedServerUrl,
      about: profile.about.trim().isEmpty ? 'На связи в Маяке' : profile.about,
    );

    await saveProfile(updated);
    return updated;
  }

  Future<String> getDisplayName() async {
    final profile = await ensureProfile();
    return profile.displayName;
  }

  Future<String> getServerUrl() async {
    final profile = await ensureProfile();
    return profile.serverUrl;
  }

  Future<List<String>> getRecentRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentRoomsKey);
    if (raw == null || raw.isEmpty) {
      return [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return [];
    }

    return decoded.map((item) => item.toString()).toList();
  }

  Future<void> saveBaseSettings({
    required String displayName,
    required String serverUrl,
  }) async {
    final profile = await ensureProfile();
    final parts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((item) => item.trim().isNotEmpty)
        .toList();

    final firstName = parts.isNotEmpty ? parts.first : profile.firstName;
    final lastName =
        parts.length > 1 ? parts.sublist(1).join(' ') : profile.lastName;

    await saveProfile(
      profile.copyWith(
        firstName: firstName,
        lastName: lastName,
        serverUrl: fixedServerUrl,
      ),
    );
  }

  Future<void> saveRecentRoom(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getRecentRooms();

    final updated = <String>[
      roomId,
      ...current.where((String item) => item != roomId),
    ].take(8).toList();

    await prefs.setString(_recentRoomsKey, jsonEncode(updated));
  }

  static String buildDirectChatId(String myPublicId, String friendPublicId) {
    final ids = [
      myPublicId.trim().toUpperCase(),
      friendPublicId.trim().toUpperCase(),
    ]..sort();
    return ids.join('__');
  }

  static String buildDirectRoomId(String myPublicId, String friendPublicId) {
    final chatId = buildDirectChatId(myPublicId, friendPublicId);
    return 'dm_$chatId';
  }

  UserProfile _normalizeProfile(UserProfile profile) {
    final rawServerUrl = profile.serverUrl.trim();

    final mustUseFixedServer = _legacyServerUrls.contains(rawServerUrl) ||
        rawServerUrl.contains('10.0.2.2') ||
        rawServerUrl.contains('127.0.0.1') ||
        rawServerUrl.contains('localhost');

    return profile.copyWith(
      phone: _normalizePhone(profile.phone),
      about: profile.about.trim().isEmpty ? 'На связи в Маяке' : profile.about.trim(),
      serverUrl: mustUseFixedServer ? fixedServerUrl : rawServerUrl,
    );
  }

  bool _sameProfile(UserProfile a, UserProfile b) {
    return a.publicId == b.publicId &&
        a.deviceId == b.deviceId &&
        a.firstName == b.firstName &&
        a.lastName == b.lastName &&
        a.phone == b.phone &&
        a.about == b.about &&
        a.serverUrl == b.serverUrl &&
        a.createdAt.millisecondsSinceEpoch == b.createdAt.millisecondsSinceEpoch &&
        a.registered == b.registered;
  }

  String _normalizePhone(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  String _generateShortId(String prefix) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();

    final chars = List.generate(
      8,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();

    return '$prefix-$chars';
  }
}