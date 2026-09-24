// rclone bridge for cloud-storage vaults.
//
// The app shells out to the `rclone` binary for every remote operation
// (`listremotes`, `lsjson`, `copyto`, …). Arguments are always passed as an
// argument list (never string-interpolated), so paths with spaces or
// non-ASCII characters survive on Windows. The subprocess does the heavy
// lifting (network I/O + hashing), so the UI isolate is never blocked.
//
// rclone's own config file (`rclone.conf`) stays the single source of truth
// for remotes. This service only reads names/types/entries — it never logs or
// displays the secret values inside `rclone config dump`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A configured rclone remote (a named backend in `rclone.conf`).
class RcloneRemote {
  const RcloneRemote({required this.name, required this.type});

  final String name;
  final String type;

  @override
  String toString() => type.isEmpty ? name : '$name ($type)';
}

/// One entry in a remote directory listing (`rclone lsjson`).
class RcloneEntry {
  const RcloneEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.isDir,
    required this.modTime,
  });

  factory RcloneEntry.fromJson(Map<String, dynamic> json) => RcloneEntry(
    name: json['Name'] as String? ?? '',
    path: json['Path'] as String? ?? '',
    size: (json['Size'] as num?)?.toInt() ?? 0,
    isDir: json['IsDir'] as bool? ?? false,
    modTime: json['ModTime'] as String?,
  );

  final String name;
  final String path;
  final int size;
  final bool isDir;

  /// RFC3339-ish timestamp as reported by rclone; `null` when the backend has
  /// no modtime support (compared as an opaque string for conflict checks).
  final String? modTime;

  bool get isVault => name.toLowerCase().endsWith('.ac');
}

/// The remote-modification fingerprint used for conflict detection:
/// size + modtime, exactly what rclone itself compares by default.
class RemoteState {
  const RemoteState(this.size, this.modTime);

  final int size;
  final String? modTime;

  @override
  bool operator ==(Object other) =>
      other is RemoteState && other.size == size && other.modTime == modTime;

  @override
  int get hashCode => Object.hash(size, modTime);
}

/// A failed rclone invocation (exit code != 0).
class RcloneException implements Exception {
  const RcloneException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Build an rclone remote path from a remote name and `'/'`-separated path
/// segments: `gdrive` + `['vaults', 'foo.ac']` → `gdrive:/vaults/foo.ac`.
/// An empty path yields `gdrive:` (the remote root).
String remotePathOf(String remote, List<String> segments) {
  final joined = segments.where((s) => s.isNotEmpty).join('/');
  return '$remote:${joined.isEmpty ? '' : '/$joined'}';
}

/// Split `gdrive:/path/to/foo.ac` into `('gdrive', '/path/to/foo.ac')`
/// (the path keeps its leading slash; trailing-slash roots are `''`).
(String, String) splitRemotePath(String remotePath) {
  final i = remotePath.indexOf(':');
  if (i == -1) return (remotePath, '');
  final remote = remotePath.substring(0, i);
  var path = remotePath.substring(i + 1);
  while (path.startsWith('/')) {
    path = path.substring(1);
  }
  return (remote, path);
}

String _basename(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? path : path.substring(i + 1);
}

String _parent(String path) {
  final i = path.lastIndexOf('/');
  return i == -1 ? '' : path.substring(0, i);
}

/// Thin wrapper around the `rclone` executable.
class RcloneService {
  const RcloneService();

  /// The binary to run: a user override from settings when set and present on
  /// disk, otherwise `rclone` resolved through PATH.
  Future<String> resolveBinary() async {
    final prefs = await SharedPreferences.getInstance();
    final override = prefs.getString('rclone_binary_path')?.trim() ?? '';
    if (override.isNotEmpty && File(override).existsSync()) return override;
    return 'rclone';
  }

  Future<ProcessResult> _run(List<String> args) async {
    final binary = await resolveBinary();
    final result = await Process.run(binary, ['-q', ...args]);
    if (result.exitCode != 0) {
      final err = result.stderr.toString().trim();
      throw RcloneException(
        err.isEmpty
            ? 'rclone exited with code ${result.exitCode}'
            : err.split('\n').last,
      );
    }
    return result;
  }

  /// All configured remotes, names + backend types.
  ///
  /// Types come from `rclone config dump`, which also contains secrets — only
  /// the `type` key of each remote is read here, never printed.
  Future<List<RcloneRemote>> listRemotes() async {
    final out = (await _run(['listremotes'])).stdout.toString().trim();
    final names = <String>[];
    for (final line in out.split('\n')) {
      final t = line.trim();
      if (t.endsWith(':')) names.add(t.substring(0, t.length - 1));
    }

    Map<String, dynamic> types = const {};
    try {
      final dump = (await _run(['config', 'dump'])).stdout.toString().trim();
      if (dump.isNotEmpty) {
        types = await Isolate.run(
          () => Map<String, dynamic>.from(jsonDecode(dump) as Map),
        );
      }
    } catch (_) {
      // Types are cosmetic — listing names alone still works.
    }

    return [
      for (final n in names)
        RcloneRemote(
          name: n,
          type: (types[n] as Map<String, dynamic>?)?['type'] as String? ?? '',
        ),
    ];
  }

