// Folder model for the vault browser.
//
// The engine stores flat files whose stored names may contain `/` prefixes
// (`Photos/2024/1.jpg`). There is no engine-side directory type, so:
//
//  * Folders are *derived* from the path prefixes of stored names.
//  * Empty folders are made durable by a hidden 0-byte marker entry named
//    `<folder>/.ackeep`. Markers are filtered out of every listing.
//
// This file is pure Dart (no Flutter imports) so the derivation can be unit
// tested without an engine.

import 'package:autocipher_dart/autocipher_dart.dart';

/// Hidden 0-byte entry whose presence persists an (possibly empty) folder.
const String folderMarker = '.ackeep';

/// True when `name` is a folder marker like `photos/2024/.ackeep`.
bool isFolderMarker(String name) => name.endsWith('/$folderMarker');

/// True when a stored name uses the reserved folder-marker namespace.
///
/// Markers are hidden by the browser, so allowing a user file to use this
/// name would make that file invisible and could cause an import marker write
/// to overwrite it.
bool isReservedEntryName(String name) =>
    name == folderMarker || isFolderMarker(name);

/// True when any path segment is the reserved marker name. This is used when
/// importing trees so a directory named `.ackeep` cannot create an ambiguous
/// namespace.
bool containsReservedPathSegment(String name) =>
    name.split('/').any((segment) => segment == folderMarker);

/// True when two stored names occupy the same file/folder namespace.
///
/// A flat vault cannot safely contain both `a` and `a/b`: the former would be
/// simultaneously a file and a folder. The comparison is deliberately
/// path-segment aware so similarly named siblings such as `a` and `ab` do
/// not conflict.
bool storedPathsConflict(String a, String b) =>
    a == b || a.startsWith('$b/') || b.startsWith('$a/');

/// The folder path declared by a marker entry: `a/b/.ackeep` → `a/b`.
String folderPathOfMarker(String name) =>
    name.substring(0, name.length - folderMarker.length - 1);

/// The parent path of `path`: `a/b` → `a`, `a` → `''` (vault root).
String parentOfPath(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? '' : path.substring(0, i);
}

/// A folder shown in the browser: `path` is its full stored prefix
/// (`Photos/2024`), `name` its display basename, and `childCount` the number
/// of descendant plaintext files (marker entries excluded). `directChildCount`
/// is the number of immediate files and subfolders used for browser labels.
class VaultFolder {
  const VaultFolder({
    required this.path,
    required this.name,
    required this.childCount,
    this.directChildCount = 0,
    this.size = 0,
    this.storageUsed = 0,
    this.createdAt = 0,
    this.modifiedAt = 0,
  });

  final String path;
  final String name;
  final int childCount;
  final int directChildCount;
  final int size;
  final int storageUsed;
  final int createdAt;
  final int modifiedAt;

  /// Immediate contents for list/grid labels. The fallback keeps manually
  /// constructed folders source-compatible when only descendant `childCount`
  /// is supplied.
  int get visibleChildCount =>
      directChildCount > 0 ? directChildCount : childCount;
}

/// Criteria offered by the browser's Sort by action sheet.
enum VaultSort { name, modified, size }

/// Persistent sort selection and direction.
class VaultSortSettings {
  const VaultSortSettings({
    this.criterion = VaultSort.name,
    this.descending = false,
  });

  final VaultSort criterion;
  final bool descending;

  VaultSortSettings withCriterion(VaultSort value) =>
      VaultSortSettings(criterion: value, descending: descending);

  VaultSortSettings withDescending(bool value) =>
      VaultSortSettings(criterion: criterion, descending: value);

  @override
  bool operator ==(Object other) =>
      other is VaultSortSettings &&
      other.criterion == criterion &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(criterion, descending);
}

/// One row in the vault browser: either a folder or a file.
class VaultBrowserEntry {
  VaultBrowserEntry.file(this.file) : folder = null;

  VaultBrowserEntry.folder(this.folder) : file = null;

  final VaultFileInfo? file;
  final VaultFolder? folder;

  bool get isFolder => folder != null;

  int get size => isFolder ? folder!.size : file!.size;

  int get storageUsed => isFolder ? folder!.storageUsed : file!.storageUsed;

  int get createdAt => isFolder ? folder!.createdAt : file!.createdAt;

  int get modifiedAt => isFolder ? folder!.modifiedAt : file!.modifiedAt;

  String get location => isFolder ? folder!.path : file!.name;

