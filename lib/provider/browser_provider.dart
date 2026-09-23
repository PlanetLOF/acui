// Riverpod state for the open-vault browser: the file listing, vault info
// snapshot, in-memory preview reads, and every mutating action (import /
// extract / rename / delete / save-as / compact / remirror). All actions
// dispatch through `Vault` (worker-isolate heavy ops) and then refresh the
// async providers so the UI re-reads the container.
//
// Folders are a UI-level concept (see `../ui/vault_model.dart`): they are
// derived from the `/` prefixes of stored names, and empty folders persist as
// hidden `.ackeep` marker entries. The current folder is plain per-session UI
// state (auto-disposed when the browser unmounts on lock).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/format.dart';
import '../ui/vault_model.dart';
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

/// The folder shown by the browser; `''` = vault root. Scoped to the open
/// session: it auto-disposes when the browser is unmounted (vault locked), so
/// the next session starts at the root.
class CurrentFolderNotifier extends Notifier<String> {
  @override
  String build() => '';

  void go(String path) => state = path;
}

final currentVaultFolderProvider =
    NotifierProvider<CurrentFolderNotifier, String>(CurrentFolderNotifier.new);

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

/// How many image bytes are read to build a browser grid/list thumbnail.
/// Files larger than this fall back to the generic file icon (the truncated
/// head usually won't decode).
const int imageThumbCap = 4 << 20;

/// A tiny bounded LRU of raw thumbnail bytes, keyed by stored name. The grid
/// shows many images at once and Riverpod's autoDispose would otherwise
/// re-read the engine on every scroll/rebuild; this keeps reads to once per
/// file while pinning memory (~16 MiB budget).
class ThumbnailByteCache {
  ThumbnailByteCache(this.budgetBytes);

  final int budgetBytes;
  final _entries = <String, Uint8List>{};
  int _used = 0;

  Uint8List? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value; // move to the recency tail
    return value;
  }

  void put(String key, Uint8List value) {
    final existing = _entries.remove(key);
    if (existing != null) _used -= existing.length;
    if (value.length > budgetBytes) return; // never cache oversized entries
    _entries[key] = value;
    _used += value.length;
    while (_used > budgetBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _used -= _entries.remove(oldest)!.length;
    }
  }
}

final thumbnailByteCacheProvider = Provider<ThumbnailByteCache>(
  (_) => ThumbnailByteCache(16 << 20),
);

/// Raw head bytes of an image-like file for grid/list thumbnails, cached by
/// stored name. Decoding happens in the widget (`Image.memory` with
/// `cacheWidth`), so corrupt or truncated heads simply fall back to the
/// generic file icon.
final vaultImageThumbProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, name) async {
      final cache = ref.read(thumbnailByteCacheProvider);
      final hit = cache.get(name);
      if (hit != null) return hit;
      final session = _watchSession(ref);
      final files = await ref.watch(vaultFilesProvider.future);
      final file = files.firstWhere(
        (f) => f.name == name,
        orElse: () => throw NotFoundInVaultException(2, 'no such file: $name'),
      );
      final Uint8List bytes;
      if (file.size <= imageThumbCap) {
        bytes = await session.readFile(name);
      } else {
        bytes = await session.readRange(name, offset: 0, len: imageThumbCap);
      }
      cache.put(name, bytes);
      return bytes;
    });

/// A video's captured frame, used for browser thumbnails and the
/// thumbnail-only click dialog.
class VaultVideoThumb {
  const VaultVideoThumb({required this.frameBytes, required this.fullSize});

  /// One decoded frame as JPEG bytes.
  final Uint8List frameBytes;

  /// The file's full size, for reference in the UI.
  final int fullSize;
}

/// Bounded LRU of captured video frames (JPEG bytes), keyed by stored name.
/// A frame capture is expensive — full-file decrypt to temp + an mpv decode —
/// so revisiting a video (scroll back, dialog reopen) must not repeat it.
/// ~24 MiB budget, well below the image-thumb cache's semantics.
final videoThumbCacheProvider = Provider<ThumbnailByteCache>(
  (_) => ThumbnailByteCache(24 << 20),
);

