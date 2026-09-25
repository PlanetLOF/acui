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

  group('allFolderPaths', () {
    test('derives folders from markers and name prefixes', () {
      final files = filesOf([
        'Notes/.ackeep',
        'Notes/todo.txt',
        'Notes/2024/a.txt',
        'Photos/2024/.ackeep',
        'readme.md',
      ]);
      // A nested marker alone only declares its own path (`Photos/2024`);
      // intermediate ancestors come from stored names, same as the browser.
      expect(allFolderPaths(files), {'Notes', 'Notes/2024', 'Photos/2024'});
    });

    test('is empty for a flat listing', () {
      expect(allFolderPaths(filesOf(['a.txt', 'b.txt'])), isEmpty);
    });
  });

  group('move destination validation', () {
    test('allows a file to move into a different folder', () {
      expect(
        canMoveEntries(
          fileNames: ['Notes/todo.txt'],
          folderPaths: const [],
          destPath: 'Archive',
        ),
        isTrue,
      );
    });

    test('rejects no-op moves and folder descendants', () {
      expect(
        canMoveEntries(
          fileNames: ['Notes/todo.txt'],
          folderPaths: const [],
          destPath: 'Notes',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const ['Photos'],
          destPath: 'Photos/2024',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const ['Photos'],
          destPath: 'Photos',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const ['Notes/2024'],
          destPath: 'Notes',
        ),
        isFalse,
      );
    });

    test('allows a nested item to move to the vault root', () {
      expect(
        canMoveEntries(
          fileNames: ['Notes/todo.txt'],
          folderPaths: const [],
          destPath: '',
        ),
        isTrue,
      );
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const ['Notes/2024'],
          destPath: '',
        ),
        isTrue,
      );
    });

    test('rejects an empty selection', () {
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const [],
          destPath: 'Notes',
        ),
        isFalse,
      );
    });
  });

  group('entry keys', () {
    test('file and folder keys are prefix-distinct', () {
      final file = buildBrowserEntries(filesOf(['a.txt']), '')[0];
      final folder = buildBrowserEntries(filesOf(['a.txt', 'd/x.txt']), '')[0];
      expect(file.key, 'file:a.txt');
      expect(folder.key, 'folder:d');
      expect(file.key, isNot(folder.key));
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
