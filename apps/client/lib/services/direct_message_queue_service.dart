import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

import '../models/app_models.dart';
import '../models/p2p_models.dart';
import 'api_service.dart';
import 'local_message_store.dart';
import 'settings_repository.dart';
import 'signaling_service.dart';
import 'p2p_message_transport.dart';

class DirectMessageQueueService {
  DirectMessageQueueService({
    required this.api,
    required this.store,
    required this.profile,
    required this.signaling,
  }) {
    _startRetryTimer();
  }

  final ApiService api;
  final LocalMessageStore store;
  final UserProfile profile;
  final SignalingService signaling;
  final Uuid _uuid = const Uuid();
  
  Timer? _retryTimer;
  final Map<String, P2PMessageTransport> _activeTransports = {};
  StreamSubscription? _signalingSubscription;

  void _startRetryTimer() {
    // Слушаем сигналы от сервера для P2P транспорта
    _signalingSubscription = signaling.messages.listen((msg) {
      if (msg.roomId == null || !msg.roomId!.startsWith('dm_')) return;
      
      final chatId = msg.roomId!.replaceFirst('dm_', '');
      final transport = _activeTransports[chatId];
      
      if (transport != null) {
        if (msg.type == 'offer') transport.handleOffer(msg);
        if (msg.type == 'answer') transport.handleAnswer(msg);
        if (msg.type == 'ice_candidate') transport.handleIceCandidate(msg);
      }
    });

    // Механизм Retry (каждые 10 секунд пытаемся доставить зависшие сообщения)
    _retryTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _processQueue();
    });
  }

  Future<void> _processQueue() async {
    // Находим все чаты, где есть сообщения со статусом queued или waiting_for_peer
    // В реальном приложении лучше сделать отдельный SQL запрос в LocalMessageStore,
    // но для простоты переберем всех друзей через историю (или передадим список друзей)
    // В рамках текущей архитектуры, мы будем вызывать этот метод при открытии конкретного чата.
  }

  // Метод для ручной синхронизации и отправки зависших сообщений при открытии чата
  Future<void> syncLegacyMessages(FriendUser friend) async {
    final chatId = SettingsRepository.buildDirectChatId(profile.publicId, friend.publicId);
    
    // Получаем локальные недоставленные сообщения
    final localMessages = await store.listMessages(chatId: chatId);
    final pending = localMessages.where((m) => m.isMine && (m.status == 'queued' || m.status == 'waiting_for_peer')).toList();

    if (pending.isEmpty) return;

    // Проверяем онлайн статус друга
    final devices = await refreshPeerRouting(friend);
    final isOnline = devices.any((d) => d.isOnline);

    if (isOnline) {
      final transport = await _getOrInitializeTransport(friend, chatId);
      
      // Ждем соединения
      int attempts = 0;
      while (!transport.isConnected && attempts < 10) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      if (transport.isConnected) {
        for (var msg in pending) {
          try {
            transport.sendMessage(msg);
            // Статус обновится на 'delivered' когда придет ACK через transport.onMessageAck
          } catch (e) {
            debugPrint('Failed to send p2p message: $e');
          }
        }
      }
    }
  }

  Future<P2PMessageTransport> _getOrInitializeTransport(FriendUser friend, String chatId) async {
    if (_activeTransports.containsKey(chatId)) {
      return _activeTransports[chatId]!;
    }

    final transport = P2PMessageTransport(
      signaling: signaling,
      myPublicId: profile.publicId,
      peerPublicId: friend.publicId,
      roomId: 'dm_$chatId',
    );

    _activeTransports[chatId] = transport;

    transport.onMessageReceived.listen((msg) async {
      await store.upsertMessage(peerPublicId: friend.publicId, message: msg);
    });

    transport.onMessageAck.listen((msgId) async {
      await store.updateMessageStatus(messageId: msgId, status: 'delivered');
    });

    await transport.initializeAsCaller();
    return transport;
  }

  Future<List<PeerDeviceEndpoint>> refreshPeerRouting(FriendUser friend) async {
    await api.announceP2pDevice(
      publicId: profile.publicId,
      deviceId: profile.deviceId,
      sessionToken: profile.sessionToken,
      platform: 'flutter',
      appVersion: '0.3.0+3',
      signalingWsUrl: profile.serverUrl,
      transportPreference: 'webrtc',
      stunServers: const [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
      ],
      turnServers: const [],
      capabilities: const {
        'supportsCalls': true,
        'supportsDirectMessages': true,
        'supportsLocalQueue': true,
        'supportsFiles': true,
      },
    );

    final devices = await api.fetchPeerDevices(friend.publicId);
    final nextStatus = devices.any((item) => item.isOnline)
        ? 'waiting_for_peer' // Был 'route_ready', но теперь мы ждем P2P соединения
        : 'queued';

    await store.updatePendingStatusesForPeer(
      peerPublicId: friend.publicId,
      fromStatuses: const ['queued', 'waiting_for_peer', 'route_ready'],
      toStatus: nextStatus,
    );

    return devices;
  }

  Future<DirectMessage> sendTextMessage({
    required FriendUser friend,
    required String text,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      throw Exception('Пустое сообщение отправлять нельзя');
    }

    final chatId = SettingsRepository.buildDirectChatId(
      profile.publicId,
      friend.publicId,
    );

    final optimistic = DirectMessage(
      id: 'local_${_uuid.v4()}',
      chatId: chatId,
      authorPublicId: profile.publicId,
      authorDisplayName: profile.displayName,
      text: normalizedText,
      createdAt: DateTime.now(),
      isMine: true,
      status: 'queued', // Изначально всегда queued (локально)
    );

    // 1. Сохраняем ТОЛЬКО локально, на сервер больше не отправляем.
    await store.upsertMessage(
      peerPublicId: friend.publicId,
      message: optimistic,
    );

    // 2. Пытаемся сразу отправить через P2P, если друг онлайн
    try {
      await syncLegacyMessages(friend);
    } catch (e) {
      debugPrint('Sync failed, message remains queued: $e');
    }

    // Возвращаем optimistic сообщение для UI
    return optimistic;
  }

  void dispose() {
    _retryTimer?.cancel();
    _signalingSubscription?.cancel();
    for (var transport in _activeTransports.values) {
      transport.dispose();
    }
    _activeTransports.clear();
  }
}