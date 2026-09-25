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

/// The vault's plaintext file listing and metadata, re-read whenever the
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

/// Persistent sort criterion and direction for the vault browser.
class BrowserSortNotifier extends AsyncNotifier<VaultSortSettings> {
  static const _criterionKey = 'browser_sort_criterion';
  static const _descendingKey = 'browser_sort_descending';

  @override
  Future<VaultSortSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_criterionKey);
    final criterion =
        index != null && index >= 0 && index < VaultSort.values.length
        ? VaultSort.values[index]
        : VaultSort.name;
    return VaultSortSettings(
      criterion: criterion,
      descending:
          prefs.getBool(_descendingKey) ?? (criterion != VaultSort.name),
    );
  }

  Future<void> selectSettings(VaultSortSettings value) async {
    state = AsyncData(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_criterionKey, value.criterion.index);
    await prefs.setBool(_descendingKey, value.descending);
  }

  /// Choose a criterion with its conventional default direction.
  Future<void> selectCriterion(VaultSort criterion) => selectSettings(
    VaultSortSettings(
      criterion: criterion,
      descending: switch (criterion) {
        VaultSort.name => false,
        VaultSort.modified || VaultSort.size => true,
      },
    ),
  );
}

final browserSortProvider =
    AsyncNotifierProvider<BrowserSortNotifier, VaultSortSettings>(
      BrowserSortNotifier.new,
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
    await importPaths(picked);
  }

  /// Import every file of the picked folder plus the folder itself: stored
  /// names are prefixed with the folder's own name (e.g. `Photos/2024/1.jpg`),
  /// and empty subfolders are preserved as `.ackeep` markers.
  Future<void> importFolder() async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    await importPaths([dir]);
  }

  /// Import the given host paths into the current vault folder in one busy
  /// window — the shared path behind the Import files… / Import folder…
  /// dialogs and the drag-and-drop zone, so the gestures can never drift.
  ///
  /// Files are stored under their own basename in the current folder.
  /// Directories are walked recursively: stored names get the folder's own
  /// name as prefix (e.g. a dropped `Photos` lands as `Photos/2024/1.jpg`)
  /// and empty subfolders are preserved as `.ackeep` markers.
  Future<void> importPaths(List<String> paths) async {
    if (state.busy) return;
    final cleaned = [
      for (final p in paths)
        if (p.trim().isNotEmpty) p.trim(),
    ];
    if (cleaned.isEmpty) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final items = <({String src, String storedName})>[];
      final markers = <String>[];
      final skippedReserved = <String>{};

      for (final p in cleaned) {
        final type = FileSystemEntity.typeSync(p, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          final root = Directory(p.replaceAll(RegExp(r'[/\\]+$'), ''));
          final rootName = basenameOf(root.path);
          if (containsReservedPathSegment(rootName)) {
            skippedReserved.add(rootName);
            continue;
          }

          void visit(Directory d, String rel) {
            // `rel` is the stored path of this directory including the root
            // name; `_childName` joins it under the current vault folder. Check
            // the complete stored path too: legacy data can put the user in a
            // folder whose own path contains `.ackeep`.
            final storedDir = _childName(rel);
            if (containsReservedPathSegment(storedDir)) {
              skippedReserved.add(storedDir);
              return;
            }
            markers.add('$storedDir/$folderMarker');
            for (final entity in d.listSync(followLinks: false)) {
              if (entity is Directory) {
                final childRel = '$rel/${basenameOf(entity.path)}';
                if (containsReservedPathSegment(childRel)) {
                  skippedReserved.add(childRel);
                } else {
                  visit(entity, childRel);
                }
              } else if (entity is File) {
                final storedName = _childName(
                  '$rel/${basenameOf(entity.path)}',
                );
                if (containsReservedPathSegment(storedName)) {
                  skippedReserved.add(storedName);
                } else {
                  items.add((src: entity.path, storedName: storedName));
                }
              }
            }
          }

          visit(root, rootName);
        } else if (type == FileSystemEntityType.file) {
          final storedName = _childName(basenameOf(p));
          if (containsReservedPathSegment(storedName)) {
            skippedReserved.add(storedName);
          } else {
            items.add((src: p, storedName: storedName));
          }
        }
      }

      // Preflight all stored-name namespaces before importing any bytes. A
      // marker must not be written beside a legacy file at its folder root (or
      // beneath a file that already occupies the marker path), and a plain
      // file must not create the same ambiguous file/folder pair. The indexes
      // keep this linear in the number of paths rather than rescanning the
      // complete vault listing for every incoming name.
      final existing = {for (final f in await session.listFiles()) f.name};
      final existingIndex = StoredPathIndex(existing);

      // Directory traversal can encounter the same marker more than once when
      // the host selection overlaps. De-duplicate it and reject any malformed
      // marker/ancestor collision before considering the rest of the import.
      final markerPaths = <String>[];
      final markerPathIndex = StoredPathIndex();
      for (final marker in markers) {
        if (markerPathIndex.contains(marker)) continue;
        if (markerPathIndex.conflictsWith(marker)) {
          skippedReserved.add(marker);
          continue;
        }
        markerPathIndex.add(marker);
        markerPaths.add(marker);
      }

      final acceptedItems = <({String src, String storedName})>[];
      final incomingIndex = StoredPathIndex();
      for (final item in items) {
        final name = item.storedName;
        final exactExisting = existingIndex.contains(name);
        final canOverwriteExistingFile =
            exactExisting &&
            !existingIndex.hasDescendant(name) &&
            !existingIndex.hasAncestor(name);
        if ((existingIndex.conflictsWith(name) && !canOverwriteExistingFile) ||
            incomingIndex.conflictsWith(name) ||
            markerPathIndex.conflictsWith(name)) {
          skippedReserved.add(name);
          continue;
        }
        acceptedItems.add(item);
        incomingIndex.add(name);
      }

      final acceptedMarkers = <String>[];
      final markersToWrite = <String>[];
      for (final marker in markerPaths) {
        // An already-present marker is idempotent; do not report it as a
        // skipped name. Any other namespace collision is preserved, not
        // overwritten.
        if (existingIndex.contains(marker)) {
          acceptedMarkers.add(marker);
          continue;
        }
        if (existingIndex.conflictsWith(marker) ||
            incomingIndex.conflictsWith(marker)) {
          skippedReserved.add(marker);
          continue;
        }
        acceptedMarkers.add(marker);
        markersToWrite.add(marker);
      }

      var count = 0;
      if (acceptedItems.isNotEmpty) {
        count = await session.addPaths(acceptedItems);
      }
      for (final marker in markersToWrite) {
        await session.put(marker, Uint8List(0));
      }
      final markerCount = acceptedMarkers.length;
      await _reload();
      final skippedText = skippedReserved.isEmpty
          ? ''
          : ' Skipped ${skippedReserved.length} reserved or conflicting '
                'name${skippedReserved.length == 1 ? '' : 's'}: '
                '${skippedReserved.take(3).join(', ')}'
                '${skippedReserved.length > 3 ? ', ...' : ''}.';
      if (acceptedItems.isEmpty && markerCount == 0) {
        if (skippedReserved.isEmpty) {
          _notice('No files or folders to import in the selection.');
        } else {
          _notice('Nothing imported.$skippedText');
        }
      } else if (acceptedItems.isEmpty) {
        _notice('Imported an empty folder.$skippedText');
      } else {
        _notice('Imported ${_plural(count, 'file')}.$skippedText');
      }
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Create an empty folder in the current vault folder via a hidden marker.
  /// Returns whether the marker was written and the listing reloaded.
  Future<bool> createFolder(String name) async {
    if (state.busy) return false;
    if (!isValidFolderName(name)) {
      _notice('Invalid folder name.');
      return false;
    }
    final session = _session;
    if (session == null) return false;
    final folderPath = _childName(name);
    if (containsReservedPathSegment(folderPath)) {
      _notice('The name ".ackeep" is reserved for folder markers.');
      return false;
    }
    _setBusy(true);
    try {
      final marker = '$folderPath/$folderMarker';
      final existing = {for (final f in await session.listFiles()) f.name};
      final conflicts = existing.any(
        (stored) => storedPathsConflict(stored, folderPath),
      );
      if (conflicts) {
        _notice('A file or folder named "$name" already exists here.');
        return false;
      }
      await session.put(marker, Uint8List(0));
      await _reload();
      _notice('Created folder "$name".');
      return true;
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Rename `path` to `newName`, keeping it in the same parent: the marker and
  /// every stored name under the prefix are renamed.
  Future<void> renameFolder(String path, String newName) async {
    if (state.busy) return;
    if (!isValidFolderName(newName)) {
      _notice('Invalid folder name.');
      return;
    }
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final parent = parentOfPath(path);
      final newPath = parent.isEmpty ? newName : '$parent/$newName';
      if (newPath == path) {
        _notice('Folder name is unchanged.');
        return;
      }
      if (containsReservedPathSegment(newPath)) {
        _notice('The name ".ackeep" is reserved for folder markers.');
        return;
      }

      final oldPrefix = '$path/';
      final existing = {for (final f in await session.listFiles()) f.name};
      final affected = existing
          .where((name) => name.startsWith(oldPrefix))
          .toList();
      if (affected.isEmpty) {
        _notice('Folder not found.');
        return;
      }

      final renames = <({String oldName, String newName})>[];
      for (final name in affected) {
        final next = '$newPath/${name.substring(oldPrefix.length)}';
        if (!isFolderMarker(name) && containsReservedPathSegment(next)) {
          _notice('The name ".ackeep" is reserved for folder markers.');
          return;
        }
        renames.add((oldName: name, newName: next));
      }

      // Every planned leaf is below `newPath`, so a non-moving name that
      // conflicts with any leaf also conflicts with the destination root.
      // Checking the root once avoids an O(files × existing-names) preflight
      // while retaining the same namespace guarantee. This also catches a
      // legacy user file at `<new>/.ackeep`.
      for (final name in existing) {
        if (name.startsWith(oldPrefix)) continue;
        if (storedPathsConflict(name, newPath)) {
          _notice('A file or folder named "$newName" already exists here.');
          return;
        }
      }

      for (final rename in renames) {
        await session.rename(rename.oldName, rename.newName);
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

  /// Expand a selection of stored names + folder paths into the full set of
  /// stored names the action should touch (folders contribute every
  /// descendant, marker entries included; plain files pass through).
  Future<List<String>> _expandSelection(
    Vault session,
    List<String> fileNames,
    List<String> folderPaths,
  ) async {
    final names = <String>{...fileNames};
    for (final folder in folderPaths) {
      names.addAll(await _namesUnder(session, '$folder/'));
    }
    return names.toList();
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
    if (oldName == newName) return;
    if (newName.isEmpty) {
      _notice('Invalid file name.');
      return;
    }
    if (containsReservedPathSegment(newName) && !isFolderMarker(oldName)) {
      _notice('The name ".ackeep" is reserved for folder markers.');
      return;
    }
    _setBusy(true);
    try {
      final existing = {for (final f in await session.listFiles()) f.name};
      final conflict = existing.any(
        (name) => name != oldName && storedPathsConflict(name, newName),
      );
      if (conflict) {
        _notice('A file or folder named "$newName" already exists.');
        return;
      }
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

  /// Relocate files and folders (with their whole subtree) into `destPath`
  /// (`''` = vault root). Implemented as stored-name renames that rewrite the
  /// folder prefix, so file ids / chunk bindings are preserved — a move is a
  /// rename within the vault, never a re-encrypt.
  ///
  /// No-op and impossible destinations are rejected up front, and destination
  /// collisions are validated before any rename so a conflict aborts the whole
  /// move without partially moving it.
  Future<bool> moveEntries({
    required List<String> fileNames,
    required List<String> folderPaths,
    required String destPath,
  }) async {
    if (state.busy) return false;
    if (fileNames.isEmpty && folderPaths.isEmpty) return false;
    if (!canMoveEntries(
      fileNames: fileNames,
      folderPaths: folderPaths,
      destPath: destPath,
    )) {
      final alreadyInDestination =
          fileNames.any((name) => parentOfPath(name) == destPath) ||
          folderPaths.any((name) => parentOfPath(name) == destPath);
      if (alreadyInDestination) {
        final target = destPath.isEmpty ? 'the vault root' : '"$destPath"';
        _notice('Cannot move an item that is already in $target.');
      } else {
        _notice(
          'Cannot move overlapping entries, an item into itself or a descendant, '
          'or anything through the reserved folder-marker namespace.',
        );
      }
      return false;
    }
    final session = _session;
    if (session == null) return false;
    _setBusy(true);
    try {
      final renames = <({String oldName, String newName})>[];
      for (final name in fileNames) {
        final rel = basenameOf(name);
        final dest = destPath.isEmpty ? rel : '$destPath/$rel';
        if (dest == name) continue; // already there
        renames.add((oldName: name, newName: dest));
      }
      for (final folder in folderPaths) {
        final folderName = basenameOf(folder);
        final oldPrefix = '$folder/';
        for (final name in await _namesUnder(session, oldPrefix)) {
          final rest = name.substring(oldPrefix.length);
          final dest = destPath.isEmpty
              ? '$folderName/$rest'
              : '$destPath/$folderName/$rest';
          if (dest == name) continue;
          renames.add((oldName: name, newName: dest));
        }
      }
      if (renames.isEmpty) {
        _notice('Nothing to move.');
        return false;
      }
      // Every planned leaf must be free. A name that is being moved away no
      // longer counts as occupied in the existing listing, but it is still
      // checked against every destination so sequential renames cannot depend
      // on ordering. Checking all leaves also catches duplicate and nested
      // destinations that a set of top-level roots would collapse.
      final existing = {for (final f in await session.listFiles()) f.name};
      final movedNames = {for (final r in renames) r.oldName};
      final destinationRoots = <String>[];
      for (final name in fileNames) {
        final rel = basenameOf(name);
        destinationRoots.add(destPath.isEmpty ? rel : '$destPath/$rel');
      }
      for (final folder in folderPaths) {
        final rel = basenameOf(folder);
        destinationRoots.add(destPath.isEmpty ? rel : '$destPath/$rel');
      }
      final conflict = moveDestinationConflict(
        existingNames: existing,
        movedNames: movedNames,
        plannedNames: renames.map((rename) => rename.newName),
      );
      String? conflictRoot;
      if (conflict != null) {
        // Report the user-facing top-level destination rather than a marker or
        // nested leaf when the conflict is inside a moved folder.
        for (final root in destinationRoots) {
          if (storedPathsConflict(root, conflict)) {
            conflictRoot = root;
            break;
          }
        }
        conflictRoot ??= conflict;
      }
      if (conflictRoot != null) {
        final target = destPath.isEmpty ? 'vault root' : destPath;
        _notice(
          'Cannot move "${basenameOf(conflictRoot)}": a file or folder named '
          '"${basenameOf(conflictRoot)}" already exists in $target.',
        );
        return false;
      }
      for (final r in renames) {
        await session.rename(r.oldName, r.newName);
      }
      await _reload();
      _notice(
        'Moved ${_plural(fileNames.length + folderPaths.length, 'item')}.',
      );
      return true;
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Delete multiple files and whole folder trees in one busy window.
  Future<void> deleteEntries({
    required List<String> fileNames,
    required List<String> folderPaths,
  }) async {
    if (state.busy) return;
    if (fileNames.isEmpty && folderPaths.isEmpty) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final names = await _expandSelection(session, fileNames, folderPaths);
      if (names.isEmpty) {
        _notice('Nothing to delete.');
        return;
      }
      for (final name in names) {
        await session.delete(name);
      }
      await _reload();
      _notice('Deleted ${_plural(names.length, 'item')}.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Extract multiple files and folder trees into the picked directory,
  /// mirroring the stored hierarchy (a selected `Notes/a.txt` lands at
  /// `<dir>/Notes/a.txt`, a selected folder recreates its subtree).
  Future<void> extractEntries({
    required List<String> fileNames,
    required List<String> folderPaths,
  }) async {
    if (state.busy) return;
    if (fileNames.isEmpty && folderPaths.isEmpty) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final names = await _expandSelection(session, fileNames, folderPaths);
      final sep = Platform.pathSeparator;
      var count = 0;
      for (final name in names) {
        if (isFolderMarker(name)) continue;
        final dest = '$dir$sep${name.replaceAll('/', sep)}';
        File(dest).parent.createSync(recursive: true);
        await session.extract(name, dest);
        count++;
      }
      _notice(
        count == 0
            ? 'Nothing to extract.'
            : 'Extracted ${_plural(count, 'item')} to $dir.',
      );
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

  /// Compact the vault container; returns whether the operation succeeded.
  Future<bool> compact() async {
    if (state.busy) return false;
    final session = _session;
    if (session == null) return false;
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
      return true;
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Regenerate both container mirrors; returns whether the operation
  /// succeeded.
  Future<bool> remirror() async {
    if (state.busy) return false;
    final session = _session;
    if (session == null) return false;
    _setBusy(true);
    try {
      await session.remirror();
      await _reload();
      _notice('Mirrors regenerated.');
      return true;
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
      return false;
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
