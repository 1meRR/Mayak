import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

class SettingsRepository {
  static const _profileKey = 'mayak_profile';
  static const _displayNameKey = 'mayak_display_name';
  static const _serverUrlKey = 'mayak_server_url';
  static const _recentRoomsKey = 'recent_rooms';
  static const _mailboxCursorKeyPrefix = 'mayak_mailbox_cursor';
  static const _deviceKeyPackageStateKeyPrefix = 'mayak_device_key_package';

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

    final displayName = await getDisplayName();
    final serverUrl = await getServerUrl();
    final parts = displayName.trim().split(RegExp(r'\s+'));
    final firstName = parts.isNotEmpty ? parts.first : '';
    final lastName = parts.length > 1 ? parts.skip(1).join(' ') : '';

    final profile = UserProfile(
      publicId: _generateShortId('M'),
      friendCode: '',
      deviceId: _generateShortId('D'),
      sessionToken: '',
      firstName: firstName,
      lastName: lastName,
      phone: '',
      about: 'На связи в Маяке',
      serverUrl: _normalizeServerUrl(serverUrl),
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
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));

    await saveBaseSettings(
      displayName: profile.displayName,
      serverUrl: profile.serverUrl,
    );
  }

  Future<void> clearSession() async {
    final existing = await ensureProfile();
    await clearMailboxCursor(existing);
    await clearDeviceKeyPackageState(existing);

    final cleared = existing.copyWith(
      publicId: '',
      friendCode: '',
      sessionToken: '',
      firstName: '',
      lastName: '',
      phone: '',
      registered: false,
    );
    await saveProfile(cleared);
  }

  Future<String> getDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_displayNameKey)?.trim() ?? '';
  }

  Future<String> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_serverUrlKey)?.trim() ?? '';
    return _normalizeServerUrl(value);
  }

  Future<void> saveBaseSettings({
    required String displayName,
    required String serverUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, displayName.trim());
    await prefs.setString(_serverUrlKey, _normalizeServerUrl(serverUrl));
  }

  Future<List<String>> getRecentRooms() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_recentRoomsKey) ?? const [];
  }

  Future<void> saveRecentRooms(List<String> roomIds) async {
    final prefs = await SharedPreferences.getInstance();
    final unique = <String>[];

    for (final roomId in roomIds) {
      final normalized = roomId.trim().toUpperCase();
      if (normalized.isEmpty || unique.contains(normalized)) {
        continue;
      }
      unique.add(normalized);
      if (unique.length >= 20) {
        break;
      }
    }

    await prefs.setStringList(_recentRoomsKey, unique);
  }

  Future<void> saveRecentRoom(String roomId) async {
    final current = await getRecentRooms();
    final normalized = roomId.trim().toUpperCase();
    final merged = <String>[
      normalized,
      ...current.where((item) => item.trim().toUpperCase() != normalized),
    ];
    await saveRecentRooms(merged);
  }

  Future<int?> getMailboxCursor(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _mailboxCursorStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    return prefs.getInt(key);
  }

  Future<void> saveMailboxCursor(UserProfile profile, int serverSeq) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _mailboxCursorStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    await prefs.setInt(key, serverSeq);
  }

  Future<void> clearMailboxCursor(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _mailboxCursorStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    await prefs.remove(key);
  }

  Future<int?> getDeviceKeyPackageVersion(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _deviceKeyPackageStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    return prefs.getInt(key);
  }

  Future<bool> isDeviceKeyPackagePublished(
    UserProfile profile, {
    int expectedVersion = 1,
  }) async {
    final version = await getDeviceKeyPackageVersion(profile);
    return version != null && version >= expectedVersion;
  }

  Future<void> markDeviceKeyPackagePublished(
    UserProfile profile, {
    int version = 1,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _deviceKeyPackageStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    await prefs.setInt(key, version);
  }

  Future<void> clearDeviceKeyPackageState(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _deviceKeyPackageStorageKey(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
    );
    await prefs.remove(key);
  }

  static String buildDirectChatId(String left, String right) {
    final items = [left.trim().toUpperCase(), right.trim().toUpperCase()]..sort();
    return 'dm_${items.join('_')}';
  }

  UserProfile _normalizeProfile(UserProfile profile) {
    return profile.copyWith(
      publicId: profile.publicId.trim().toUpperCase(),
      friendCode: profile.friendCode.trim().toUpperCase(),
      deviceId: profile.deviceId.trim().toUpperCase(),
      sessionToken: profile.sessionToken.trim(),
      firstName: profile.firstName.trim(),
      lastName: profile.lastName.trim(),
      phone: profile.phone.trim(),
      about: profile.about.trim(),
      serverUrl: _normalizeServerUrl(profile.serverUrl),
    );
  }

  bool _sameProfile(UserProfile left, UserProfile right) {
    return left.publicId == right.publicId &&
        left.friendCode == right.friendCode &&
        left.deviceId == right.deviceId &&
        left.sessionToken == right.sessionToken &&
        left.firstName == right.firstName &&
        left.lastName == right.lastName &&
        left.phone == right.phone &&
        left.about == right.about &&
        left.serverUrl == right.serverUrl &&
        left.createdAt.millisecondsSinceEpoch ==
            right.createdAt.millisecondsSinceEpoch &&
        left.registered == right.registered;
  }

  String _mailboxCursorStorageKey({
    required String publicId,
    required String deviceId,
  }) {
    return '$_mailboxCursorKeyPrefix:${publicId.trim().toUpperCase()}:${deviceId.trim().toUpperCase()}';
  }

  String _deviceKeyPackageStorageKey({
    required String publicId,
    required String deviceId,
  }) {
    return '$_deviceKeyPackageStateKeyPrefix:${publicId.trim().toUpperCase()}:${deviceId.trim().toUpperCase()}';
  }

  static String _normalizeServerUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty || _legacyServerUrls.contains(value)) {
      return fixedServerUrl;
    }
    return value;
  }

  static String _generateShortId(String prefix) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final buffer = StringBuffer(prefix.toUpperCase());

    for (var i = 0; i < 8; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }
}