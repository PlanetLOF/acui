import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/common/app_theme.dart';
import 'ui/screens/provider_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AcuiApp()));
}

class AcuiApp extends StatelessWidget {
  const AcuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'auto_cipher',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const ProviderScreen(),
    );
  }
}
