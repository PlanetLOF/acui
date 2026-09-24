// Per-vault cache pinning: how a cloud vault uses the local cache, in the
// spirit of Dropbox "smart sync".
//
// Two modes per remote vault:
//  - `onlineOnly` (the default): the vault uses no disk space. Opening
//    downloads it to the cache and locking purges the cache again; opening
//    always requires the network.
//  - `offline`: the cache copy is kept on disk and can be opened without the
//    network; edits are written to the cache, and the whole-file `.ac`
//    upload happens on the next connection.
//
// The pin record also carries the last-known remote fingerprint (size +
// modtime) so the conflict guard keeps working when a vault is opened from
// cache without a fresh listing.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether a cloud vault keeps a local cache copy.
enum CloudPinMode {
  /// Dropbox "online only": no disk footprint; opening needs the network and
  /// the cache is purged on lock.
  onlineOnly,

  /// Dropbox "available offline": the cache copy is kept and opened without
  /// the network; edits queue and upload when back online.
  offline,
}

/// The persistent pin + last-known remote fingerprint for one remote vault.
class VaultPin {
  const VaultPin({required this.mode, this.lastSize, this.lastModTime});

  /// Whether the vault keeps a local cache copy.
  final CloudPinMode mode;

  /// Remote size at the last successful upload/download (conflict baseline
  /// when the vault is opened from cache without a fresh listing).
  final int? lastSize;

  /// Remote modtime at the last successful upload/download (same role).
  final String? lastModTime;
}

class CloudPinNotifier extends AsyncNotifier<Map<String, VaultPin>> {
  static const _keyPrefix = 'cloud_pin_';

  @override
  Future<Map<String, VaultPin>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final pins = <String, VaultPin>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      final remotePath = key.substring(_keyPrefix.length);
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        pins[remotePath] = VaultPin(
          mode: CloudPinMode.values.asNameMap()[map['mode']] ??
              CloudPinMode.onlineOnly,
          lastSize: (map['size'] as num?)?.toInt(),
          lastModTime: map['mod'] as String?,
        );
      } catch (_) {
        // Corrupt record — treat as unpinned.
      }
    }
    return pins;
  }

  Map<String, VaultPin> _current() => state.value ?? const {};

  /// The pin for [remotePath]; unpinned vaults default to
  /// [CloudPinMode.onlineOnly].
  Future<VaultPin> pinFor(String remotePath) async {
    final pins = await future;
    return pins[remotePath] ?? const VaultPin(mode: CloudPinMode.onlineOnly);
  }

  /// Flip the mode (offline ⇄ online-only) for [remotePath]. The stored
  /// fingerprint is kept — the remote itself did not change.
  Future<void> setMode(String remotePath, CloudPinMode mode) async {
    final pins = await future;
    final existing = pins[remotePath];
    await _put(
      remotePath,
      VaultPin(
        mode: mode,
        lastSize: existing?.lastSize,
        lastModTime: existing?.lastModTime,
      ),
    );
  }

  /// Record a successful sync: refresh the stored fingerprint but never the
  /// mode (uploads happen in both modes).
  Future<void> recordSync(
    String remotePath,
    int size,
    String? modTime,
  ) async {
    final pins = await future;
    final existing = pins[remotePath];
    await _put(
      remotePath,
      VaultPin(
        mode: existing?.mode ?? CloudPinMode.onlineOnly,
        lastSize: size,
        lastModTime: modTime,
      ),
    );
  }

  Future<void> _put(String remotePath, VaultPin pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_keyPrefix$remotePath',
      jsonEncode({
        'mode': pin.mode.name,
        'size': pin.lastSize,
        'mod': pin.lastModTime,
      }),
    );
    state = AsyncData({..._current(), remotePath: pin});
  }
}

final cloudPinProvider =
    AsyncNotifierProvider<CloudPinNotifier, Map<String, VaultPin>>(
      CloudPinNotifier.new,
    );