  /// Row label: the folder's segment name, or the file's basename.
  String get displayName {
    if (isFolder) return folder!.name;
    final n = file!.name;
    final i = n.lastIndexOf(RegExp(r'[/\\]'));
    return i == -1 ? n : n.substring(i + 1);
  }

  /// Stable identity for multi-select state: `file:<stored-name>` or
  /// `folder:<path>`. Stored names are unique, so a file's key never collides
  /// with a folder's.
  String get key {
    if (isFolder) return 'folder:${folder!.path}';
    return 'file:${file!.name}';
  }
}

class _FolderStats {
  int childCount = 0;
  int directChildCount = 0;
  int size = 0;
  int storageUsed = 0;
  int createdAt = 0;
  int modifiedAt = 0;

  void addFile(VaultFileInfo file) {
    childCount += 1;
    size += file.size;
    storageUsed += file.storageUsed;
    _addDates(file.createdAt, file.modifiedAt);
  }

  void addMarker(VaultFileInfo marker) {
    _addDates(marker.createdAt, marker.modifiedAt);
  }

  void _addDates(int created, int modified) {
    if (created > 0 && (createdAt == 0 || created < createdAt)) {
      createdAt = created;
    }
    if (modified > modifiedAt) modifiedAt = modified;
  }
}

/// Build the browser rows to show inside `currentDir` ('' = vault root) from
/// the flat vault listing. Folders always precede files; within each group the
/// selected criterion is applied, with a stable name tie-breaker.
List<VaultBrowserEntry> buildBrowserEntries(
  List<VaultFileInfo> files,
  String currentDir, {
  VaultSortSettings sort = const VaultSortSettings(),
}) {
  final prefix = currentDir.isEmpty ? '' : '$currentDir/';

  // 1. Discover folder paths and aggregate descendant metadata. Markers carry
  //    folder dates but are excluded from counts and content-size totals.
  final folders = <String>{};
  final stats = <String, _FolderStats>{};
  for (final f in files) {
    final name = f.name;
    if (isFolderMarker(name)) {
      var path = folderPathOfMarker(name);
      folders.add(path);
      while (true) {
        stats.putIfAbsent(path, _FolderStats.new).addMarker(f);
        if (path.isEmpty) break;
        final next = parentOfPath(path);
        if (next == path) break;
        path = next;
        folders.add(path);
      }
      continue;
    }

    var i = name.indexOf('/');
    while (i != -1) {
      final path = name.substring(0, i);
      folders.add(path);
      stats.putIfAbsent(path, _FolderStats.new).addFile(f);
      i = name.indexOf('/', i + 1);
    }
  }

  // Count immediate children separately from descendant files. A folder can
  // contain only a nested folder (including a marker-only subtree), so using
  // `childCount` for the browser label would incorrectly show it as empty.
  for (final path in folders) {
    final parent = parentOfPath(path);
    if (parent.isNotEmpty) {
      stats.putIfAbsent(parent, _FolderStats.new).directChildCount++;
    }
  }
  for (final file in files) {
    if (isFolderMarker(file.name)) continue;
    final parent = parentOfPath(file.name);
    if (parent.isNotEmpty) {
      stats.putIfAbsent(parent, _FolderStats.new).directChildCount++;
    }
  }

  final entries = <VaultBrowserEntry>[];

  // 2. Direct child folders of the current directory.
  for (final path in folders) {
    if (!path.startsWith(prefix)) continue;
    final rest = path.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) continue;
    final folderStats = stats[path] ?? _FolderStats();
    entries.add(
      VaultBrowserEntry.folder(
        VaultFolder(
          path: path,
          name: rest,
          childCount: folderStats.childCount,
          directChildCount: folderStats.directChildCount,
          size: folderStats.size,
          storageUsed: folderStats.storageUsed,
          createdAt: folderStats.createdAt,
          modifiedAt: folderStats.modifiedAt,
        ),
      ),
    );
  }

  // 3. Direct child files of the current directory (markers never render).
  for (final f in files) {
    if (isFolderMarker(f.name)) continue;
    final name = f.name;
    if (!name.startsWith(prefix)) continue;
    final rest = name.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) continue;
    entries.add(VaultBrowserEntry.file(f));
  }

  entries.sort((a, b) => _compareEntries(a, b, sort));
  return entries;
}