/// Serializes frame captures so a grid full of videos never stacks decoders
/// (each capture owns one mpv instance + texture).
class _CaptureGate {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

final _videoCaptureGate = _CaptureGate();

bool _mediaKitInitialized = false;

/// One-time `MediaKit.ensureInitialized`. Called from `main()` and again
/// defensively from the video provider; safe to invoke any number of times.
void ensureMediaKitInitialized() {
  if (_mediaKitInitialized) return;
  _mediaKitInitialized = true;
  try {
    MediaKit.ensureInitialized();
  } catch (_) {
    // The video-thumbnail path surfaces its own error if mpv never loaded.
  }
}

/// Captured-frame thumbnail of a video for the browser grid/list and the
/// thumbnail-only tap dialog. The whole file is extracted to a temp file (the
/// engine decrypts streaming, but a decoder needs a seekable file), one frame
/// is decoded with the bundled mpv via `media_kit`, and the temp file is
/// deleted. Playback is deliberately not wired up.
final vaultVideoThumbProvider = FutureProvider.autoDispose
    .family<VaultVideoThumb, String>((ref, name) async {
      ensureMediaKitInitialized();
      final session = _watchSession(ref);
      final files = await ref.watch(vaultFilesProvider.future);
      final file = files.firstWhere(
        (f) => f.name == name,
        orElse: () => throw NotFoundInVaultException(2, 'no such file: $name'),
      );

      final cache = ref.read(videoThumbCacheProvider);
      final cached = cache.get(name);
      if (cached != null) {
        return VaultVideoThumb(frameBytes: cached, fullSize: file.size);
      }

      final frame = await _captureVideoFrame(session, file);
      if (frame == null) {
        throw StateError('no frame could be captured from the video');
      }
      cache.put(name, frame);
      return VaultVideoThumb(frameBytes: frame, fullSize: file.size);
    });

/// Extract [file] to a temp file, decode one representative frame with mpv via
/// `media_kit`/`media_kit_video`, and return it as JPEG bytes (or `null` when
/// mpv is unavailable or the file cannot be decoded).
Future<Uint8List?> _captureVideoFrame(Vault session, VaultFileInfo file) {
  return _videoCaptureGate.run(() async {
    final player = Player();
    // A bare media_kit Player runs mpv with vid=no (no video decode); attaching
    // the VideoController is what flips on vid=auto + a rendering VO so a frame
    // can actually be decoded and screenshotted.
    final controller = VideoController(player);
    final tmp = await Directory.systemTemp.createTemp('acui_video_');
    try {
      await controller.platform.future.timeout(const Duration(seconds: 10));
      // Vault names may carry characters that are invalid in Windows
      // filenames; keep only a portable token set for the temp file.
      final safeName = basenameOf(file.name)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final dest = '${tmp.path}${Platform.pathSeparator}$safeName';
      await session.extract(file.name, dest);
      await player.open(Media(dest), play: false);
      await _waitForDecodedFrame(player);
      await _seekToPreviewFrame(player);
      final frame = await player.screenshot(format: 'image/jpeg');
      return (frame == null || frame.isEmpty) ? null : frame;
    } finally {
      await player.dispose();
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup; a stale temp file is a non-issue.
      }
    }
  });
}

/// Wait until [player] has decoded at least one video frame (width known), or
/// fail after [timeout]. Both the width stream and the live state are watched,
/// so an early broadcast event that precedes the subscription can't deadlock
/// the wait.
Future<void> _waitForDecodedFrame(
  Player player, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final sawWidth = Completer<void>();
  late final StreamSubscription<int?> subscription;
  subscription = player.stream.width.listen((w) {
    if ((w ?? 0) > 0 && !sawWidth.isCompleted) sawWidth.complete();
  });
  try {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if ((player.state.width ?? 0) > 0 || sawWidth.isCompleted) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('video frame decode timed out', timeout);
  } finally {
    await subscription.cancel();
  }
}

/// Seek to a representative position (10% of the duration, or ~1 s for very
/// short clips) and let mpv render it before the screenshot.
Future<void> _seekToPreviewFrame(Player player) async {
  final duration = player.state.duration;
  final target = duration.inMilliseconds > 2000
      ? Duration(milliseconds: duration.inMilliseconds ~/ 10)
      : const Duration(seconds: 1);
  await player.seek(target);
  await Future<void>.delayed(const Duration(milliseconds: 400));
}

/// List/grid display mode for the browser, persisted across restarts.
enum BrowserView { list, grid }

class BrowserViewNotifier extends AsyncNotifier<BrowserView> {
  @override
  Future<BrowserView> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('browser_grid') == true
        ? BrowserView.grid
        : BrowserView.list;
  }

  Future<void> select(BrowserView view) async {
    state = AsyncData(view);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('browser_grid', view == BrowserView.grid);
  }
}

