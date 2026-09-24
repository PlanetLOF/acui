// The open vault. `create`/`open` populate it; `close` scrubs it and returns
// the shell. It lives at app scope so the shell can switch scenes between the
// provider forms and the vault browser. Underneath, `Vault` runs long ops
// (Argon2id, folder imports, compact) on worker isolates.
//
// A session also records *where* the vault file lives, and — for cloud-backed
// sessions — the cloud origin it was downloaded from, so the browser can push
// changes back with rclone.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rclone_provider.dart';

/// The cloud origin of an open vault: the remote `remote:path` it came from
/// and the local cache file the engine works on. [stateAtOpen] is the remote
/// fingerprint when we downloaded it — the baseline for conflict detection.
class CloudOrigin {
  const CloudOrigin({
    required this.remotePath,
    required this.cachePath,
    this.stateAtOpen,
  });

  final String remotePath;
  final String cachePath;
  final RemoteState? stateAtOpen;
}

/// One open vault plus its provenance. [vault] holds the engine handle —
/// everything else is bookkeeping for local vs. cloud sync.
class VaultSession {
  const VaultSession({
    required this.vault,
    required this.localPath,
    this.cloud,
  });

  final Vault vault;
  final String localPath;
  final CloudOrigin? cloud;

  bool get isCloud => cloud != null;
}

class VaultNotifier extends Notifier<VaultSession?> {
  @override
  VaultSession? build() => null;

  Future<void> create(
    String path,
    String password,
    KdfPreset preset, {
    CloudOrigin? cloud,
  }) async {
    state = VaultSession(
      vault: await Vault.create(path, password, preset),
      localPath: path,
      cloud: cloud,
    );
  }

  Future<void> open(String path, String password, {CloudOrigin? cloud}) async {
    state = VaultSession(
      vault: await Vault.open(path, password),
      localPath: path,
      cloud: cloud,
    );
  }

  /// Adopt an already-created vault (the cloud create flow creates locally,
  /// uploads, then hands the live handle over).
  void adopt(Vault vault, String localPath, {CloudOrigin? cloud}) {
    state = VaultSession(vault: vault, localPath: localPath, cloud: cloud);
  }

  /// Lock the vault: drop the scene immediately, then close the handle (which
  /// drops key material on the Rust side). Cloud upload decisions happen
  /// *before* this is called (see `CloudSyncNotifier`).
  Future<void> close() async {
    final session = state;
    state = null;
    if (session != null) {
      try {
        await session.vault.close();
      } catch (_) {
        // Closing a dead handle is fine — we're leaving anyway.
      }
    }
  }
}

final vaultSessionProvider = NotifierProvider<VaultNotifier, VaultSession?>(
  VaultNotifier.new,
);
