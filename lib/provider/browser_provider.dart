// Riverpod state for the open-vault browser: the file listing, vault info
// snapshot, in-memory preview reads, and every mutating action (import /
// extract / rename / delete / save-as / compact / remirror). All actions
// dispatch through `Vault` (worker-isolate heavy ops) and then refresh the
// async providers so the UI re-reads the container.

import 'dart:io';
import 'dart:typed_data';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/format.dart';
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

/// The vault's plaintext file listing (name + size), re-read whenever the
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

  Future<void> importFiles() async {
    if (state.busy) return;
    final picked = await ref.read(fileServiceProvider).pickImportFiles();
    if (picked.isEmpty) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final items = [
        for (final p in picked) (src: p, storedName: basenameOf(p)),
      ];
      final count = await session.addPaths(items);
      await _reload();
      _notice('Imported ${_plural(count, 'file')}.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> importFolder() async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final items = <({String src, String storedName})>[];
      for (final entity in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          items.add((
            src: entity.path,
            storedName: _relativeStoredName(dir, entity.path),
          ));
        }
      }
      if (items.isEmpty) {
        _notice('No files found in that folder.');
        return;
      }
      final count = await session.addPaths(items);
      await _reload();
      _notice('Imported ${_plural(count, 'file')}.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
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
    _setBusy(true);
    try {
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

  Future<void> saveFileAs(String name, Uint8List bytes) async {
    final loc = await ref
        .read(fileServiceProvider)
        .saveFileAs(suggestedName: basenameOf(name), bytes: bytes);
    if (loc != null) _notice('Saved to $loc');
  }

  Future<void> compact() async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
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
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> remirror() async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.remirror();
      await _reload();
      _notice('Mirrors regenerated.');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  /// Local relative path with `/` separators, mirroring the engine's stored
  /// name convention used by `addPaths`.
  static String _relativeStoredName(String root, String path) {
    final rel = path.substring(root.length).replaceAll('\\', '/');
    return rel.startsWith('/') ? rel.substring(1) : rel;
  }
}

final vaultActionsProvider =
    NotifierProvider<VaultActionsNotifier, VaultActionsState>(
      VaultActionsNotifier.new,
    );
