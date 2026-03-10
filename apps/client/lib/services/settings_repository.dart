import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

class SettingsRepository {
  static const _profileKey = 'mayak_profile';
  static const _recentRoomsKey = 'recent_rooms';

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
      serverUrl: 'ws://155.212.247.22:8080/ws',
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

    return UserProfile.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
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
      phone: phone.trim(),
      registered: true,
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
    final parts = displayName.trim().split(RegExp(r'\s+'));
    final firstName = parts.isNotEmpty ? parts.first : profile.firstName;
    final lastName =
        parts.length > 1 ? parts.sublist(1).join(' ') : profile.lastName;

    await saveProfile(
      profile.copyWith(
        firstName: firstName,
        lastName: lastName,
        serverUrl: serverUrl,
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

  String _generateShortId(String prefix) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();

    final chars = List.generate(
      5,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();

    return '$prefix-$chars';
  }
}