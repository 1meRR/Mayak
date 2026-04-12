import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../widgets/glass_panel.dart';
import '../widgets/section_header.dart';

class FriendsScreen extends StatelessWidget {
  const FriendsScreen({
    super.key,
    required this.profile,
    required this.friends,
    required this.incomingRequests,
    required this.outgoingRequests,
    required this.onOpenChat,
    required this.onStartVoiceCall,
    required this.onStartVideoCall,
    required this.onAcceptRequest,
    required this.onRejectRequest,
    required this.onDeleteFriend,
    required this.onRefresh,
  });

  final UserProfile profile;
  final List<FriendUser> friends;
  final List<FriendRequestView> incomingRequests;
  final List<FriendRequestView> outgoingRequests;
  final ValueChanged<FriendUser> onOpenChat;
  final ValueChanged<FriendUser> onStartVoiceCall;
  final ValueChanged<FriendUser> onStartVideoCall;
  final ValueChanged<FriendRequestView> onAcceptRequest;
  final ValueChanged<FriendRequestView> onRejectRequest;
  final ValueChanged<FriendUser> onDeleteFriend;
  final Future<void> Function() onRefresh;

  String _initials(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return '?';
    return cleaned.substring(0, 1).toUpperCase();
  }

  String _statusText(FriendUser friend) {
    if (friend.isOnline) return 'online';
    if (friend.lastSeenAt == null) return 'offline';
    final time = friend.lastSeenAt!;
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return 'был(а) в $hh:$mm';
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
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
            children: [
              const SectionHeader(
                title: 'Маяк',
                subtitle: 'Друзья, заявки и диалоги',
              ),
              const SizedBox(height: 18),
              GlassPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Мой ID', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 10),
                    SelectableText(
                      profile.publicId,
                      style: theme.textTheme.headlineMedium?.copyWith(fontSize: 24),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Устройство: ${profile.deviceId}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              GlassPanel(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Добавление новых друзей находится во вкладке «Добавить» внизу экрана.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
              if (incomingRequests.isNotEmpty) ...[
                const SizedBox(height: 18),
                GlassPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Входящие заявки', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 14),
                      ...incomingRequests.map(
                        (request) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  request.fromDisplayName,
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  request.fromPublicId,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    FilledButton.icon(
                                      onPressed: () => onAcceptRequest(request),
                                      icon: const Icon(Icons.check_rounded),
                                      label: const Text('Принять'),
                                    ),
                                    const SizedBox(width: 10),
                                    OutlinedButton.icon(
                                      onPressed: () => onRejectRequest(request),
                                      icon: const Icon(Icons.close_rounded),
                                      label: const Text('Отклонить'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (outgoingRequests.isNotEmpty) ...[
                const SizedBox(height: 18),
                GlassPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Исходящие заявки', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 14),
                      ...outgoingRequests.map(
                        (request) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        request.toDisplayName,
                                        style: theme.textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        request.toPublicId,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: const Text('Ожидает'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (friends.isEmpty)
                GlassPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Друзей пока нет', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Text(
                        'Перейди во вкладку «Добавить», найди пользователя по ID и отправь заявку в друзья.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                )
              else
                ...friends.map(
                  (friend) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: GlassPanel(
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor:
                                theme.colorScheme.primary.withValues(alpha: 0.18),
                            child: Text(
                              _initials(friend.displayName),
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  friend.displayName,
                                  style: theme.textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: friend.isOnline
                                            ? Colors.greenAccent
                                            : Colors.grey,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _statusText(friend),
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  friend.publicId,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                if (friend.about.trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    friend.about,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: Colors.white.withValues(alpha: 0.80),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton.filledTonal(
                                onPressed: () => onOpenChat(friend),
                                icon: const Icon(Icons.chat_bubble_rounded),
                                tooltip: 'Чат',
                              ),
                              const SizedBox(height: 8),
                              IconButton.filledTonal(
                                onPressed: () => onStartVoiceCall(friend),
                                icon: const Icon(Icons.call_rounded),
                                tooltip: 'Голосовой звонок',
                              ),
                              const SizedBox(height: 8),
                              IconButton.filled(
                                onPressed: () => onStartVideoCall(friend),
                                icon: const Icon(Icons.videocam_rounded),
                                tooltip: 'Видеозвонок',
                              ),
                              const SizedBox(height: 8),
                              IconButton(
                                onPressed: () => onDeleteFriend(friend),
                                icon: const Icon(Icons.person_remove_rounded),
                                tooltip: 'Удалить из друзей',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
