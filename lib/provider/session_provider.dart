// The open vault. `create`/`open` populate it; `close` scrubs it and returns
// the shell. It lives at app scope so the shell can switch scenes between the
// provider forms and the vault browser. Underneath, `Vault` runs long ops
// (Argon2id, folder imports, compact) on worker isolates.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VaultNotifier extends Notifier<Vault?> {
  @override
  Vault? build() => null;

  Future<void> create(String path, String password, KdfPreset preset) async {
    state = await Vault.create(path, password, preset);
  }

  Future<void> open(String path, String password) async {
    state = await Vault.open(path, password);
  }

  /// Lock the vault: drop the scene immediately, then close the handle (which
  /// drops key material on the Rust side).
  Future<void> close() async {
    final vault = state;
    state = null;
    if (vault != null) {
      try {
        await vault.close();
      } catch (_) {
        // Closing a dead handle is fine — we're leaving anyway.
      }
    }
  }
}

final vaultSessionProvider = NotifierProvider<VaultNotifier, Vault?>(
  VaultNotifier.new,
);