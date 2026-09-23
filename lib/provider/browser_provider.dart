// Riverpod state for the open-vault browser: the file listing, vault info
// snapshot, in-memory preview reads, and every mutating action (import /
// extract / rename / delete / save-as / compact / remirror). All actions
// dispatch through `Vault` (worker-isolate heavy ops) and then refresh the
// async providers so the UI re-reads the container.
//
// Folders are a UI-level concept (see `../ui/vault_model.dart`): they are
// derived from the `/` prefixes of stored names, and empty folders persist as
// hidden `.ackeep` marker entries. The current folder is plain per-session UI
// state (auto-disposed when the browser unmounts on lock).

import 'dart:io';
import 'dart:typed_data';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/format.dart';
import '../ui/vault_model.dart';
import 'file_provider.dart';
import 'session_provider.dart';

/// Preview a text file: first [previewCap] bytes (or the whole file when it
/// fits), plus whether the content was truncated.
class VaultPreview {
  const VaultPreview(this.bytes, this.truncated, this.fullSize);

  final Uint8List bytes;
  final bool truncated;

  /// The file's full size, for the "first N shown" size line in the dialog.
  final int fullSize;
}

const int previewCap = 1 << 20; // preview the first 1 MiB

Vault _watchSession(Ref ref) {
  final session = ref.watch(vaultSessionProvider);
  if (session == null) {
    throw StateError('no open vault session');
  }
  return session;
}

/// The folder shown by the browser; `''` = vault root. Scoped to the open
/// session: it auto-disposes when the browser is unmounted (vault locked), so
/// the next session starts at the root.
class CurrentFolderNotifier extends Notifier<String> {
  @override
  String build() => '';

  void go(String path) => state = path;
}

final currentVaultFolderProvider =
    NotifierProvider<CurrentFolderNotifier, String>(CurrentFolderNotifier.new);

/// The vault's plaintext file listing (name + size), re-read whenever the
/// session changes or after a mutation.
final vaultFilesProvider = FutureProvider<List<VaultFileInfo>>((ref) async {
  return _watchSession(ref).listFiles();
});

/// Aggregated engine + container statistics for the open vault.
final vaultInfoProvider = FutureProvider<VaultInfoModel>((ref) async {
  return _watchSession(ref).info();
});

/// In-memory read of a file for the preview dialog (whole file up to a
/// 1 MiB cap, first 1 MiB otherwise).
final vaultPreviewProvider = FutureProvider.autoDispose
    .family<VaultPreview, String>((ref, name) async {
      final session = _watchSession(ref);
      final files = await ref.watch(vaultFilesProvider.future);
      final file = files.firstWhere(
        (f) => f.name == name,
        orElse: () => throw NotFoundInVaultException(2, 'no such file: $name'),
      );
      final Uint8List content;
      if (file.size <= previewCap) {
        content = await session.readFile(name);
      } else {
        content = await session.readRange(name, offset: 0, len: previewCap);
      }
      return VaultPreview(content, file.size > previewCap, file.size);
    });

/// How many image bytes are read to build a browser grid/list thumbnail.
/// Files larger than this fall back to the generic file icon (the truncated
/// head usually won't decode).
const int imageThumbCap = 4 << 20;

/// A tiny bounded LRU of raw thumbnail bytes, keyed by stored name. The grid
/// shows many images at once and Riverpod's autoDispose would otherwise
/// re-read the engine on every scroll/rebuild; this keeps reads to once per
/// file while pinning memory (~16 MiB budget).
class ThumbnailByteCache {
  ThumbnailByteCache(this.budgetBytes);

  final int budgetBytes;
  final _entries = <String, Uint8List>{};
  int _used = 0;

  Uint8List? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value; // move to the recency tail
    return value;
  }

  void put(String key, Uint8List value) {
    final existing = _entries.remove(key);
    if (existing != null) _used -= existing.length;
    if (value.length > budgetBytes) return; // never cache oversized entries
    _entries[key] = value;
    _used += value.length;
    while (_used > budgetBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _used -= _entries.remove(oldest)!.length;
    }
  }
}

final thumbnailByteCacheProvider = Provider<ThumbnailByteCache>(
  (_) => ThumbnailByteCache(16 << 20),
);

