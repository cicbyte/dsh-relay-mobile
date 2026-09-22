import 'package:flutter/material.dart';

import 'app_shell.dart';

void main() {
  runApp(const DshMobileApp());
}

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F6BED),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AppRoot(),
    );
  }
}