int _compareEntries(
  VaultBrowserEntry a,
  VaultBrowserEntry b,
  VaultSortSettings sort,
) {
  // Preserve the familiar folder-first grouping regardless of the criterion.
  if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;

  final result = switch (sort.criterion) {
    VaultSort.name => a.displayName.compareTo(b.displayName),
    VaultSort.modified => _compareTimestamps(a.modifiedAt, b.modifiedAt),
    VaultSort.size => a.size.compareTo(b.size),
  };
  if (result != 0) {
    // Unknown timestamps remain at the end in both directions; known values
    // are the only ones whose numeric order is reversed.
    if (sort.descending &&
        (sort.criterion != VaultSort.modified ||
            (a.modifiedAt != 0 && b.modifiedAt != 0))) {
      return -result;
    }
    return result;
  }

  final nameResult = a.displayName.compareTo(b.displayName);
  if (nameResult != 0) return nameResult;
  return a.key.compareTo(b.key);
}

int _compareTimestamps(int a, int b) {
  // Legacy entries have timestamp zero. Keep them at the end in either
  // direction rather than pretending they are the newest files.
  if (a == 0 && b == 0) return 0;
  if (a == 0) return 1;
  if (b == 0) return -1;
  return a.compareTo(b);
}

/// Best-effort MIME-like type label inferred from the stored filename.
String vaultEntryType(String name) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash == -1 ? name : name.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return 'File';
  final ext = base.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'Image (JPEG)',
    'png' => 'Image (PNG)',
    'gif' => 'Image (GIF)',
    'webp' => 'Image (WebP)',
    'bmp' => 'Image (BMP)',
    'tif' || 'tiff' => 'Image (TIFF)',
    'svg' => 'Image (SVG)',
    'mp4' || 'm4v' => 'Video (MP4)',
    'mov' => 'Video (QuickTime)',
    'webm' => 'Video (WebM)',
    'avi' => 'Video (AVI)',
    'mp3' => 'Audio (MP3)',
    'wav' => 'Audio (WAV)',
    'flac' => 'Audio (FLAC)',
    'ogg' => 'Audio (Ogg)',
    'pdf' => 'PDF document',
    'txt' || 'text' => 'Text',
    'md' => 'Markdown',
    'rtf' => 'Rich text',
    'csv' => 'CSV',
    'json' => 'JSON',
    'xml' => 'XML',
    'html' || 'htm' => 'HTML',
    'css' => 'CSS',
    'js' || 'mjs' || 'cjs' => 'JavaScript',
    'ts' => 'TypeScript',
    'dart' => 'Dart',
    'rs' => 'Rust',
    'zip' => 'ZIP archive',
    'gz' => 'Gzip archive',
    '7z' => '7-Zip archive',
    _ => 'File (.$ext)',
  };
}

/// Every folder path present in the vault listing: marker entries, marker
/// ancestors, and the ancestor prefix of every stored name (`Photos/2024/1.jpg`
/// yields both `Photos` and `Photos/2024`). Used by the move-target picker.
Set<String> allFolderPaths(List<VaultFileInfo> files) {
  final paths = <String>{};
  for (final f in files) {
    final name = f.name;
    if (isFolderMarker(name)) {
      var path = folderPathOfMarker(name);
      while (path.isNotEmpty) {
        paths.add(path);
        path = parentOfPath(path);
      }
      continue;
    }
    var i = name.indexOf('/');
    while (i != -1) {
      paths.add(name.substring(0, i));
      i = name.indexOf('/', i + 1);
    }
  }
  return paths;
}

/// Whether any two stored paths are equal or one is a path ancestor of the
/// other.
///
/// This walks each path's ancestors rather than comparing every pair. The
/// latter is prohibitively expensive for a large selection because the result
/// is evaluated repeatedly while a drag target is hovered.
bool hasStoredPathConflict(Iterable<String> paths) {
  final values = paths.toList();
  final unique = values.toSet();
  if (unique.length != values.length) return true;

  for (final path in unique) {
    var ancestor = parentOfPath(path);
    while (ancestor.isNotEmpty) {
      if (unique.contains(ancestor)) return true;
      final next = parentOfPath(ancestor);
      if (next == ancestor) break;
      ancestor = next;
    }
  }
  return false;
}

/// A compact path index for collision checks over a large stored-name set.
///
/// [prefixes] contains every proper ancestor of an indexed name. A candidate
/// therefore collides with the index when it is itself indexed, is a proper
/// ancestor of an indexed name, or has an indexed ancestor. The ancestor walk
/// keeps each check proportional to path depth rather than to the number of
/// entries.
class StoredPathIndex {
  /// Set [trackDuplicates] when [conflictsWithOther] will compare a complete
  /// planned list; ordinary occupancy indexes can avoid the extra count map.
  StoredPathIndex([
    Iterable<String> paths = const <String>[],
    bool trackDuplicates = false,
  ]) : _counts = trackDuplicates ? <String, int>{} : null {
    for (final path in paths) {
      add(path);
    }
  }

