// Unit tests for the folder derivation model (no engine / Flutter needed).

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:acui/ui/vault_model.dart';

List<VaultFileInfo> filesOf(List<String> names) => [
  for (final n in names) VaultFileInfo(n, n.length),
];

void main() {
  group('folder marker helpers', () {
    test('recognizes markers only as a /.ackeep suffix', () {
      expect(isFolderMarker('a/.ackeep'), isTrue);
      expect(isFolderMarker('a/b/.ackeep'), isTrue);
      expect(isFolderMarker('.ackeep'), isFalse);
      expect(isFolderMarker('a/.ackeep/x'), isFalse);
      expect(isFolderMarker('a/real.txt'), isFalse);
    });

    test('extracts the folder path from a marker', () {
      expect(folderPathOfMarker('a/.ackeep'), 'a');
      expect(folderPathOfMarker('a/b/.ackeep'), 'a/b');
      expect(folderPathOfMarker('photos/2024/.ackeep'), 'photos/2024');
    });

    test('parentOfPath', () {
      expect(parentOfPath('a'), '');
      expect(parentOfPath('a/b'), 'a');
      expect(parentOfPath('a/b/c'), 'a/b');
      expect(parentOfPath(''), '');
    });
  });

  group('folder name validation', () {
    test('accepts single-segment names', () {
      expect(isValidFolderName('Photos'), isTrue);
      expect(isValidFolderName('my folder 2'), isTrue);
    });

    test('rejects separators and dot names', () {
      expect(isValidFolderName('a/b'), isFalse);
      expect(isValidFolderName('a\\b'), isFalse);
      expect(isValidFolderName('.'), isFalse);
      expect(isValidFolderName('..'), isFalse);
      expect(isValidFolderName(''), isFalse);
      expect(isValidFolderName(' padded '), isFalse);
    });
  });

  group('buildBrowserEntries', () {
    test('derives folders from prefixes, folders first, alphabetical', () {
      final files = filesOf([
        'zz.txt',
        'Notes/todo.txt',
        'Notes/2024/a.txt',
        'Beta/x.txt',
        'aa.txt',
      ]);
      final entries = buildBrowserEntries(files, '');
      expect(entries.map((e) => e.displayName).toList(), [
        'Beta',
        'Notes',
        'aa.txt',
        'zz.txt',
      ]);
      expect(entries[0].isFolder, isTrue);
      expect(entries[0].folder!.path, 'Beta');
      expect(
        entries[1].folder!.childCount,
        2,
      ); // Notes/todo.txt + Notes/2024/a.txt
      expect(entries[2].isFolder, isFalse);
    });

    test('empty folders from markers render with a zero count', () {
      final files = filesOf(['empty/.ackeep', 'Notes/todo.txt']);
      final entries = buildBrowserEntries(files, '');
      expect(entries.map((e) => e.displayName).toList(), ['Notes', 'empty']);
      final empty = entries.firstWhere(
        (e) => e.isFolder && e.folder!.name == 'empty',
      );
      expect(empty.folder!.childCount, 0);
    });

    test('inside a folder only its direct children are listed', () {
      final files = filesOf([
        'Notes/.ackeep',
        'Notes/todo.txt',
        'Notes/2024/a.txt',
        'Notes/2024/.ackeep',
        'Notes/readme.md',
        'other.txt',
      ]);
      final entries = buildBrowserEntries(files, 'Notes');
      expect(entries.map((e) => e.displayName).toList(), [
        '2024',
        'readme.md',
        'todo.txt',
      ]);
      expect(entries[0].folder!.path, 'Notes/2024');
      expect(entries[0].folder!.childCount, 1);
      expect(entries[2].file!.name, 'Notes/todo.txt');
    });

    test('markers never become file rows', () {
      final files = filesOf(['a/b/.ackeep', 'a/file.txt']);
      final entries = buildBrowserEntries(files, 'a');
      expect(
        entries.any((e) => e.isFolder == false && e.displayName == '.ackeep'),
        isFalse,
      );
    });

    test('nested folder counts include descendants', () {
      final files = filesOf(['p/b/c1.txt', 'p/b/c2.txt', 'p/x.txt']);
      final entries = buildBrowserEntries(files, 'p');
      expect(entries[0].folder!.name, 'b');
      expect(entries[0].folder!.childCount, 2);
    });

    test('root folder path for a top-level child folder', () {
      final files = filesOf(['Music/song.mp3', 'Music/.ackeep']);
      final entries = buildBrowserEntries(files, '');
      final folded = entries.firstWhere((e) => e.isFolder).folder!;
      expect(folded.path, 'Music');
    });
  });
}