  /// One level of `remote:path` as [RcloneEntry]s (dirs and files mixed).
  Future<List<RcloneEntry>> listDir(String remotePath) async {
    final out = (await _run(['lsjson', remotePath])).stdout.toString().trim();
    if (out.isEmpty) return const [];
    final parsed = await Isolate.run(() => jsonDecode(out) as List);
    return [
      for (final e in parsed) RcloneEntry.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Locate the entry for `remotePath` inside its parent listing, or `null`
  /// when the file does not exist remotely.
  Future<RcloneEntry?> findRemoteEntry(String remotePath) async {
    final (remote, path) = splitRemotePath(remotePath);
    if (path.isEmpty) return null;
    final parent = _parent(path);
    final name = _basename(path);
    final entries = await listDir(remotePathOf(remote, [parent]));
    for (final e in entries) {
      if (e.path == name) return e;
    }
    return null;
  }

  /// Download `remotePath` to the exact local file `localPath`.
  Future<void> download(String remotePath, String localPath) async {
    await File(localPath).parent.create(recursive: true);
    await _run(['copyto', remotePath, localPath]);
  }

  /// Upload the local file `localPath` to the exact remote path.
  Future<void> upload(String localPath, String remotePath) async {
    await _run(['copyto', localPath, remotePath]);
  }

  /// Delete one remote file.
  Future<void> deleteFile(String remotePath) =>
      _run(['deletefile', remotePath]);

  /// Remove a remote folder and everything inside it.
  Future<void> purge(String remotePath) => _run(['purge', remotePath]);

  /// Create a remote folder (and its parents).
  Future<void> mkdir(String remotePath) => _run(['mkdir', remotePath]);

  /// Remove the remote `name` from the config file.
  Future<void> deleteRemote(String name) => _run(['config', 'delete', name]);

  /// Open the interactive `rclone config` wizard in its own terminal window
  /// (Option A). The app returns immediately; the user creates/authorizes
  /// remotes there, then hits REFRESH in the app.
  Future<void> launchRcloneConfig() async {
    final binary = await resolveBinary();
    if (Platform.isWindows) {
      // `start "" <exe> args` opens a fresh console window running the
      // wizard, leaving the GUI app's own console (if any) untouched.
      // Every token is a separate argument — embedding quotes inside one
      // argument gets backslash-escaped by Dart's Windows encoder and cmd
      // misparses it ("cannot find '\\rclone\\config'").
      await Process.start('cmd', [
        '/c',
        'start',
        '',
        binary,
        'config',
      ], mode: ProcessStartMode.detachedWithStdio);
      return;
    }
    if (Platform.isMacOS) {
      final script = File(
        '${Directory.systemTemp.path}/acui-rclone-config.command',
      );
      await script.writeAsString('#!/bin/bash\nexec "$binary" config\n');
      await Process.run('chmod', ['+x', script.path]);
      await Process.start('open', [
        script.path,
      ], mode: ProcessStartMode.detachedWithStdio);
      return;
    }
    // Linux: try the common terminal emulators, falling back to a direct
    // spawn (which needs a terminal/conpty to be useful).
    for (final term in <List<String>>[
      ['x-terminal-emulator', '-e'],
      ['gnome-terminal', '--'],
      ['konsole', '-e'],
      ['xfce4-terminal', '-e'],
    ]) {
      try {
        final which = await Process.run('which', [term[0]]);
        if (which.exitCode != 0 || which.stdout.toString().trim().isEmpty) {
          continue;
        }
        await Process.start(term[0], [
          ...term.sublist(1),
          binary,
          'config',
        ], mode: ProcessStartMode.detachedWithStdio);
        return;
      } catch (_) {
        // Try the next terminal.
      }
    }
    throw const RcloneException(
      'No terminal emulator found to run "rclone config". '
      'Run it manually in a terminal, then tap REFRESH.',
    );
  }
}

final rcloneServiceProvider = Provider<RcloneService>(
  (ref) => const RcloneService(),
);

/// The configured remotes, invalidated after wizard / settings changes.
final cloudRemotesProvider = FutureProvider<List<RcloneRemote>>((ref) {
  return ref.watch(rcloneServiceProvider).listRemotes();
});

/// The user's rclone binary path override (`null` = use PATH).
class RcloneSettingsNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('rclone_binary_path');
  }

  Future<void> setPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.trim().isEmpty) {
      await prefs.remove('rclone_binary_path');
      state = const AsyncData(null);
    } else {
      await prefs.setString('rclone_binary_path', path.trim());
      state = AsyncData(path.trim());
    }
  }
}

final rcloneSettingsProvider =
    AsyncNotifierProvider<RcloneSettingsNotifier, String?>(
      RcloneSettingsNotifier.new,
    );