  final _names = <String>{};
  final _prefixes = <String>{};
  final Map<String, int>? _counts;

  void add(String path) {
    _names.add(path);
    final counts = _counts;
    if (counts != null) counts[path] = (counts[path] ?? 0) + 1;
    var ancestor = parentOfPath(path);
    while (ancestor.isNotEmpty) {
      _prefixes.add(ancestor);
      final next = parentOfPath(ancestor);
      if (next == ancestor) break;
      ancestor = next;
    }
  }

  bool contains(String path) => _names.contains(path);

  /// Whether the index contains a proper descendant of [path].
  bool hasDescendant(String path) => _prefixes.contains(path);

  /// Whether the index contains a proper ancestor of [path].
  bool hasAncestor(String path) {
    var ancestor = parentOfPath(path);
    while (ancestor.isNotEmpty) {
      if (_names.contains(ancestor)) return true;
      final next = parentOfPath(ancestor);
      if (next == ancestor) break;
      ancestor = next;
    }
    return false;
  }

  bool conflictsWith(String path) {
    return _names.contains(path) ||
        _prefixes.contains(path) ||
        hasAncestor(path);
  }

  /// Like [conflictsWith], but ignores one occurrence of [path] itself. This
  /// is used for the complete planned list, where each candidate should still
  /// be compared with every *other* planned leaf.
  bool conflictsWithOther(String path) {
    return (_counts?[path] ?? 0) > 1 ||
        _prefixes.contains(path) ||
        hasAncestor(path);
  }
}

/// Whether the selected entries can be moved into [destPath].
///
/// Stored names are flat and folders are represented by path prefixes, so a
/// source entry's parent is the destination at which it already lives. A
/// folder also cannot be moved into itself or any of its descendants. Entries
/// or destinations in the reserved `.ackeep` namespace are rejected.
bool canMoveEntries({
  required Iterable<String> fileNames,
  required Iterable<String> folderPaths,
  required String destPath,
}) {
  if (fileNames.isEmpty && folderPaths.isEmpty) return false;
  if (containsReservedPathSegment(destPath)) return false;

  final sourcePaths = [...fileNames, ...folderPaths];
  // A selection cannot contain an entry and one of its descendants (or two
  // representations of the same stored name). Expanding either one would
  // make the rename plan overlap and could clobber data.
  if (hasStoredPathConflict(sourcePaths)) return false;

  for (final name in fileNames) {
    // A move preserves the basename; carrying the reserved namespace into
    // another folder would recreate an ambiguous hidden marker tree.
    if (containsReservedPathSegment(name)) return false;
    if (parentOfPath(name) == destPath) return false;
  }
  for (final folder in folderPaths) {
    if (containsReservedPathSegment(folder)) return false;
    if (parentOfPath(folder) == destPath) return false;
    if (destPath == folder || destPath.startsWith('$folder/')) return false;
  }
  return true;
}

/// Return the first planned move destination that would create a namespace
/// collision, or `null` when the whole rename plan is safe.
///
/// [movedNames] are the old stored names that will be vacated. They are
/// excluded from the existing-listing check, but are still checked against
/// every destination: a planned path must not depend on a source entry that
/// is itself being renamed. Checking every planned leaf (rather than only the
/// top-level roots) also catches duplicate and nested destinations before the
/// sequential renames begin.
String? moveDestinationConflict({
  required Iterable<String> existingNames,
  required Iterable<String> movedNames,
  required Iterable<String> plannedNames,
}) {
  final movedSet = movedNames.toSet();
  final moved = StoredPathIndex(movedSet);
  final existing = StoredPathIndex(
    existingNames.where((name) => !movedSet.contains(name)),
  );
  final planned = plannedNames.toList();
  final plannedIndex = StoredPathIndex(planned, true);

  for (final destination in planned) {
    if (moved.conflictsWith(destination) ||
        existing.conflictsWith(destination) ||
        plannedIndex.conflictsWithOther(destination)) {
      return destination;
    }
  }
  return null;
}

/// Folder-name validation shared by the create/rename dialogs: non-empty, not
/// `.`/`..`, and no path separators (a folder is one segment).
bool isValidFolderName(String name) {
  if (name.isEmpty || name.trim() != name) return false;
  if (name == '.' || name == '..' || name == folderMarker) return false;
  return !name.contains('/') && !name.contains('\\');
}
