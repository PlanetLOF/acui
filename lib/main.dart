import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider/browser_provider.dart';
import 'ui/common/app_theme.dart';
import 'ui/screens/provider_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled mpv drives the video-frame preview; failure here only disables
  // that one feature, so initialization errors are swallowed defensively.
  ensureMediaKitInitialized();
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
