// Cloud browser state: which remote + remote folder is being browsed, the
// entries under it, and the operations that transfer vaults to/from the cloud
// (open, save-as, create). Transfer itself is `RcloneService`; opening a
// vault works on a local cache copy (the engine needs a real filesystem
// path), and [CloudOrigin] records the remote path so changes sync back.

import 'dart:io';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_provider.dart';
import 'rclone_provider.dart';
import 'session_provider.dart';

class CloudBrowserState {
  const CloudBrowserState({
    this.selectedRemote,
    this.dir = '',
    this.busy = false,
    this.revision = 0,
    this.notice,
  });

  /// The chosen rclone remote name (`null` until one is picked).
  final String? selectedRemote;

  /// Current remote folder, `''` = root, `'/'`-separated.
  final String dir;

  final bool busy;

  /// Bumped on remote/path changes so the UI rebuilds around widgets that
  /// cache state by key.
  final int revision;

  /// Transient user-facing message (surfaced as a snackbar by the screen).
  final String? notice;

  CloudBrowserState copyWith({
    String? selectedRemote,
    String? dir,
    bool? busy,
    int? revision,
    String? notice,
  }) => CloudBrowserState(
    selectedRemote: selectedRemote ?? this.selectedRemote,
    dir: dir ?? this.dir,
    busy: busy ?? this.busy,
    revision: revision ?? this.revision,
    notice: notice ?? this.notice,
  );
}

class CloudBrowserNotifier extends Notifier<CloudBrowserState> {
  @override
  CloudBrowserState build() => const CloudBrowserState();

  void _notice(String message) => state = state.copyWith(notice: message);

  /// The remote the UI is acting on: the user's explicit selection when one
  /// exists, otherwise the first configured remote (the dropdown shows it pre-
  /// selected, so every action uses the same effective value).
  String? get effectiveRemote {
    final chosen = state.selectedRemote;
    final known = ref.read(cloudRemotesProvider).value;
    if (known != null && known.isNotEmpty) {
      if (chosen != null && known.any((r) => r.name == chosen)) return chosen;
      return known.first.name;
    }
    return chosen;
  }

  /// `remote:/dir` form of the current location, or `null` when no remote
  /// exists yet.
  String? get currentRemotePath {
    final remote = effectiveRemote;
    if (remote == null) return null;
    return remotePathOf(remote, [state.dir]);
  }

  void selectRemote(String? name) {
    state = state.copyWith(selectedRemote: name, dir: '', notice: null);
    ref.invalidate(cloudEntriesProvider);
  }

  void enterDir(String path) {
    state = state.copyWith(dir: path, notice: null);
    ref.invalidate(cloudEntriesProvider);
  }

  void up() {
    final dir = state.dir;
    if (dir.isEmpty) return;
    final i = dir.lastIndexOf('/');
    enterDir(i == -1 ? '' : dir.substring(0, i));
  }

  /// Re-list the current location; also re-reads the remote list (a new
  /// remote may have been added by the config wizard).
  void refresh() {
    ref.invalidate(cloudEntriesProvider);
    ref.invalidate(cloudRemotesProvider);
  }

