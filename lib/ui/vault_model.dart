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

/// The folder path declared by a marker entry: `a/b/.ackeep` → `a/b`.
String folderPathOfMarker(String name) =>
    name.substring(0, name.length - folderMarker.length - 1);

/// The parent path of `path`: `a/b` → `a`, `a` → `''` (vault root).
String parentOfPath(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? '' : path.substring(0, i);
}

/// A folder shown in the browser: `path` is its full stored prefix
/// (`Photos/2024`), `name` its display basename, `childCount` the number of
/// descendant plaintext files (marker entries excluded).
class VaultFolder {
  const VaultFolder({
    required this.path,
    required this.name,
    required this.childCount,
  });

  final String path;
  final String name;
  final int childCount;
}

/// One row in the vault browser: either a folder or a file.
class VaultBrowserEntry {
  VaultBrowserEntry.file(this.file) : folder = null;

  VaultBrowserEntry.folder(this.folder) : file = null;

  final VaultFileInfo? file;
  final VaultFolder? folder;

  bool get isFolder => folder != null;

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

/// Build the browser rows to show inside `currentDir` ('' = vault root) from
/// the flat vault listing. Folders sort before files, each group alphabetical.
List<VaultBrowserEntry> buildBrowserEntries(
  List<VaultFileInfo> files,
  String currentDir,
) {
  final prefix = currentDir.isEmpty ? '' : '$currentDir/';

  // 1. Discover every folder path: marker entries plus each ancestor prefix of
  //    every stored name.
  final folders = <String>{};
  final counts = <String, int>{};
  for (final f in files) {
    final name = f.name;
    if (isFolderMarker(name)) {
      folders.add(folderPathOfMarker(name));
      continue;
    }
    var i = name.indexOf('/');
    while (i != -1) {
      final fp = name.substring(0, i);
      folders.add(fp);
      counts[fp] = (counts[fp] ?? 0) + 1;
      i = name.indexOf('/', i + 1);
    }
  }

  // 2. Direct child folders of the current directory.
  final childFolderNames = <String>[];
  for (final fp in folders) {
    if (!fp.startsWith(prefix)) continue;
    final rest = fp.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) continue;
    childFolderNames.add(rest);
  }
  childFolderNames.sort();

  // 3. Direct child files of the current directory (markers never render).
  final childFiles = <VaultFileInfo>[];
  for (final f in files) {
    if (isFolderMarker(f.name)) continue;
    final name = f.name;
    if (!name.startsWith(prefix)) continue;
    final rest = name.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) continue;
    childFiles.add(f);
  }
  childFiles.sort((a, b) => a.name.compareTo(b.name));

  return [
    for (final n in childFolderNames)
      VaultBrowserEntry.folder(
        VaultFolder(
          path: prefix.isEmpty ? n : '$prefix$n',
          name: n,
          childCount: counts[prefix.isEmpty ? n : '$prefix$n'] ?? 0,
        ),
      ),
    for (final f in childFiles) VaultBrowserEntry.file(f),
  ];
}

/// Every folder path present in the vault listing: marker entries plus the
/// ancestor prefix of every stored name (`Photos/2024/1.jpg` yields both
/// `Photos` and `Photos/2024`). Used by the move-target picker.
Set<String> allFolderPaths(List<VaultFileInfo> files) {
  final paths = <String>{};
  for (final f in files) {
    final name = f.name;
    if (isFolderMarker(name)) {
      paths.add(folderPathOfMarker(name));
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

/// Whether the selected entries can be moved into [destPath].
///
/// Stored names are flat and folders are represented by path prefixes, so a
/// source entry's parent is the destination at which it already lives. A
/// folder also cannot be moved into itself or any of its descendants.
bool canMoveEntries({
  required Iterable<String> fileNames,
  required Iterable<String> folderPaths,
  required String destPath,
}) {
  if (fileNames.isEmpty && folderPaths.isEmpty) return false;

  for (final name in fileNames) {
    if (parentOfPath(name) == destPath) return false;
  }
  for (final folder in folderPaths) {
    if (parentOfPath(folder) == destPath) return false;
    if (destPath == folder || destPath.startsWith('$folder/')) return false;
  }
  return true;
}

/// Folder-name validation shared by the create/rename dialogs: non-empty, not
/// `.`/`..`, and no path separators (a folder is one segment).
bool isValidFolderName(String name) {
  if (name.isEmpty || name.trim() != name) return false;
  if (name == '.' || name == '..') return false;
  return !name.contains('/') && !name.contains('\\');
}
