// File-preview type detection and rendering helpers for the vault browser.
//
// The engine stores no content type — `VaultFileInfo` is name + size only — so
// the preview kind is inferred from the stored name's extension and the first
// bytes of content:
//
//  * raster images and SVG render natively (`Image.memory` / `SvgPicture.memory`),
//  * video files are no longer decoded — they show a generic movie icon in the
//    browser and a read-free placeholder dialog on tap,
//  * anything that decodes cleanly as UTF-8 / UTF-16 renders as selectable text,
//  * everything else falls back to a hex dump instead of mojibake.
//
// Magic-byte sniffing wins over the extension so a misnamed file still renders
// by its actual content; the extension is only trusted when no magic matched.
// This module is pure Dart so the detection can be unit-tested without Flutter.

import 'dart:convert';
import 'dart:typed_data';

/// How preview content should be rendered in the preview dialog.
enum PreviewKind { image, svg, video, text, binary }

/// Raster-image suffixes that render with `Image.memory` and can be
/// thumbnailed inline in the browser grid/list.
const Set<String> _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'ico',
};

/// Video suffixes: previewed as a captured-frame thumbnail in the dialog.
/// `.ts` (MPEG-TS) is intentionally absent so TypeScript sources keep their
/// text preview instead of being misdetected as video.
const Set<String> _videoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'webm',
  'mkv',
  'avi',
  'wmv',
  'flv',
  'mpg',
  'mpeg',
  'ogv',
  '3gp',
};

/// Lowercased file suffix (no leading dot) → native preview kind, or `null`
/// when the extension carries no content hint. The sets are kept as plain
/// constants; membership checks replace the old lookup map.
PreviewKind? _extensionKind(String ext) {
  if (_imageExtensions.contains(ext)) return PreviewKind.image;
  if (_videoExtensions.contains(ext)) return PreviewKind.video;
  if (ext == 'svg') return PreviewKind.svg;
  return null;
}

/// Suffixes that are never plain text; these always render as a hex dump.
/// PDF pages are not rendered by the preview dialog yet, so `.pdf` (which a
/// real file proves binary via NUL bytes anyway) is pinned to the hex view.
const Set<String> _binaryExtensions = {'pdf'};

/// How many leading bytes are sniffed for type detection / text heuristics.
const int _sniffBytes = 16 * 1024;

/// The kind to show for [name] whose content is [bytes].
///
/// Magic bytes take precedence over the name's extension; a recognized
/// extension is the fallback for types without a solid signature (e.g. ICO);
/// anything else is text when it round-trips as clean UTF-8/UTF-16 content and
/// binary otherwise.
PreviewKind previewKindOf(String name, Uint8List bytes) {
  final head = _head(bytes);
  final byMagic = _magicKind(head);
  if (byMagic != null) return byMagic;
  final ext = _extensionOf(name);
  final byExtension = _extensionKind(ext);
  if (byExtension != null) return byExtension;
  if (_binaryExtensions.contains(ext)) return PreviewKind.binary;
  return _looksLikeText(head) ? PreviewKind.text : PreviewKind.binary;
}

/// Whether [name]'s extension is a raster image that can be thumbnailed in
/// the browser grid/list (content is not read — extension-only).
bool isImageName(String name) => _imageExtensions.contains(_extensionOf(name));

/// Whether [name]'s extension is a video type (extension-only). Videos are no
/// longer decoded/previewed; the browser shows them with a generic movie icon
/// and a read-free placeholder dialog.
bool isVideoName(String name) => _videoExtensions.contains(_extensionOf(name));

/// The last lowercase suffix of [name] (e.g. `a/b/Photo.JPG` → `jpg`), or
/// `''` when there is none. Names use `/` separators inside the vault.
String _extensionOf(String name) {
  final base = name.substring(name.lastIndexOf('/') + 1);
  final i = base.lastIndexOf('.');
  return i == -1 ? '' : base.substring(i + 1).toLowerCase();
}

/// The first [_sniffBytes] of [bytes] (or the whole buffer when smaller).
Uint8List _head(Uint8List bytes) => bytes.length <= _sniffBytes
    ? bytes
    : Uint8List.sublistView(bytes, 0, _sniffBytes);

