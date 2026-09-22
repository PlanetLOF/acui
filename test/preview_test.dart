// Unit tests for the preview kind detection, text decoding, and hex dump that
// back the vault-browser preview dialog (see `lib/ui/preview.dart`). Pure Dart
// — no engine, no Flutter widgets — so it runs with `flutter test` quickly.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:acui/ui/preview.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

// Real signatures for the magic-byte cases.
final _png = _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
final _jpeg = _bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46]);
final _gif = _bytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
final _bmp = _bytes([0x42, 0x4D, 0x36, 0x00, 0x00, 0x00]);
final _webp = _bytes([
  0x52,
  0x49,
  0x46,
  0x46,
  0x24,
  0x00,
  0x00,
  0x00,
  0x57,
  0x45,
  0x42,
  0x50,
]);

void main() {
  group('previewKindOf — magic bytes', () {
    test('raster image signatures', () {
      expect(previewKindOf('photo', _png), PreviewKind.image);
      expect(previewKindOf('photo', _jpeg), PreviewKind.image);
      expect(previewKindOf('photo', _gif), PreviewKind.image);
      expect(previewKindOf('photo', _bmp), PreviewKind.image);
      expect(previewKindOf('photo', _webp), PreviewKind.image);
    });

    test('magic bytes beat a misleading extension', () {
      expect(previewKindOf('notes.txt', _png), PreviewKind.image);
      expect(previewKindOf('archive.zip', _jpeg), PreviewKind.image);
      expect(previewKindOf('no-extension', _webp), PreviewKind.image);
    });

    test('svg magic (declaration and bare root, with leading whitespace)', () {
      expect(
        previewKindOf('icon', _utf8('<svg xmlns="x"><circle/></svg>')),
        PreviewKind.svg,
      );
      expect(
        previewKindOf('icon', _utf8('<?xml version="1.0"?><svg/>')),
        PreviewKind.svg,
      );
      expect(
        previewKindOf(
          'icon',
          _utf8('\n  <svg xmlns="http://www.w3.org/2000/svg"></svg>'),
        ),
        PreviewKind.svg,
      );
    });
  });

  group('previewKindOf — extensions', () {
    test('image extensions are trusted without contradicting magic', () {
      for (final ext in ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico']) {
        expect(
          previewKindOf('a.$ext', _utf8('not really an image')),
          PreviewKind.image,
          reason: ext,
        );
      }
    });

    test('extensions are case-insensitive and path-aware', () {
      expect(previewKindOf('Photos/2024/1.JPG', _jpeg), PreviewKind.image);
      expect(
        previewKindOf('Assets\\icon.SVG', _utf8('<svg/>')),
        PreviewKind.svg,
      );
    });

    test('svg extension falls back to svg kind', () {
      expect(previewKindOf('icon.svg', _utf8('plain text')), PreviewKind.svg);
    });
  });

  group('previewKindOf — text vs binary', () {
    test('clean utf-8 content with unknown extension is text', () {
      expect(
        previewKindOf('notes.xyz', _utf8('hello world\nnext line')),
        PreviewKind.text,
      );
      expect(
        previewKindOf('no-extension', _utf8('plain text')),
        PreviewKind.text,
      );
      expect(previewKindOf('', _utf8('')), PreviewKind.text); // empty file
    });

    test('bom-prefixed utf-8 and utf-16 content is text', () {
      expect(
        previewKindOf('a', _bytes([0xEF, 0xBB, 0xBF, 0x68, 0x69])),
        PreviewKind.text,
      );
      expect(
        previewKindOf('a', _bytes([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])),
        PreviewKind.text,
      );
      expect(
        previewKindOf('a', _bytes([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69])),
        PreviewKind.text,
      );
    });

    test('nul bytes or malformed utf-8 are binary', () {
      expect(
        previewKindOf('a', _bytes([0x00, 0x01, 0x02])),
        PreviewKind.binary,
      );
      expect(
        previewKindOf('a', _bytes([0x48, 0x69, 0x00, 0x21])),
        PreviewKind.binary,
      );
      expect(previewKindOf('a', _bytes([0xC3, 0x28])), PreviewKind.binary);
    });

    test('pdf files render as hex dump (no pdf preview yet)', () {
      expect(
        previewKindOf('doc.pdf', _utf8('%PDF-1.4\n1 0 obj\n')),
        PreviewKind.binary,
      );
      expect(
        previewKindOf('doc.PDF', _bytes([0x25, 0x50, 0x44, 0x46, 0x00])),
        PreviewKind.binary,
      );
    });
  });

  group('decodeText', () {
    test('utf-8 (bom stripped)', () {
      expect(decodeText(_utf8('hello')), 'hello');
      expect(decodeText(_bytes([0xEF, 0xBB, 0xBF, 0x68, 0x69])), 'hi');
    });

    test('utf-16 little- and big-endian via bom', () {
      expect(decodeText(_bytes([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00])), 'AB');
      expect(decodeText(_bytes([0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42])), 'AB');
    });

    test(
      'malformed utf-8 decodes with replacement chars instead of throwing',
      () {
        expect(decodeText(_bytes([0xC3, 0x28])), contains('\uFFFD'));
      },
    );
  });

  group('hexDump', () {
    test('single row with padded offset and lowercase hex', () {
      expect(
        hexDump(_bytes([0x00, 0x01, 0x0A, 0xFF])),
        '00000000  00 01 0a ff',
      );
    });

    test('two rows, second row offset advances', () {
      final bytes = List<int>.generate(17, (i) => i);
      final dump = hexDump(Uint8List.fromList(bytes));
      expect(
        dump,
        contains('00000000  00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f'),
      );
      expect(dump, contains('00000010  10'));
    });

    test('maxRows caps the dump and reports skipped bytes', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(1100, (i) => i & 0xFF),
      );
      final dump = hexDump(bytes, maxRows: 64);
      final lines = dump.split('\n');
      expect(lines.length, 65); // 64 rows + "more bytes" trailer
      expect(dump, contains('… 76 more bytes'));
    });

    test('empty content dumps to an empty string', () {
      expect(hexDump(Uint8List(0)), isEmpty);
    });
  });
}