/// Raw head bytes of an image-like file for grid/list thumbnails, cached by
/// stored name. Decoding happens in the widget (`Image.memory` with
/// `cacheWidth`), so corrupt or truncated heads simply fall back to the
/// generic file icon.
final vaultImageThumbProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, name) async {
      final cache = ref.read(thumbnailByteCacheProvider);
      final hit = cache.get(name);
      if (hit != null) return hit;
      final session = _watchSession(ref);
      final files = await ref.watch(vaultFilesProvider.future);
      final file = files.firstWhere(
        (f) => f.name == name,
        orElse: () => throw NotFoundInVaultException(2, 'no such file: $name'),
      );
      final Uint8List bytes;
      if (file.size <= imageThumbCap) {
        bytes = await session.readFile(name);
      } else {
        bytes = await session.readRange(name, offset: 0, len: imageThumbCap);
      }
      cache.put(name, bytes);
      return bytes;
    });

// Note: video frame capture was removed along with media_kit (see git history
// to resurrect it). Videos show a generic movie icon in the browser — nothing
// in the app decodes video content anymore.

/// List/grid display mode for the browser, persisted across restarts.
enum BrowserView { list, grid }

class BrowserViewNotifier extends AsyncNotifier<BrowserView> {
  @override
  Future<BrowserView> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('browser_grid') == true
        ? BrowserView.grid
        : BrowserView.list;
  }

  Future<void> select(BrowserView view) async {
    state = AsyncData(view);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('browser_grid', view == BrowserView.grid);
  }
}

final browserViewProvider =
    AsyncNotifierProvider<BrowserViewNotifier, BrowserView>(
      BrowserViewNotifier.new,
    );

/// Busy flag + transient user-facing notices for vault mutations.
class VaultActionsState {
  const VaultActionsState({this.busy = false, this.notice});

  final bool busy;
  final String? notice;

  VaultActionsState copyWith({bool? busy, String? notice}) =>
      VaultActionsState(busy: busy ?? this.busy, notice: notice ?? this.notice);
}

class VaultActionsNotifier extends Notifier<VaultActionsState> {
  @override
  VaultActionsState build() => const VaultActionsState();

  Vault? get _session => ref.read(vaultSessionProvider);

  void _setBusy(bool value) => state = state.copyWith(busy: value);
  void _notice(String message) => state = state.copyWith(notice: message);

  Future<void> _reload() async {
    ref.invalidate(vaultFilesProvider);
    ref.invalidate(vaultInfoProvider);
  }

  /// Join `segment` onto the current vault folder path (`''` = root).
  String _childName(String segment) {
    final dir = ref.read(currentVaultFolderProvider);
    return dir.isEmpty ? segment : '$dir/$segment';
  }