final browserViewProvider =
    AsyncNotifierProvider<BrowserViewNotifier, BrowserView>(
      BrowserViewNotifier.new,
    );

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

  /// Join `segment` onto the current vault folder path (`''` = root).
  String _childName(String segment) {
    final dir = ref.read(currentVaultFolderProvider);
    return dir.isEmpty ? segment : '$dir/$segment';
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
        for (final p in picked) (src: p, storedName: _childName(basenameOf(p))),
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

  /// Import every file of the picked folder plus the folder itself: stored
  /// names are prefixed with the folder's own name (e.g. `Photos/2024/1.jpg`),
  /// and empty subfolders are preserved as `.ackeep` markers.
  Future<void> importFolder() async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final root = Directory(dir.replaceAll(RegExp(r'[/\\]+$'), ''));
      final rootName = basenameOf(root.path);
      final items = <({String src, String storedName})>[];
      final markers = <String>[];

      void visit(Directory d, String rel) {
        // `rel` is the stored path of this directory including the root name.
        markers.add(_childName('$rel/$folderMarker'));
        for (final entity in d.listSync(followLinks: false)) {
          if (entity is Directory) {
            visit(entity, '$rel/${basenameOf(entity.path)}');
          } else if (entity is File) {
            items.add((
              src: entity.path,
              storedName: _childName('$rel/${basenameOf(entity.path)}'),
            ));
          }
        }
      }

      visit(root, rootName);

      var count = 0;
      if (items.isNotEmpty) {
        count = await session.addPaths(items);
      }
      // Markers are idempotent (overwrite in place), so re-importing a folder
      // never duplicates empty-directory entries.
      for (final m in markers) {
        await session.put(m, Uint8List(0));
      }
      await _reload();
      _notice(
        items.isEmpty
            ? 'Imported empty folder "$rootName".'
            : 'Imported ${_plural(count, 'file')} in "$rootName".',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Create an empty folder in the current vault folder via a hidden marker.
  Future<void> createFolder(String name) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      await session.put(_childName('$name/$folderMarker'), Uint8List(0));
      await _reload();
      _notice('Created folder "$name".');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Rename `path` to `newName`, keeping it in the same parent: the marker and
  /// every stored name under the prefix are renamed.
  Future<void> renameFolder(String path, String newName) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final parent = parentOfPath(path);
      final newPath = parent.isEmpty ? newName : '$parent/$newName';
      final oldPrefix = '$path/';
      final affected = await _namesUnder(session, oldPrefix);
      if (affected.isEmpty) {
        _notice('Folder not found.');
        return;
      }
      for (final name in affected) {
        await session.rename(
          name,
          '$newPath/${name.substring(oldPrefix.length)}',
        );
      }
      await _reload();
      _notice('Renamed folder to "$newName".');
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Delete `path` and everything inside it (files + marker entries).
  Future<void> deleteFolder(String path) async {
    if (state.busy) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final affected = await _namesUnder(session, '$path/');
      if (affected.isEmpty) {
        _notice('Folder not found.');
        return;
      }
      for (final name in affected) {
        await session.delete(name);
      }
      await _reload();
      _notice(
        'Deleted folder "${basenameOf(path)}" '
        '(${_plural(affected.length, 'item')}).',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// Extract every file of `path` into the picked directory, mirroring the
  /// stored hierarchy; the folder itself is created even when empty.
  Future<void> extractFolder(String path) async {
    if (state.busy) return;
    final dir = await ref.read(fileServiceProvider).pickDirectory();
    if (dir == null) return;
    final session = _session;
    if (session == null) return;
    _setBusy(true);
    try {
      final sep = Platform.pathSeparator;
      Directory('$dir$sep${path.replaceAll('/', sep)}')
          .createSync(recursive: true);
      final affected = await _namesUnder(session, '$path/');
      var count = 0;
      for (final name in affected) {
        if (isFolderMarker(name)) continue;
        final dest = '$dir$sep${name.replaceAll('/', sep)}';
        File(dest).parent.createSync(recursive: true);
        await session.extract(name, dest);
        count++;
      }
      await _reload();
      _notice(
        count == 0
            ? 'Extracted empty folder "${basenameOf(path)}" to $dir.'
            : 'Extracted ${_plural(count, 'item')} to $dir.',
      );
    } on AutocipherException catch (e) {
      _notice(exceptionText(e));
    } finally {
      _setBusy(false);
    }
  }

  /// All stored names under `prefix` (marker entries included).
  Future<List<String>> _namesUnder(Vault session, String prefix) async {
    final files = await session.listFiles();
    return [
      for (final f in files)
        if (f.name.startsWith(prefix)) f.name,
    ];
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
}

final vaultActionsProvider =
    NotifierProvider<VaultActionsNotifier, VaultActionsState>(
      VaultActionsNotifier.new,
    );