/// The native kind proven by [head]'s leading signature, or `null`.
PreviewKind? _magicKind(Uint8List head) {
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (_startsWith(head, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return PreviewKind.image;
  }
  // JPEG: FF D8 FF
  if (head.length >= 3 &&
      head[0] == 0xFF &&
      head[1] == 0xD8 &&
      head[2] == 0xFF) {
    return PreviewKind.image;
  }
  // GIF: "GIF87a" / "GIF89a"
  if (head.length >= 3 &&
      head[0] == 0x47 &&
      head[1] == 0x49 &&
      head[2] == 0x46) {
    return PreviewKind.image;
  }
  // BMP: "BM"
  if (head.length >= 2 && head[0] == 0x42 && head[1] == 0x4D) {
    return PreviewKind.image;
  }
  // WebP: "RIFF" .... "WEBP"
  if (head.length >= 12 &&
      head[0] == 0x52 &&
      head[1] == 0x49 &&
      head[2] == 0x46 &&
      head[3] == 0x46 &&
      head[8] == 0x57 &&
      head[9] == 0x45 &&
      head[10] == 0x42 &&
      head[11] == 0x50) {
    return PreviewKind.image;
  }
  // MP4 / M4V / MOV / 3GP: an `ftyp` box at offset 4.
  if (head.length >= 8 &&
      head[4] == 0x66 &&
      head[5] == 0x74 &&
      head[6] == 0x79 &&
      head[7] == 0x70) {
    return PreviewKind.video;
  }
  // WebM / Matroska (.mkv): the EBML header magic.
  if (head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3) {
    return PreviewKind.video;
  }
  // AVI: a "RIFF" chunk whose form type is "AVI " (distinct from WebP's
  // "WEBP" or WAV's "WAVE").
  if (head.length >= 12 &&
      head[0] == 0x52 &&
      head[1] == 0x49 &&
      head[2] == 0x46 &&
      head[3] == 0x46 &&
      head[8] == 0x41 &&
      head[9] == 0x56 &&
      head[10] == 0x49 &&
      head[11] == 0x20) {
    return PreviewKind.video;
  }
  // SVG: an XML declaration or a bare <svg… root (tolerating leading
  // whitespace so indented documents aren't missed).
  final trimmed = utf8.decode(head, allowMalformed: true).trimLeft();
  if (trimmed.startsWith('<?xml') || trimmed.startsWith('<svg')) {
    return PreviewKind.svg;
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

bool _isUtf8Bom(Uint8List b) =>
    b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF;

bool _isUtf16Bom(Uint8List b) =>
    b.length >= 2 &&
    ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF));

/// Whether [head] plausibly contains text: no UTF-8 replacement surrogates and
/// no non-whitespace control bytes. BOM-prefixed UTF-8/UTF-16 counts as text.
bool _looksLikeText(Uint8List head) {
  if (_isUtf8Bom(head) || _isUtf16Bom(head)) return true;
  final s = utf8.decode(head, allowMalformed: true);
  if (s.contains('\uFFFD')) return false;
  for (final unit in s.codeUnits) {
    if (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) {
      return false; // NUL, ESC, … — binary content
    }
  }
  return true;
}

/// Decode [bytes] as text: BOM-aware UTF-16, then UTF-8 (BOM stripped).
/// Malformed sequences decode as replacement characters instead of throwing.
/// (dart:convert ships no public UTF-16 codec, hence the small decoder here.)
String decodeText(Uint8List bytes) {
  if (_isUtf16Bom(bytes)) return _decodeUtf16(bytes);
  final body = _isUtf8Bom(bytes) ? bytes.sublist(3) : bytes;
  return utf8.decode(body, allowMalformed: true);
}

/// Decode BOM-prefixed UTF-16 payload (LE or BE) into a Dart string. Code
/// units are passed through `String.fromCharCodes`, which pairs adjacent
/// surrogates as usual; stray surrogates just render as U+FFFD.
String _decodeUtf16(Uint8List bytes) {
  final littleEndian = bytes[0] == 0xFF && bytes[1] == 0xFE;
  final codeUnits = <int>[];
  var i = 2;
  while (i + 1 < bytes.length) {
    codeUnits.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
    i += 2;
  }
  return String.fromCharCodes(codeUnits);
}

/// A monospace hex dump of [bytes], byte-offset columns and up to [maxRows]
/// rows of [rowBytes] bytes each; a trailing line reports skipped bytes.
String hexDump(Uint8List bytes, {int rowBytes = 16, int maxRows = 64}) {
  final totalRows =
      bytes.length ~/ rowBytes + (bytes.length % rowBytes == 0 ? 0 : 1);
  final rows = totalRows < maxRows ? totalRows : maxRows;
  final sb = StringBuffer();
  for (var r = 0; r < rows; r++) {
    final start = r * rowBytes;
    final end = start + rowBytes < bytes.length
        ? start + rowBytes
        : bytes.length;
    sb.write(start.toRadixString(16).padLeft(8, '0'));
    sb.write('  ');
    for (var i = start; i < end; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    sb.write('\n');
  }
  final shown = rows * rowBytes;
  if (bytes.length > shown) {
    sb.write('… ${bytes.length - shown} more bytes\n');
  }
  return sb.toString().trimRight();
}
