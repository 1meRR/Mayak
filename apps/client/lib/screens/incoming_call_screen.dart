import 'package:flutter/material.dart';

import '../models/app_models.dart';

class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({
    super.key,
    required this.invite,
  });

  final CallInviteView invite;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF070B14),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.call_rounded,
                  size: 72,
                  color: Colors.white,
                ),
                const SizedBox(height: 24),
                Text(
                  'Входящий звонок',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 18),
                Text(
                  invite.callerDisplayName,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontSize: 34,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  invite.callerPublicId,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 40),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        onPressed: () => Navigator.of(context).pop('reject'),
                        icon: const Icon(Icons.call_end_rounded),
                        label: const Text('Отклонить'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop('accept'),
                        icon: const Icon(Icons.call_rounded),
                        label: const Text('Принять'),
                      ),
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