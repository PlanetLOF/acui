// The vault browser: browse plaintext entries in folders (derived from stored
// name prefixes, with `.ackeep` markers persisting empty folders), import from
// the host filesystem, extract / preview / rename / delete individual files and
// folders, toggle list/grid view, and open settings.
//
// The scene is mounted by the app shell whenever a vault session is open.
// Every engine operation is dispatched through the vault providers on a
// worker isolate, so this widget is a pure consumer of Riverpod state — no
// local mutable state beyond the transient file dialogs.
//
// File pickers come from `FileService` (file_selector).

import 'dart:typed_data';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../provider/browser_provider.dart';
import '../provider/cloud_pin_provider.dart';
import '../provider/cloud_sync_provider.dart';
import '../provider/file_provider.dart';
import '../provider/session_provider.dart';
import 'cloud_sync_banner.dart';
import 'common/action_sheet.dart';
import 'format.dart';
import 'preview.dart';
import 'vault_model.dart';
import 'vault_settings_sheet.dart';

/// The open vault's file browser.
class VaultBrowserScreen extends ConsumerWidget {
  const VaultBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(vaultFilesProvider);
    final info = ref.watch(vaultInfoProvider);
    final actions = ref.watch(vaultActionsProvider);
    final dir = ref.watch(currentVaultFolderProvider);
    final view = ref.watch(browserViewProvider).value ?? BrowserView.list;
    final session = ref.watch(vaultSessionProvider);
    final inFolder = dir.isNotEmpty;

