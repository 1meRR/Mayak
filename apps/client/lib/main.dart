import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'screens/app_shell_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Text(
              details.exceptionAsString(),
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  };

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  runApp(const MayakRootApp());
}

class MayakRootApp extends StatelessWidget {
  const MayakRootApp({super.key});

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