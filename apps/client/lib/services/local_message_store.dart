import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_models.dart';

class LocalMessageStore {
  static const _dbName = 'mayak_local_messages_v2.db';
  static const _dbVersion = 1;
  static const _table = 'direct_messages';

  Database? _database;
  bool _ffiInitialized = false;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  DatabaseFactory get _factory {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        _ffiInitialized = true;
      }
      return databaseFactoryFfi;
    }

    return databaseFactory;
  }

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }

    final dbPath = await _factory.getDatabasesPath();
    final fullPath = p.join(dbPath, _dbName);

    final db = await _factory.openDatabase(
      fullPath,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_table (
              id TEXT PRIMARY KEY,
              chat_id TEXT NOT NULL,
              peer_public_id TEXT NOT NULL,
              peer_device_id TEXT,
              author_public_id TEXT NOT NULL,
              author_display_name TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL,
              is_mine INTEGER NOT NULL,
              status TEXT NOT NULL,
              envelope_id TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              next_retry_at INTEGER,
              last_error TEXT,
              delivered_at INTEGER,
              acknowledged_at INTEGER
            )
          ''');

          await db.execute('''
            CREATE INDEX idx_direct_messages_chat_created
            ON $_table (chat_id, created_at ASC)
          ''');

          await db.execute('''
            CREATE INDEX idx_direct_messages_peer_status
            ON $_table (peer_public_id, status, updated_at DESC)
          ''');

          await db.execute('''
            CREATE INDEX idx_direct_messages_pending_retry
            ON $_table (is_mine, status, next_retry_at, created_at ASC)
          ''');

          await db.execute('''
            CREATE INDEX idx_direct_messages_envelope
            ON $_table (envelope_id)
          ''');
        },
      ),
    );

    _database = db;
    return db;
  }

  Future<List<DirectMessage>> listMessages({
    required String chatId,
  }) async {
    return _getMessagesByChat(chatId);
  }

  Future<List<DirectMessage>> _getMessagesByChat(String chatId) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC',
    );

    return rows.map(_rowToMessage).toList();
  }

  Stream<List<DirectMessage>> watchMessages({
    required String chatId,
  }) async* {
    yield await _getMessagesByChat(chatId);

    await for (final _ in _changes.stream) {
      yield await _getMessagesByChat(chatId);
    }
  }

  Future<DirectMessage?> getMessageById(String messageId) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return _rowToMessage(rows.first);
  }

  Future<void> upsertMessage({
    required String peerPublicId,
    String? peerDeviceId,
    String? envelopeId,
    int? retryCount,
    DateTime? nextRetryAt,
    String? lastError,
    DateTime? deliveredAt,
    DateTime? acknowledgedAt,
    required DirectMessage message,
  }) async {
    final db = await database;
    await _upsertMessageDb(
      db,
      peerPublicId: peerPublicId,
      peerDeviceId: peerDeviceId,
      envelopeId: envelopeId,
      retryCount: retryCount,
      nextRetryAt: nextRetryAt,
      lastError: lastError,
      deliveredAt: deliveredAt,
      acknowledgedAt: acknowledgedAt,
      message: message,
    );
    _notifyChanged();
  }

  Future<void> updateMessageStatus({
    required String messageId,
    required String status,
    String? peerDeviceId,
    String? envelopeId,
    String? lastError,
    DateTime? nextRetryAt,
    bool incrementRetry = false,
    DateTime? deliveredAt,
    DateTime? acknowledgedAt,
  }) async {
    final db = await database;

    final rows = await db.query(
      _table,
      columns: const ['retry_count'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );

    final currentRetryCount = rows.isEmpty
        ? 0
        : (rows.first['retry_count'] as num?)?.toInt() ?? 0;

    await db.update(
      _table,
      {
        'status': status,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        if (peerDeviceId != null) 'peer_device_id': peerDeviceId,
        if (envelopeId != null) 'envelope_id': envelopeId,
        if (lastError != null) 'last_error': lastError,
        'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
        'retry_count': incrementRetry ? currentRetryCount + 1 : currentRetryCount,
        if (deliveredAt != null) 'delivered_at': deliveredAt.millisecondsSinceEpoch,
        if (acknowledgedAt != null)
          'acknowledged_at': acknowledgedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    _notifyChanged();
  }

  Future<void> updateMessageStatusByEnvelope({
    required String envelopeId,
    required String status,
    String? lastError,
    DateTime? nextRetryAt,
    bool incrementRetry = false,
    DateTime? deliveredAt,
    DateTime? acknowledgedAt,
  }) async {
    final db = await database;

    final rows = await db.query(
      _table,
      columns: const ['id', 'retry_count'],
      where: 'envelope_id = ? AND is_mine = 1',
      whereArgs: [envelopeId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return;
    }

    final messageId = rows.first['id']?.toString();
    if (messageId == null || messageId.isEmpty) {
      return;
    }

    final currentRetryCount = (rows.first['retry_count'] as num?)?.toInt() ?? 0;

    await db.update(
      _table,
      {
        'status': status,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        if (lastError != null) 'last_error': lastError,
        'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
        'retry_count': incrementRetry ? currentRetryCount + 1 : currentRetryCount,
        if (deliveredAt != null) 'delivered_at': deliveredAt.millisecondsSinceEpoch,
        if (acknowledgedAt != null)
          'acknowledged_at': acknowledgedAt.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    _notifyChanged();
  }

  Future<void> markMessageDeliveredByEnvelope(String ackForEnvelopeId) async {
    final now = DateTime.now();
    await updateMessageStatusByEnvelope(
      envelopeId: ackForEnvelopeId,
      status: 'delivered',
      deliveredAt: now,
      acknowledgedAt: now,
      lastError: '',
      nextRetryAt: null,
    );
  }

  Future<void> updatePendingStatusesForPeer({
    required String peerPublicId,
    required List<String> fromStatuses,
    required String toStatus,
  }) async {
    if (fromStatuses.isEmpty) {
      return;
    }

    final db = await database;
    final placeholders = List.filled(fromStatuses.length, '?').join(',');

    await db.rawUpdate(
      '''
      UPDATE $_table
      SET status = ?, updated_at = ?
      WHERE peer_public_id = ?
        AND is_mine = 1
        AND status IN ($placeholders)
      ''',
      [
        toStatus,
        DateTime.now().millisecondsSinceEpoch,
        peerPublicId,
        ...fromStatuses,
      ],
    );

    _notifyChanged();
  }

  Future<List<PendingOutgoingMessage>> listPendingOutgoing({
    String? peerPublicId,
    int limit = 100,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final rows = await db.query(
      _table,
      where: peerPublicId == null
          ? '''
            is_mine = 1
            AND status IN (?, ?, ?, ?)
            AND (next_retry_at IS NULL OR next_retry_at <= ?)
          '''
          : '''
            is_mine = 1
            AND peer_public_id = ?
            AND status IN (?, ?, ?, ?)
            AND (next_retry_at IS NULL OR next_retry_at <= ?)
          ''',
      whereArgs: peerPublicId == null
          ? ['queued', 'waiting_for_peer', 'route_ready', 'failed', now]
          : [peerPublicId, 'queued', 'waiting_for_peer', 'route_ready', 'failed', now],
      orderBy: 'created_at ASC',
      limit: limit,
    );

    return rows.map(_rowToPending).toList();
  }

  Future<List<String>> listPendingPeerPublicIds() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final rows = await db.rawQuery(
      '''
      SELECT DISTINCT peer_public_id
      FROM $_table
      WHERE is_mine = 1
        AND status IN ('queued', 'waiting_for_peer', 'route_ready', 'failed')
        AND (next_retry_at IS NULL OR next_retry_at <= ?)
      ORDER BY peer_public_id ASC
      ''',
      [now],
    );

    return rows
        .map((row) => row['peer_public_id']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<void> deleteChatMessages({
    required String chatId,
  }) async {
    final db = await database;
    await db.delete(
      _table,
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    _notifyChanged();
  }

  Future<void> deleteAllMessages() async {
    final db = await database;
    await db.delete(_table);
    _notifyChanged();
  }

  Future<void> _upsertMessageDb(
    DatabaseExecutor db, {
    required String peerPublicId,
    String? peerDeviceId,
    String? envelopeId,
    int? retryCount,
    DateTime? nextRetryAt,
    String? lastError,
    DateTime? deliveredAt,
    DateTime? acknowledgedAt,
    required DirectMessage message,
  }) async {
    final existingRows = await db.query(
      _table,
      columns: const [
        'status',
        'retry_count',
        'envelope_id',
        'peer_device_id',
        'delivered_at',
        'acknowledged_at',
      ],
      where: 'id = ?',
      whereArgs: [message.id],
      limit: 1,
    );

    final currentStatus = existingRows.isEmpty
        ? null
        : existingRows.first['status']?.toString();
    final currentRetryCount = existingRows.isEmpty
        ? 0
        : (existingRows.first['retry_count'] as num?)?.toInt() ?? 0;
    final currentEnvelopeId = existingRows.isEmpty
        ? null
        : existingRows.first['envelope_id']?.toString();
    final currentPeerDeviceId = existingRows.isEmpty
        ? null
        : existingRows.first['peer_device_id']?.toString();
    final currentDeliveredAt = existingRows.isEmpty
        ? null
        : (existingRows.first['delivered_at'] as num?)?.toInt();
    final currentAcknowledgedAt = existingRows.isEmpty
        ? null
        : (existingRows.first['acknowledged_at'] as num?)?.toInt();

    final mergedStatus = _preferStatus(currentStatus, message.status);

    await db.insert(
      _table,
      {
        'id': message.id,
        'chat_id': message.chatId,
        'peer_public_id': peerPublicId,
        'peer_device_id':
            (peerDeviceId != null && peerDeviceId.trim().isNotEmpty)
                ? peerDeviceId.trim().toUpperCase()
                : currentPeerDeviceId,
        'author_public_id': message.authorPublicId,
        'author_display_name': message.authorDisplayName,
        'text': message.text,
        'created_at': message.createdAt.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'is_mine': message.isMine ? 1 : 0,
        'status': mergedStatus,
        'envelope_id':
            (envelopeId != null && envelopeId.trim().isNotEmpty)
                ? envelopeId.trim()
                : currentEnvelopeId,
        'retry_count': retryCount ?? currentRetryCount,
        'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
        'last_error': lastError,
        'delivered_at': deliveredAt?.millisecondsSinceEpoch ?? currentDeliveredAt,
        'acknowledged_at':
            acknowledgedAt?.millisecondsSinceEpoch ?? currentAcknowledgedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String _preferStatus(String? current, String incoming) {
    if (current == null || current.isEmpty) {
      return incoming;
    }

    const priority = <String, int>{
      'failed': 0,
      'local': 1,
      'queued': 2,
      'waiting_for_peer': 3,
      'route_ready': 4,
      'sent': 5,
      'relay_accepted': 5,
      'delivered': 6,
      'acknowledged': 7,
    };

    final currentRank = priority[current] ?? 0;
    final incomingRank = priority[incoming] ?? 0;
    return currentRank >= incomingRank ? current : incoming;
  }

  DirectMessage _rowToMessage(Map<String, Object?> row) {
    return DirectMessage(
      id: row['id']?.toString() ?? '',
      chatId: row['chat_id']?.toString() ?? '',
      authorPublicId: row['author_public_id']?.toString() ?? '',
      authorDisplayName: row['author_display_name']?.toString() ?? '',
      text: row['text']?.toString() ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      isMine: ((row['is_mine'] as num?)?.toInt() ?? 0) == 1,
      status: row['status']?.toString() ?? 'local',
    );
  }

  PendingOutgoingMessage _rowToPending(Map<String, Object?> row) {
    return PendingOutgoingMessage(
      messageId: row['id']?.toString() ?? '',
      chatId: row['chat_id']?.toString() ?? '',
      peerPublicId: row['peer_public_id']?.toString() ?? '',
      peerDeviceId: row['peer_device_id']?.toString(),
      authorPublicId: row['author_public_id']?.toString() ?? '',
      authorDisplayName: row['author_display_name']?.toString() ?? '',
      text: row['text']?.toString() ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      status: row['status']?.toString() ?? 'queued',
      envelopeId: row['envelope_id']?.toString(),
      retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
      nextRetryAt: row['next_retry_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (row['next_retry_at'] as num).toInt(),
            ),
      lastError: row['last_error']?.toString(),
    );
  }

  void _notifyChanged() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<void> dispose() async {
    if (!_changes.isClosed) {
      await _changes.close();
    }
    await _database?.close();
    _database = null;
  }
}