    // Surface transient results/failures from vault mutations as snackbars.
    ref.listen<String?>(vaultActionsProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    final vaultName = info.maybeWhen(
      data: (i) => basenameOf(i.path),
      orElse: () => 'Vault',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          inFolder ? dir : vaultName,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          tooltip: inFolder ? 'Up' : 'Lock vault',
          onPressed: actions.busy
              ? null
              : () {
                  if (inFolder) {
                    _goUp(ref, dir);
                  } else {
                    _lockVault(context, ref);
                  }
                },
          icon: Icon(inFolder ? Icons.arrow_back : Icons.lock_outline),
        ),
        actions: [
          IconButton(
            tooltip: 'New folder',
            onPressed: actions.busy
                ? null
                : () => _newFolderDialog(context, ref),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: view == BrowserView.grid ? 'List view' : 'Grid view',
            onPressed: actions.busy
                ? null
                : () => ref
                      .read(browserViewProvider.notifier)
                      .select(
                        view == BrowserView.grid
                            ? BrowserView.list
                            : BrowserView.grid,
                      ),
            icon: Icon(
              view == BrowserView.grid
                  ? Icons.view_list_outlined
                  : Icons.grid_view_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: actions.busy ? null : () => _refresh(ref),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: actions.busy ? null : () => showVaultSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: actions.busy ? null : () => _showImportMenu(context, ref),
        icon: const Icon(Icons.file_download_outlined),
        label: const Text(
          'IMPORT',
          style: TextStyle(fontSize: 14, letterSpacing: 1),
        ),
      ),
      body: Column(
        children: [
          if (actions.busy) const LinearProgressIndicator(minHeight: 2),
          if (session != null && session.isCloud) const CloudSyncBanner(),
          Expanded(child: _buildBody(context, ref, files, dir, view)),
        ],
      ),
    );
  }

  void _goUp(WidgetRef ref, String dir) {
    ref.read(currentVaultFolderProvider.notifier).go(parentOfPath(dir));
  }

  /// Lock the vault. Local sessions lock immediately. Cloud sessions lock
  /// immediately too when auto-sync has already pushed everything (clean
  /// state); only when edits are pending, a sync failed, or a conflict is
  /// active do we offer to upload first, so changes are never silently left
  /// behind (an upload failure keeps the vault open).
  Future<void> _lockVault(BuildContext context, WidgetRef ref) async {
    final session = ref.read(vaultSessionProvider);
    if (session == null || !session.isCloud) {
      await ref.read(vaultSessionProvider.notifier).close();
      return;
    }
    final origin = session.cloud!;
    final sync = ref.read(cloudSyncProvider);
    final needsSyncPrompt = sync.dirty || sync.busy || sync.conflict;
    if (!needsSyncPrompt) {
      await _closeAndRelease(context, ref, origin);
      return;
    }
    final choice = await showDialog<_LockDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sync before locking?'),
        content: Text(
          'Upload the current vault to ${origin.remotePath} before locking?',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_LockDecision.lockOnly),
            child: const Text('Lock without uploading'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_LockDecision.uploadAndLock),
            child: const Text('Upload & lock'),
          ),
        ],
      ),
    );
    if (choice == null || choice == _LockDecision.cancel) return;

    if (choice == _LockDecision.uploadAndLock) {
      // Wait for an in-flight auto-sync to settle, then upload; surface the
      // real reason (conflict / rclone error / busy) instead of a canned one.
      final reason = await ref
          .read(cloudSyncProvider.notifier)
          .syncWhenIdle();
      if (reason != null) {
        if (context.mounted) {
          showSnack(context, 'Upload failed — $reason The vault stays open.');
        }
        return;
      }
    }
    if (!context.mounted) {
      // Widget gone mid-flow — release the session without UI feedback.
      await ref.read(vaultSessionProvider.notifier).close();
      return;
    }
    await _closeAndRelease(context, ref, origin);
  }

  /// Close the session, then apply the vault's cache pin:
  ///   - online-only + nothing pending → purge the cache copy (no disk use);
  ///   - online-only + pending edits → keep it and say so (never delete the
  ///     only copy of unsynced changes);
  ///   - available offline → keep it.
  Future<void> _closeAndRelease(
    BuildContext context,
    WidgetRef ref,
    CloudOrigin origin,
  ) async {
    final pin = await ref.read(cloudPinProvider.notifier).pinFor(
      origin.remotePath,
    );
    final pending =
        ref.read(cloudSyncProvider).dirty ||
        ref.read(cloudSyncProvider).conflict;
    final isOnlineOnly = pin.mode == CloudPinMode.onlineOnly;
    if (isOnlineOnly && pending && context.mounted) {
      showSnack(
        context,
        'Changes were not uploaded — the cached copy stays on disk '
        '(nothing is lost).',
      );
    }
    await ref.read(vaultSessionProvider.notifier).close();
    if (isOnlineOnly && !pending) {
      await ref.read(fileServiceProvider).deleteVaultCache(origin.cachePath);
    }
  }

  void _enterFolder(WidgetRef ref, String path) {
    ref.read(currentVaultFolderProvider.notifier).go(path);
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(vaultFilesProvider);
    ref.invalidate(vaultInfoProvider);
  }

  Future<void> _pullToRefresh(WidgetRef ref) async {
    ref.invalidate(vaultFilesProvider);
    ref.invalidate(vaultInfoProvider);
    await ref.read(vaultFilesProvider.future);
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<VaultFileInfo>> files,
    String dir,
    BrowserView view,
  ) {
    return files.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 8),
              Text(describeEngineError(e), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _refresh(ref),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
            child: Text('Empty vault — use Import to add files.'),
          );
        }
        final entries = buildBrowserEntries(list, dir);
        if (entries.isEmpty) {
          return const Center(child: Text('Empty folder.'));
        }
        return RefreshIndicator(
          onRefresh: () => _pullToRefresh(ref),
          child: view == BrowserView.grid
              ? _buildGrid(context, ref, entries)
              : _buildList(context, ref, entries),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    WidgetRef ref,
    List<VaultBrowserEntry> entries,
  ) {
    return ListView.builder(
      // Clearance so the floating IMPORT button never covers the last row's
      // Actions (⋯) popup.
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.isFolder) {
          final folder = entry.folder!;
          return ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            subtitle: Text(
              folder.childCount == 0
                  ? 'Empty'
                  : '${folder.childCount} '
                        '${folder.childCount == 1 ? 'item' : 'items'}',
            ),
            trailing: IconButton(
              tooltip: 'Actions',
              onPressed: () => _showFolderActions(context, ref, folder),
              icon: const Icon(Icons.more_vert),
            ),
            onTap: () => _enterFolder(ref, folder.path),
          );
        }
        final file = entry.file!;
        return ListTile(
          leading: _FileLeading(file: file),
          title: Text(entry.displayName),
          subtitle: Text(formatBytes(file.size)),
          trailing: IconButton(
            tooltip: 'Actions',
            onPressed: () => _showFileActions(context, ref, file),
            icon: const Icon(Icons.more_vert),
          ),
          onTap: () => _preview(context, ref, file),
        );
      },
    );
  }

  Widget _buildGrid(
    BuildContext context,
    WidgetRef ref,
    List<VaultBrowserEntry> entries,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final String subtitle = entry.isFolder
            ? (entry.folder!.childCount == 0
                  ? 'Empty'
                  : '${entry.folder!.childCount} '
                        '${entry.folder!.childCount == 1 ? 'item' : 'items'}')
            : formatBytes(entry.file!.size);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (entry.isFolder) {
                _enterFolder(ref, entry.folder!.path);
              } else {
                _preview(context, ref, entry.file!);
              }
            },
            onLongPress: () {
              if (entry.isFolder) {
                _showFolderActions(context, ref, entry.folder!);
              } else {
                _showFileActions(context, ref, entry.file!);
              }
            },
            child: Column(
              children: [
                Expanded(child: _GridTileVisual(entry: entry)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                  child: Column(
                    children: [
                      Text(
                        entry.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showImportMenu(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(vaultActionsProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => ActionSheet(
        title: 'IMPORT INTO VAULT',
        children: [
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('Import files…'),
            subtitle: const Text('Add one or more plaintext files'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.importFiles();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Import folder…'),
            subtitle: const Text('Import a folder with its whole tree'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.importFolder();
            },
          ),
        ],
      ),
    );
  }

  void _showFolderActions(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => ActionSheet(
        title: 'FOLDER ACTIONS',
        children: [
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Open'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _enterFolder(ref, folder.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _renameFolderDialog(context, ref, folder);
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Extract…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(vaultActionsProvider.notifier)
                  .extractFolder(folder.path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _deleteFolderDialog(context, ref, folder);
            },
          ),
        ],
      ),
    );
  }

  void _showFileActions(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => ActionSheet(
        title: 'FILE ACTIONS',
        children: [
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('Preview'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _preview(context, ref, file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Extract…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref.read(vaultActionsProvider.notifier).extract(file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _renameDialog(context, ref, file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _deleteFile(context, ref, file);
            },
          ),
        ],
      ),
    );
  }

  void _preview(BuildContext context, WidgetRef ref, VaultFileInfo file) {
    showDialog<void>(
      context: context,
      // With media_kit removed there is no video decode/preview, so videos
      // open a placeholder dialog instead of _PreviewDialog.
      builder: (_) => isVideoName(file.name)
          ? _VideoPlaceholderDialog(file: file)
          : _PreviewDialog(name: file.name),
    );
  }

  /// True when an entry named [name] already exists in the current folder.
  Future<bool> _nameExists(WidgetRef ref, String name) async {
    final dir = ref.read(currentVaultFolderProvider);
    final files = await ref.read(vaultFilesProvider.future);
    return buildBrowserEntries(files, dir).any((e) => e.displayName == name);
  }

  String _joinDir(WidgetRef ref, String segment) {
    final dir = ref.read(currentVaultFolderProvider);
    return dir.isEmpty ? segment : '$dir/$segment';
  }

  Future<void> _newFolderDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return;
    final trimmed = name.trim();
    if (!isValidFolderName(trimmed)) {
      showSnack(context, 'Invalid folder name.');
      return;
    }
    if (await _nameExists(ref, trimmed)) {
      if (!context.mounted) return;
      showSnack(
        context,
        'A file or folder named "$trimmed" already exists here.',
      );
      return;
    }
    await ref.read(vaultActionsProvider.notifier).createFolder(trimmed);
  }

  Future<void> _renameFolderDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) async {
    final controller = TextEditingController(text: folder.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName == folder.name || !context.mounted) {
      return;
    }
    final trimmed = newName.trim();
    if (!isValidFolderName(trimmed)) {
      showSnack(context, 'Invalid folder name.');
      return;
    }
    final siblings = await _nameExists(ref, trimmed);
    if (siblings) {
      if (!context.mounted) return;
      showSnack(
        context,
        'A file or folder named "$trimmed" already exists here.',
      );
      return;
    }
    await ref
        .read(vaultActionsProvider.notifier)
        .renameFolder(folder.path, trimmed);
  }

  Future<void> _deleteFolderDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFolder folder,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete folder'),
        content: Text(
          'Remove "${folder.name}" and its '
          '${folder.childCount == 0 ? 'contents' : '${folder.childCount} items'} '
          'from the vault?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.deleteFolder(folder.path);
    }
  }

  Future<void> _renameDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final controller = TextEditingController(text: basenameOf(file.name));
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Stored name'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null ||
        newName.isEmpty ||
        newName == basenameOf(file.name) ||
        !context.mounted) {
      return;
    }
    if (newName.contains('/') || newName.contains('\\')) {
      showSnack(context, 'Renames stay within the current folder.');
      return;
    }
    if (await _nameExists(ref, newName)) {
      if (!context.mounted) return;
      showSnack(
        context,
        'A file or folder named "$newName" already exists here.',
      );
      return;
    }
    await notifier.rename(file.name, _joinDir(ref, newName));
  }

  Future<void> _deleteFile(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete file'),
        content: Text('Remove "${basenameOf(file.name)}" from the vault?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.delete(file.name);
    }
  }
}