  Future<void> newRemote() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref.read(rcloneServiceProvider).launchRcloneConfig();
      _notice(
        'rclone config opened in a terminal — create your remote there, '
        'close the window, then tap REFRESH.',
      );
    } catch (e) {
      _notice('Could not open rclone config: $e');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Where downloaded vaults land: the user's `cloud_cache_dir` override,
  /// or the app default (`<home>/acui`).
  Future<String> _resolveCacheRoot() async {
    final custom =
        (await ref.read(cloudCacheDirProvider.future))?.trim() ?? '';
    return custom.isEmpty ? defaultCloudCacheRoot() : custom;
  }

  /// The local cache file `entry` will be downloaded to.
  Future<String> cachePathFor(RcloneEntry entry) async {
    final remote = effectiveRemote;
    if (remote == null) throw StateError('no cloud remote selected');
    final root = await _resolveCacheRoot();
    return _cacheFilePath(root, remote, state.dir, entry.name);
  }

  /// Download `entry` to its cache path and return the local file.
  Future<String> downloadToCache(RcloneEntry entry) async {
    final remote = effectiveRemote;
    if (remote == null) throw StateError('no cloud remote selected');
    final remotePath = remotePathOf(remote, [state.dir, entry.name]);
    final cachePath = await cachePathFor(entry);
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref.read(rcloneServiceProvider).download(remotePath, cachePath);
      return cachePath;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Download `entry` directly to a user-chosen local location (Save as…).
  Future<void> saveAs(RcloneEntry entry) async {
    if (state.busy || entry.isDir) return;
    final loc = await ref.read(fileServiceProvider).saveVaultAs(entry.name);
    if (loc == null) return;
    final remote = effectiveRemote;
    if (remote == null) return;
    final remotePath = remotePathOf(remote, [state.dir, entry.name]);
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref.read(rcloneServiceProvider).download(remotePath, loc);
      _notice('Saved to $loc');
    } catch (e) {
      _notice('Download failed: $e');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Delete one remote vault file from the cloud.
  Future<void> deleteRemoteFile(RcloneEntry entry) async {
    if (state.busy || entry.isDir) return;
    final remote = effectiveRemote;
    if (remote == null) return;
    final remotePath = remotePathOf(remote, [state.dir, entry.name]);
    state = state.copyWith(busy: true, notice: null);
    try {
      await ref.read(rcloneServiceProvider).deleteFile(remotePath);
      ref.invalidate(cloudEntriesProvider);
      _notice('Deleted ${entry.name} from $remote.');
    } catch (e) {
      _notice('Delete failed: $e');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  /// Create a vault directly in the current remote folder: create the file in
  /// the local cache, upload it, then open it as a cloud session.
  Future<void> createVaultInCloud({
    required String name,
    required String password,
    required KdfPreset preset,
  }) async {
    final remote = effectiveRemote;
    if (remote == null) return;
    var fileName = name.trim();
    if (!fileName.toLowerCase().endsWith('.ac')) fileName += '.ac';

    final root = await _resolveCacheRoot();
    final cachePath = _cacheFilePath(root, remote, state.dir, fileName);
    final remotePath = remotePathOf(remote, [state.dir, fileName]);

    state = state.copyWith(busy: true, notice: null);
    try {
      final vault = await Vault.create(cachePath, password, preset);
      try {
        final service = ref.read(rcloneServiceProvider);
        if (state.dir.isNotEmpty) {
          await service.mkdir(remotePathOf(remote, [state.dir]));
        }
        await service.upload(cachePath, remotePath);
        final after = await service.findRemoteEntry(remotePath);
        ref
            .read(vaultSessionProvider.notifier)
            .adopt(
              vault,
              cachePath,
              cloud: CloudOrigin(
                remotePath: remotePath,
                cachePath: cachePath,
                stateAtOpen: after == null
                    ? null
                    : RemoteState(after.size, after.modTime),
              ),
            );
        // Success: the shell switches to the vault browser.
      } catch (e) {
        await vault.close();
        rethrow;
      }
    } on AutocipherException catch (e) {
      _notice(e.message);
    } on RcloneException catch (e) {
      _notice('Upload failed: ${e.message}');
    } catch (e) {
      _notice('$e');
    } finally {
      state = state.copyWith(busy: false);
    }
  }
}

final cloudBrowserProvider =
    NotifierProvider<CloudBrowserNotifier, CloudBrowserState>(
      CloudBrowserNotifier.new,
    );

/// The entries under the selected remote + folder. When nothing is selected
/// yet, the first configured remote is used (matching what the dropdown
/// shows), so the folder lists as soon as remotes load.
final cloudEntriesProvider = FutureProvider<List<RcloneEntry>>((ref) {
  final state = ref.watch(cloudBrowserProvider);
  final remotes = ref.watch(cloudRemotesProvider);
  final chosen = state.selectedRemote;
  String? remote;
  final known = remotes.value;
  if (known != null && known.isNotEmpty) {
    remote = chosen != null && known.any((r) => r.name == chosen)
        ? chosen
        : known.first.name;
  } else {
    remote = chosen;
  }
  if (remote == null) return const [];
  return ref
      .watch(rcloneServiceProvider)
      .listDir(remotePathOf(remote, [state.dir]));
});

// ---- cache layout ----------------------------------------------------------

/// The default cloud-vault cache root: `<home>/acui` on every platform —
/// `C:\Users\<name>\acui` on Windows, `/Users/<name>/acui` on macOS,
/// `/home/<name>/acui` on Linux. Falls back to the system temp dir when no
/// home directory is available.
String defaultCloudCacheRoot() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.systemTemp.path;
  return '$home${Platform.pathSeparator}acui';
}

String _sanitizeSegment(String s) =>
    s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

/// Local mirror of a remote vault under `root`:
/// `root\<remote>\<dir>\<file>`.
String _cacheFilePath(String root, String remote, String dir, String name) {
  final segments = [
    for (final s in [remote, ...dir.split('/'), name]) _sanitizeSegment(s),
  ];
  return '$root${Platform.pathSeparator}'
      '${segments.join(Platform.pathSeparator)}';
}

// ---- user-chosen cloud cache folder ---------------------------------------

/// Absolute-path check without the `path` package: drive-letter or UNC paths
/// on Windows, rooted paths elsewhere.
bool _isAbsolutePath(String p) {
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p) || p.startsWith('\\\\');
  }
  return p.startsWith('/');
}

/// The user's cloud-cache folder override under SharedPreferences key
/// `cloud_cache_dir` (`null` = the app default).
class CloudCacheDirNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('cloud_cache_dir');
  }

  /// Validate + persist the new cache folder. Empty clears the override back
  /// to the default. Returns `false` (leaving state untouched) when the path
  /// is relative or cannot be created.
  Future<bool> setDir(String? path) async {
    final p = path?.trim() ?? '';
    if (p.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('cloud_cache_dir');
      state = const AsyncData(null);
      return true;
    }
    if (!_isAbsolutePath(p)) return false;
    try {
      await Directory(p).create(recursive: true);
    } catch (_) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cloud_cache_dir', p);
    state = AsyncData(p);
    return true;
  }
}

final cloudCacheDirProvider =
    AsyncNotifierProvider<CloudCacheDirNotifier, String?>(
      CloudCacheDirNotifier.new,
    );
