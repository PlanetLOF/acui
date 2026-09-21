import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class PasswordGenerator {
  const PasswordGenerator();

  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*';

  /// Uses the OS CSPRNG via [Random.secure].
  String generate([int length = 16]) {
    final rng = Random.secure();
    return String.fromCharCodes(
      List.generate(
        length,
        (_) => _chars.codeUnitAt(rng.nextInt(_chars.length)),
      ),
    );
  }
}

final passwordGeneratorProvider = Provider<PasswordGenerator>(
  (ref) => const PasswordGenerator(),
);