/// The top visual zone of a grid tile: a real raster thumbnail for image
/// files, a movie icon with a play badge for videos, and the plain type icon
/// for folders and other files. The zone keeps a consistent aspect ratio so
/// tiles stay uniform regardless of the source image's proportions.
class _GridTileVisual extends ConsumerWidget {
  const _GridTileVisual({required this.entry});

  final VaultBrowserEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: SizedBox.expand(child: _buildVisual(context, ref)),
    );
  }

  Widget _buildVisual(BuildContext context, WidgetRef ref) {
    if (entry.isFolder) {
      return const Center(child: Icon(Icons.folder_outlined, size: 40));
    }
    final file = entry.file!;
    if (isVideoName(file.name)) {
      return const Center(child: Icon(Icons.movie_outlined, size: 40));
    }
    if (isImageName(file.name)) {
      const placeholder = Center(child: Icon(Icons.image_outlined, size: 32));
      return ref
          .watch(vaultImageThumbProvider(file.name))
          .when(
            loading: () => placeholder,
            error: (_, _) => placeholder,
            data: (bytes) => Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: 220,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            ),
          );
    }
    return const Center(child: Icon(Icons.description_outlined, size: 40));
  }
}

/// A 40×40 rounded raster thumbnail for image rows in list view; the generic
/// file icon otherwise.
class _FileLeading extends ConsumerWidget {
  const _FileLeading({required this.file});

