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

    test('rejects separators, dot names, and the marker name', () {
      expect(isValidFolderName('a/b'), isFalse);
      expect(isValidFolderName('a\\b'), isFalse);
      expect(isValidFolderName('.'), isFalse);
      expect(isValidFolderName('..'), isFalse);
      expect(isValidFolderName('.ackeep'), isFalse);
      expect(isValidFolderName(''), isFalse);
      expect(isValidFolderName(' padded '), isFalse);
    });

    test('recognizes the reserved marker namespace', () {
      expect(isReservedEntryName('.ackeep'), isTrue);
      expect(isReservedEntryName('a/.ackeep'), isTrue);
      expect(isReservedEntryName('a/file.ackeep'), isFalse);
      expect(containsReservedPathSegment('a/.ackeep/file.txt'), isTrue);
      expect(containsReservedPathSegment('a/file.txt'), isFalse);
    });

    test('rejects a reserved ancestor after joining the current folder', () {
      expect(containsReservedPathSegment('.ackeep/Tree'), isTrue);
      expect(containsReservedPathSegment('Notes/.ackeep/Tree'), isTrue);
      expect(containsReservedPathSegment('Notes/Tree'), isFalse);
    });

    test('detects file and folder namespace collisions', () {
      expect(storedPathsConflict('Notes', 'Notes'), isTrue);
      expect(storedPathsConflict('Notes', 'Notes/2024/a.txt'), isTrue);
      expect(storedPathsConflict('Notes/2024', 'Notes/2025/a.txt'), isFalse);
      expect(storedPathsConflict('Notes', 'Notes2'), isFalse);
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
      // A marker declares its folder and every ancestor so marker-only trees
      // have the same destinations as folders shown by the browser.
      expect(allFolderPaths(files), {
        'Notes',
        'Notes/2024',
        'Photos',
        'Photos/2024',
      });
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

    test('rejects the reserved marker namespace', () {
      expect(
        canMoveEntries(
          fileNames: ['.ackeep'],
          folderPaths: const [],
          destPath: 'Notes',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const ['file.txt'],
          folderPaths: const [],
          destPath: 'Archive/.ackeep',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const [],
          folderPaths: const ['Archive/.ackeep'],
          destPath: 'Notes',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const ['Archive/.ackeep/legacy.txt'],
          folderPaths: const [],
          destPath: 'Notes',
        ),
        isFalse,
      );
    });

    test('rejects overlapping source entries', () {
      expect(
        canMoveEntries(
          fileNames: const ['Notes/2024/a.txt'],
          folderPaths: const ['Notes'],
          destPath: 'Archive',
        ),
        isFalse,
      );
      expect(
        canMoveEntries(
          fileNames: const ['Notes/a.txt', 'Notes/a.txt'],
          folderPaths: const [],
          destPath: 'Archive',
        ),
        isFalse,
      );
    });

    test('detects overlap with an ancestor walk for large selections', () {
      final nested = <String>[
        for (var i = 0; i < 2000; i++) 'Folder/file-$i',
        'Folder',
      ];
      expect(hasStoredPathConflict(nested), isTrue);

      final independent = <String>[
        for (var i = 0; i < 2000; i++) 'Folder-$i/file',
      ];
      expect(hasStoredPathConflict(independent), isFalse);
    });

    test('rejects duplicate and nested planned destinations', () {
      expect(
        moveDestinationConflict(
          existingNames: const ['source-a', 'source-b'],
          movedNames: const ['source-a', 'source-b'],
          plannedNames: const ['Archive/photo.jpg', 'Archive/photo.jpg'],
        ),
        isNotNull,
      );
      expect(
        moveDestinationConflict(
          existingNames: const ['source-a', 'source-b'],
          movedNames: const ['source-a', 'source-b'],
          plannedNames: const ['Archive/photo', 'Archive/photo/thumb.jpg'],
        ),
        isNotNull,
      );
      expect(
        moveDestinationConflict(
          existingNames: const ['source-a', 'source-b'],
          movedNames: const ['source-a', 'source-b'],
          plannedNames: const ['Archive/photo', 'Archive/notes.txt'],
        ),
        isNull,
      );
    });

    test(
      'rejects destinations that collide with an existing or moving name',
      () {
        expect(
          moveDestinationConflict(
            existingNames: const ['Archive/photo.jpg'],
            movedNames: const ['photo.jpg'],
            plannedNames: const ['Archive/photo.jpg'],
          ),
          isNotNull,
        );
        expect(
          moveDestinationConflict(
            existingNames: const ['photo.jpg'],
            movedNames: const ['photo.jpg'],
            plannedNames: const ['photo.jpg/child.jpg'],
          ),
          isNotNull,
        );
      },
    );

    test('indexes exact, ancestor, and descendant relationships', () {
      final index = StoredPathIndex(const ['Notes/2024/a.txt']);
      expect(index.contains('Notes/2024/a.txt'), isTrue);
      expect(index.hasDescendant('Notes'), isTrue);
      expect(index.hasAncestor('Notes/2024/a.txt/child'), isTrue);
      expect(index.conflictsWith('Notes'), isTrue);
      expect(index.conflictsWith('Notes/2024/a.txt/child'), isTrue);
      expect(index.conflictsWith('Other/file.txt'), isFalse);
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

  group('metadata and sorting', () {
    test('exposes local creation and modification values when known', () {
      final unknown = VaultFileInfo('legacy.txt', 1);
      expect(unknown.created, isNull);
      expect(unknown.modified, isNull);

      final known = VaultFileInfo(
        'known.txt',
        1,
        createdAt: 1_700_000_000,
        modifiedAt: 1_700_000_001,
      );
      expect(
        known.created!.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
        1_700_000_000,
      );
      expect(
        known.modified!.millisecondsSinceEpoch ~/
            Duration.millisecondsPerSecond,
        1_700_000_001,
      );
    });

    test(
      'sorts modified dates in both directions with unknown values last',
      () {
        final files = [
          VaultFileInfo('old.txt', 1, modifiedAt: 100),
          VaultFileInfo('unknown.txt', 2),
          VaultFileInfo('new.txt', 3, modifiedAt: 300),
        ];

        final ascending = buildBrowserEntries(
          files,
          '',
          sort: const VaultSortSettings(criterion: VaultSort.modified),
        );
        expect(ascending.map((entry) => entry.displayName), [
          'old.txt',
          'new.txt',
          'unknown.txt',
        ]);

        final descending = buildBrowserEntries(
          files,
          '',
          sort: const VaultSortSettings(
            criterion: VaultSort.modified,
            descending: true,
          ),
        );
        expect(descending.map((entry) => entry.displayName), [
          'new.txt',
          'old.txt',
          'unknown.txt',
        ]);
      },
    );

    test('sorts by size while keeping folders first', () {
      final files = [
        VaultFileInfo('small.txt', 1, storageUsed: 100),
        VaultFileInfo('Folder/large.txt', 100, storageUsed: 200),
        VaultFileInfo('medium.txt', 10, storageUsed: 50),
      ];

      final entries = buildBrowserEntries(
        files,
        '',
        sort: const VaultSortSettings(
          criterion: VaultSort.size,
          descending: true,
        ),
      );
      expect(entries.map((entry) => entry.displayName), [
        'Folder',
        'medium.txt',
        'small.txt',
      ]);
      expect(entries[0].size, 100);
      expect(entries[0].storageUsed, 200);
    });

    test('aggregates descendant metadata and marker dates into folders', () {
      final files = [
        VaultFileInfo(
          'Photos/a.jpg',
          10,
          createdAt: 200,
          modifiedAt: 300,
          storageUsed: 1000,
        ),
        VaultFileInfo(
          'Photos/2024/b.jpg',
          20,
          createdAt: 100,
          modifiedAt: 400,
          storageUsed: 2000,
        ),
        VaultFileInfo(
          'Photos/.ackeep',
          0,
          createdAt: 50,
          modifiedAt: 500,
          storageUsed: 7,
        ),
      ];

      final root = buildBrowserEntries(files, '');
      final photos = root
          .singleWhere((entry) => entry.displayName == 'Photos')
          .folder!;
      expect(photos.childCount, 2);
      expect(photos.size, 30);
      expect(photos.storageUsed, 3000);
      expect(photos.createdAt, 50);
      expect(photos.modifiedAt, 500);

      final nested = buildBrowserEntries(
        files,
        'Photos',
      ).singleWhere((entry) => entry.displayName == '2024').folder!;
      expect(nested.childCount, 1);
      expect(nested.size, 20);
      expect(nested.storageUsed, 2000);
      expect(nested.createdAt, 100);
      expect(nested.modifiedAt, 400);
    });

    test('infers types from the final filename extension', () {
      expect(vaultEntryType('Photos/holiday.JPG'), 'Image (JPEG)');
      expect(vaultEntryType('notes.md'), 'Markdown');
      expect(vaultEntryType('archive.tar'), 'File (.tar)');
      expect(vaultEntryType('no-extension'), 'File');
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

    test('distinguishes marker-only child folders from empty folders', () {
      final files = filesOf(['Photos/2024/.ackeep', 'Photos/2025/.ackeep']);
      final root = buildBrowserEntries(files, '');
      final photos = root.singleWhere((e) => e.displayName == 'Photos').folder!;
      expect(photos.childCount, 0);
      expect(photos.visibleChildCount, 2);

      final nested = buildBrowserEntries(
        files,
        'Photos',
      ).firstWhere((entry) => entry.displayName == '2024');
      expect(nested.displayName, '2024');
      expect(nested.folder!.childCount, 0);
      expect(nested.folder!.visibleChildCount, 0);
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
