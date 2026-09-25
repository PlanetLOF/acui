// Small UI helpers shared by the screens: human-readable sizes, path
// basenames that work on every desktop OS, and the KDF preset menu entries.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart';

/// The KDF presets offered in the create / change-password dialogs.
const List<({KdfPreset preset, String label})> kdfPresetChoices = [
  (preset: KdfPreset.kdf128, label: '128 MiB (fast) — t=3 p=2'),
  (preset: KdfPreset.kdf256, label: '256 MiB (balanced) — t=4 p=4'),
  (preset: KdfPreset.kdf512, label: '512 MiB (max) — t=4 p=4'),
];

/// Human-readable byte size (B / KB / MB / GB).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

/// Format a Unix timestamp in seconds for the information dialog.
String formatVaultTimestamp(int seconds) {
  if (seconds <= 0) return 'Not recorded';
  final value = DateTime.fromMillisecondsSinceEpoch(
    seconds * Duration.millisecondsPerSecond,
    isUtc: true,
  ).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

/// The last path segment of `path`, accepting both `/` and `\` separators.
String basenameOf(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i == -1 ? path : path.substring(i + 1);
}

/// Show a transient [SnackBar] with [message] on the nearest messenger.
void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// A safe message for the UI: the engine's own text for typed vault errors,
/// a generic fallback otherwise.
String exceptionText(Object error) {
  if (error is AutocipherException) return error.message;
  return error.toString();
}

/// Like [exceptionText] — the engine is the only source of expected errors
/// now (the old FFI transport pipe is gone).
String describeEngineError(Object error) => exceptionText(error);