  final VaultFileInfo file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isVideoName(file.name)) {
      return const Icon(Icons.movie_outlined);
    }
    if (!isImageName(file.name)) {
      return const Icon(Icons.description_outlined);
    }
    const placeholder = Icon(Icons.description_outlined);
    return ref
        .watch(vaultImageThumbProvider(file.name))
        .when(
          loading: () => placeholder,
          error: (_, _) => placeholder,
          data: (bytes) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              bytes,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              cacheWidth: 80,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => placeholder,
            ),
          ),
        );
  }
}

/// What opens when a video is tapped. media_kit was removed, so there is no
/// decoder or preview for videos anymore — the dialog just identifies the
/// file and points at Extract. Deliberately minimal and read-free.
class _VideoPlaceholderDialog extends StatelessWidget {
  const _VideoPlaceholderDialog({required this.file});

  final VaultFileInfo file;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(basenameOf(file.name)),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.movie_outlined, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              '${formatBytes(file.size)}\n'
              'Video preview is not available — use Extract to view it.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Modal preview of a non-video entry; reads the file through
/// [vaultPreviewProvider] so the loading/error states live inside the dialog,
/// then renders it by kind — images/SVG natively, text as selectable
/// monospace, anything else as a hex dump (see `preview.dart`). Videos open
/// [_VideoPlaceholderDialog] instead.
class _PreviewDialog extends ConsumerWidget {
  const _PreviewDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(vaultPreviewProvider(name));
    final notifier = ref.read(vaultActionsProvider.notifier);

    return AlertDialog(
      title: Text(basenameOf(name)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 400),
        child: preview.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Text('Failed to preview: ${describeEngineError(e)}'),
          ),
          data: (p) {
            final sizeLine =
                '${formatBytes(p.fullSize)} · '
                '${p.truncated ? 'first ${formatBytes(previewCap)} shown' : 'full file'}';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sizeLine, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Flexible(
                  child: _PreviewBody(
                    kind: previewKindOf(name, p.bytes),
                    bytes: p.bytes,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ...?preview.maybeWhen(
          data: (p) => [
            OutlinedButton.icon(
              onPressed: () => notifier.saveFileAs(name, p.bytes),
              icon: const Icon(Icons.save_alt),
              label: const Text('Save as…'),
            ),
          ],
          orElse: () => const <Widget>[],
        ),
      ],
    );
  }
}

/// Renders a file's bytes according to its [PreviewKind]: images and SVG
/// natively (falling back to the hex view when the decoder rejects them),
/// text as selectable monospace, everything else as a hex dump.
class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.kind, required this.bytes});

  final PreviewKind kind;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case PreviewKind.image:
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _HexView(bytes: bytes),
        );
      case PreviewKind.svg:
        return SvgPicture.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _HexView(bytes: bytes),
        );
      case PreviewKind.video:
        return Stack(
          alignment: Alignment.center,
          children: [
            Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _HexView(bytes: bytes),
            ),
            const Icon(Icons.play_circle_fill, size: 56, color: Colors.white70),
          ],
        );
      case PreviewKind.text:
        return SingleChildScrollView(
          child: SelectableText(
            decodeText(bytes),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        );
      case PreviewKind.binary:
        return _HexView(bytes: bytes);
    }
  }
}

/// A monospace hex dump of the preview content (capped rows so a large read
/// never blows up the dialog).
class _HexView extends StatelessWidget {
  const _HexView({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        hexDump(bytes),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

/// What the cloud lock prompt decided.
enum _LockDecision { uploadAndLock, lockOnly, cancel }
