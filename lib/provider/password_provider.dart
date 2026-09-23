import 'package:autocipher_dart/autocipher_dart.dart' as ac;
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PasswordGenerator {
  const PasswordGenerator();

  /// Generates a password on the native side (same CSPRNG engine as the CLI)
  /// in the grouped `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` format: 5 hyphen-separated
  /// groups of 5 characters, guaranteed to contain uppercase, lowercase,
  /// digits, and symbols.
  Future<String> generate() => ac.generatePassword();
}

final passwordGeneratorProvider = Provider<PasswordGenerator>(
  (ref) => const PasswordGenerator(),
);
