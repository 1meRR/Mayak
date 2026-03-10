import 'package:flutter/material.dart';

import '../screens/app_shell_screen.dart';
import 'theme.dart';

class MayakApp extends StatelessWidget {
  const MayakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Маяк',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: buildAppTheme(),
      home: const AppShellScreen(),
    );
  }
}