  Future<void> importFiles() async {
    if (state.busy) return;
    final picked = await ref.read(fileServiceProvider).pickImportFiles();
    if (picked.isEmpty) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final items = [
        for (final p in picked) (src: p, storedName: _childName(basenameOf(p))),
      ];
      final count = await session.addPaths(items);
      await _reload();
      _notice('Imported ${_plural(count, 'file')}.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Import every file of the picked folder plus the folder itself: stored
  /// names are prefixed with the folder's own name (e.g. `Photos/2024/1.jpg`),
  /// and empty subfolders are preserved as `.ackeep` markers.
  Future<void> importFolder() async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final root = Directory(dir.replaceAll(RegExp(r'[/\\]+$'), ''));
      final rootName = basenameOf(root.path);
      final items = <({String src, String storedName})>[];
      final markers = <String>[];

      void visit(Directory d, String rel) {
        // `rel` is the stored path of this directory including the root name.
        markers.add(_childName('$rel/$folderMarker'));
        for (final entity in d.listSync(followLinks: false)) {
          if (entity is Directory) {
            visit(entity, '$rel/${basenameOf(entity.path)}');
          } else if (entity is File) {
            items.add((
              src: entity.path,
              storedName: _childName('$rel/${basenameOf(entity.path)}'),
            ));
          }
        }
      }

      visit(root, rootName);

      var count = 0;
      if (items.isNotEmpty) {
        count = await session.addPaths(items);
      }
      // Markers are idempotent (overwrite in place), so re-importing a folder
      // never duplicates empty-directory entries.
      for (final m in markers) {
        await session.put(m, Uint8List(0));
      }
      await _reload();
      _notice(
        items.isEmpty
            ? 'Imported empty folder "$rootName".'
            : 'Imported ${_plural(count, 'file')} in "$rootName".',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Create an empty folder in the current vault folder via a hidden marker.
  Future<void> createFolder(String name) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.put(_childName('$name/$folderMarker'), Uint8List(0));
      await _reload();
      _notice('Created folder "$name".');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Rename `path` to `newName`, keeping it in the same parent: the marker and
  /// every stored name under the prefix are renamed.
  Future<void> renameFolder(String path, String newName) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final parent = parentOfPath(path);
      final newPath = parent.isEmpty ? newName : '$parent/$newName';
      final oldPrefix = '$path/';
      final affected = await _namesUnder(session, oldPrefix);
      if (affected.isEmpty) {
        _notice('Folder not found.');
        return;
      }
      for (final name in affected) {
        await session.rename(
          name,
          '$newPath/${name.substring(oldPrefix.length)}',
        );
      }
      await _reload();
      _notice('Renamed folder to "$newName".');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Delete `path` and everything inside it (files + marker entries).
  Future<void> deleteFolder(String path) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final affected = await _namesUnder(session, '$path/');
      if (affected.isEmpty) {
        _notice('Folder not found.');
        return;
      }
      for (final name in affected) {
        await session.delete(name);
      }
      await _reload();
      _notice(
        'Deleted folder "${basenameOf(path)}" '
        '(${_plural(affected.length, 'item')}).',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Extract every file of `path` into the picked directory, mirroring the
  /// stored hierarchy; the folder itself is created even when empty.
  Future<void> extractFolder(String path) async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final sep = Platform.pathSeparator;
      Directory('$dir$sep${path.replaceAll('/', sep)}')
          .createSync(recursive: true);
      final affected = await _namesUnder(session, '$path/');
      var count = 0;
      for (final name in affected) {
        if (isFolderMarker(name)) continue;
        final dest = '$dir$sep${name.replaceAll('/', sep)}';
        File(dest).parent.createSync(recursive: true);
        await session.extract(name, dest);
        count++;
      }
      await _reload();
      _notice(
        count == 0
            ? 'Extracted empty folder "${basenameOf(path)}" to $dir.'
            : 'Extracted ${_plural(count, 'item')} to $dir.',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// All stored names under `prefix` (marker entries included).
  Future<List<String>> _namesUnder(Vault session, String prefix) async {
    final files = await session.listFiles();
    return [
      for (final f in files)
        if (f.name.startsWith(prefix)) f.name,
    ];
  }

  Future<void> extract(VaultFileInfo file) async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final dest = '$dir${Platform.pathSeparator}${basenameOf(file.name)}';
      await session.extract(file.name, dest);
      _notice('Extracted to $dest');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> rename(String oldName, String newName) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.rename(oldName, newName);
      await _reload();
      _notice('Renamed to $newName.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> delete(String name) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.delete(name);
      await _reload();
      _notice('Deleted ${basenameOf(name)}.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> saveFileAs(String name, Uint8List bytes) async {
    final loc = await ref
        .read(fileServiceProvider)
        .saveFileAs(suggestedName: basenameOf(name), bytes: bytes);
    if (loc != null) _notice('Saved to $loc');
  }

  Future<void> compact() async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final before = (await ref.read(vaultInfoProvider.future)).garbageBytes;
      await session.compact();
      final _ = await ref.refresh(vaultInfoProvider.future);
      final after = ref.read(vaultInfoProvider).value?.garbageBytes ?? 0;
      final reclaimed = before - after;
      _notice(
        reclaimed > 0
            ? 'Compacted — reclaimed ${formatBytes(reclaimed)}.'
            : 'Vault is already compact.',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> remirror() async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.remirror();
      await _reload();
      _notice('Mirrors regenerated.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
}

final vaultActionsProvider =
    NotifierProvider<VaultActionsNotifier, VaultActionsState>(
      VaultActionsNotifier.new,
    );
