// Sync state for a cloud-backed vault session: debounced auto-upload after
// mutations, manual SYNC NOW, and the conflict guard (remote changed since we
// opened it → never silently overwrite). Lifecycle:
//
//   open/download  → baseline = remote fingerprint at open
//   mutation       → schedule() sets `dirty` and starts a 2 s debounce timer
//   timer fires    → syncNow(): stat remote, compare to baseline, upload only
//                    if unchanged; otherwise surface a conflict for the user.
//   successful     → baseline refreshed to the just-uploaded fingerprint.
//
// Conflict resolution (Overwrite / Reload) is also here; "Save local copy"
// is pure file I/O and lives in the banner widget.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rclone_provider.dart';
import 'session_provider.dart';

const Duration autoSyncDebounce = Duration(seconds: 2);

class CloudSyncState {
  const CloudSyncState({
    this.busy = false,
    this.dirty = false,
    this.conflict = false,
    this.lastSync,
    this.notice,
  });

  final bool busy;

  /// Edits happened locally and have not been uploaded yet.
  final bool dirty;

  /// The remote changed since the baseline — uploading would clobber it.
  final bool conflict;

  final DateTime? lastSync;

  /// Transient user-facing message (surfaced as a snackbar by listeners).
  final String? notice;

  CloudSyncState copyWith({
    bool? busy,
    bool? dirty,
    bool? conflict,
    DateTime? lastSync,
    String? notice,
  }) => CloudSyncState(
    busy: busy ?? this.busy,
    dirty: dirty ?? this.dirty,
    conflict: conflict ?? this.conflict,
    lastSync: lastSync ?? this.lastSync,
    notice: notice ?? this.notice,
  );
}

class CloudSyncNotifier extends Notifier<CloudSyncState> {
  Timer? _debounce;

  /// The remote fingerprint of the last state we uploaded (or opened), keyed
  /// by remote path so switching vaults never compares stale baselines.
  RemoteState? _baseline;
  String? _baselineKey;

  @override
  CloudSyncState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const CloudSyncState();
  }

  CloudOrigin? get _origin => ref.read(vaultSessionProvider)?.cloud;

  /// Reset the conflict/dirty flags after opening a cloud vault.
  void reset(CloudOrigin origin) {
    _debounce?.cancel();
    _baseline = origin.stateAtOpen;
    _baselineKey = origin.remotePath;
    state = const CloudSyncState();
  }

  /// Debounced auto-sync: called after every successful vault mutation.
  void schedule() {
    final origin = _origin;
    if (origin == null) return;
    _debounce?.cancel();
    state = state.copyWith(dirty: true, conflict: false, notice: null);
    _debounce = Timer(autoSyncDebounce, syncNow);
  }

  /// Upload the local vault to its cloud origin.
  ///
  /// Returns `null` when the upload happened. On a conflict (or any failure)
  /// it leaves the session untouched, sets the conflict/busy flags + a notice,
  /// and returns a user-facing reason for the failure.
  Future<String?> syncNow({bool force = false}) async {
    final origin = _origin;
    final session = ref.read(vaultSessionProvider);
    if (origin == null || session == null) return 'No cloud session is open.';
    if (state.busy) return 'A sync is already running.';
    state = state.copyWith(busy: true, notice: null);
    try {
      final service = ref.read(rcloneServiceProvider);

      if (!force) {
        final remote = await service.findRemoteEntry(origin.remotePath);
        if (remote != null) {
          final baseline = _baselineKey == origin.remotePath
              ? _baseline
              : origin.stateAtOpen;
          final now = RemoteState(remote.size, remote.modTime);
          // A real conflict is the remote's *size* moving — different bytes
          // were written since we opened it. Modtime-only churn at an
          // identical size is Terabox re-touching metadata around an upload
          // (its modtime lags and drifts), so it is adopted, not blocked.
          // Trade-off: a same-size edit by another device would slip through;
          // on this backend the modtime is too unstable to be a reliable
          // conflict signal, so size is the guard.
          if (baseline != null && now.size != baseline.size) {
            state = const CloudSyncState(
              conflict: true,
              dirty: true,
              notice:
                  'The cloud copy changed since you opened it — resolve '
                  'the conflict before syncing.',
            );
            return 'the cloud copy changed since you opened it — resolve '
                'the conflict on the sync banner';
          }
          if (baseline != null && now.modTime != baseline.modTime) {
            _baseline = now;
          }
        }
      }

      await service.upload(session.localPath, origin.remotePath);
      final after = await service.findRemoteEntry(origin.remotePath);
      _baseline = after == null ? null : RemoteState(after.size, after.modTime);
      _baselineKey = origin.remotePath;
      state = CloudSyncState(
        lastSync: DateTime.now(),
        notice: 'Synced to ${origin.remotePath}',
      );
      return null;
    } on RcloneException catch (e) {
      _fail('Sync failed: ${e.message}');
      return e.message;
    } catch (e) {
      _fail('Sync failed: $e');
      return '$e';
    }
  }

  /// Conflict resolution: upload our local version over the remote anyway.
  Future<String?> overwriteRemote() => syncNow(force: true);

  /// Like [syncNow], but first waits for any in-flight auto-sync to settle
  /// (bounded ~60 s), so an explicit "Upload & lock" never fails just because
  /// the debounced auto-upload is still running.
  Future<String?> syncWhenIdle() async {
    for (var i = 0; ref.read(cloudSyncProvider).busy && i < 120; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return syncNow();
  }

  /// Conflict resolution: discard local edits, re-download the remote over
  /// the cache, and close the session (the scene returns to the shell). The
  /// download keeps running after the switch.
  Future<void> reloadFromRemote() async {
    final origin = _origin;
    if (origin == null) return;
    final notifier = ref.read(vaultSessionProvider.notifier);
    state = state.copyWith(busy: true, notice: null);
    try {
      await notifier.close(); // drop the scene + engine handle first
      await ref
          .read(rcloneServiceProvider)
          .download(origin.remotePath, origin.cachePath);
      state = const CloudSyncState(
        notice: 'Downloaded the remote copy; local edits were discarded.',
      );
    } on RcloneException catch (e) {
      _fail('Reload failed: ${e.message}');
    } catch (e) {
      _fail('Reload failed: $e');
    }
  }

  void _fail(String message) {
    state = state.copyWith(busy: false, notice: message);
  }
}

final cloudSyncProvider = NotifierProvider<CloudSyncNotifier, CloudSyncState>(
  CloudSyncNotifier.new,
);
