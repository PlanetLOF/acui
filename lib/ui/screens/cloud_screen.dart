// The CLOUD provider tab: browse configured rclone remotes, drill into
// folders, and open / save / create `.ac` vaults there. Remote configuration
// happens through rclone's own wizard (launched via NEW REMOTE…), then this
// screen lists whatever remotes exist in `rclone.conf`.
//
// Vaults carry a cache pin (see `cloud_pin_provider.dart`): "online only"
// (default — download on open, purge on lock) or "available offline" (the
// cached copy is reused and can be opened without the network).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/cloud_browser_provider.dart';
import '../../provider/cloud_pin_provider.dart';
import '../../provider/cloud_sync_provider.dart';
import '../../provider/rclone_provider.dart';
import '../../provider/session_provider.dart';
import '../cloud_dialogs.dart';
import '../common/fields.dart';
import '../common/section_header.dart';
import '../format.dart';
import '../rclone_settings_sheet.dart';

class CloudScreen extends ConsumerWidget {
  const CloudScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudBrowserProvider);
    final notifier = ref.read(cloudBrowserProvider.notifier);
    final remotes = ref.watch(cloudRemotesProvider);
    final entries = ref.watch(cloudEntriesProvider);

    // Surface transient browser results/failures as snackbars.
    ref.listen<String?>(cloudBrowserProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });
    // Background sync messages (e.g. while the browser sits on another tab).
    ref.listen<String?>(cloudSyncProvider.select((s) => s.notice), (_, notice) {
      if (notice != null) showSnack(context, notice);
    });

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              const SectionHeader('CLOUD STORAGE (RCLONE)'),
              const Divider(),
              if (state.busy) const LinearProgressIndicator(minHeight: 2),
              _RemoteRow(
                remotes: remotes,
                selected: state.selectedRemote,
                onSelect: notifier.selectRemote,
                onRefresh: notifier.refresh,
              ),
              _PathBar(
                remotePath: notifier.currentRemotePath,
                onUp: state.dir.isEmpty ? null : notifier.up,
                onRefresh: notifier.refresh,
              ),
              _EntryList(
                entries: entries,
                busy: state.busy,
                onEnterDir: (e) =>
                    notifier.enterDir(e.path.isEmpty ? e.name : e.path),
                onOpenVault: (e) => _openVault(context, ref, e),
                onSaveAs: (e) => notifier.saveAs(e),
                onDelete: (e) => _deleteVault(context, ref, e),
                onRetry: notifier.refresh,
              ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.busy ? null : notifier.newRemote,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('NEW REMOTE…'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: notifier.effectiveRemote == null || state.busy
                          ? null
                          : () => _createVault(context, ref),
                      icon: const Icon(Icons.add_box_outlined),
                      label: const Text('CREATE VAULT HERE'),
                    ),
                  ),
                ],
              ),
              if (notifier.effectiveRemote == null)
                Text(
                  'No rclone remote yet — tap NEW REMOTE… to configure one, '
                  'then REFRESH.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openVault(
    BuildContext context,
    WidgetRef ref,
    RcloneEntry entry,
  ) async {
    final notifier = ref.read(cloudBrowserProvider.notifier);
    if (entry.isDir) {
      notifier.enterDir(entry.path.isEmpty ? entry.name : entry.path);
      return;
    }
    final location = notifier.currentRemotePath;
    if (location == null) return;
    final (remote, dir) = splitRemotePath(location);
    final remotePath = remotePathOf(remote, [dir, entry.name]);
    final cachePath = await notifier.cachePathFor(entry);
    final pin = await ref.read(cloudPinProvider.notifier).pinFor(remotePath);

    // "Available offline" + an existing cache copy = open straight from disk
    // (works without the network). Everything else downloads first.
    final fromCache = pin.mode == CloudPinMode.offline &&
        File(cachePath).existsSync();
    final String usedCachePath;
    if (fromCache) {
      usedCachePath = cachePath;
    } else {
      try {
        usedCachePath = await notifier.downloadToCache(entry);
      } on RcloneException catch (e) {
        if (context.mounted) {
          showSnack(context, 'Download failed: ${e.message}');
        }
        return;
      } catch (e) {
        if (context.mounted) showSnack(context, 'Download failed: $e');
        return;
      }
      // The download is the remote content — record its fingerprint so a
      // later from-cache open has a correct conflict baseline.
      await ref
          .read(cloudPinProvider.notifier)
          .recordSync(remotePath, entry.size, entry.modTime);
    }
    if (!context.mounted) return;

    // Baseline for the conflict guard: for a cache open use the stored
    // fingerprint (the remote state at last sync), falling back to the
    // listing; for a download use the fresh listing.
    final stateAtOpen = fromCache
        ? RemoteState(
            pin.lastSize ?? entry.size,
            pin.lastModTime ?? entry.modTime,
          )
        : RemoteState(entry.size, entry.modTime);
    await showDialog<bool>(
      context: context,
      builder: (_) => CloudOpenVaultDialog(
        vaultName: entry.name,
        onSubmit: (password) async {
          await ref
              .read(vaultSessionProvider.notifier)
              .open(
                usedCachePath,
                password,
                cloud: CloudOrigin(
                  remotePath: remotePath,
                  cachePath: usedCachePath,
                  stateAtOpen: stateAtOpen,
                ),
              );
          ref
              .read(cloudSyncProvider.notifier)
              .reset(
                CloudOrigin(
                  remotePath: remotePath,
                  cachePath: usedCachePath,
                  stateAtOpen: stateAtOpen,
                ),
              );
          if (fromCache) {
            // Push offline edits (or pick up remote changes) through the
            // normal conflict guard; rclone skips when the bytes match.
            ref.read(cloudSyncProvider.notifier).syncNow();
          }
        },
      ),
    );
    // Success: the session is set and the shell switches to the vault browser
    // (which receives the sync baseline above).
  }

  Future<void> _createVault(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(cloudBrowserProvider.notifier);
    return showDialog<bool>(
      context: context,
      builder: (_) => CloudCreateDialog(
        onSubmit: (name, password, preset) => notifier.createVaultInCloud(
          name: name,
          password: password,
          preset: preset,
        ),
      ),
    );
  }

  Future<void> _deleteVault(
    BuildContext context,
    WidgetRef ref,
    RcloneEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete from cloud'),
        content: Text(
          'Remove "${entry.name}" permanently from '
          '${ref.read(cloudBrowserProvider.notifier).currentRemotePath ?? 'the cloud'}?',
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
      await ref.read(cloudBrowserProvider.notifier).deleteRemoteFile(entry);
    }
  }
}

/// The remote picker row: dropdown of configured remotes, settings, and a
/// helper text when no rclone remote exists yet.
class _RemoteRow extends StatelessWidget {
  const _RemoteRow({
    required this.remotes,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
  });

  final AsyncValue<List<RcloneRemote>> remotes;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return remotes.when(
      loading: () => const SizedBox(
        height: 72,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'rclone unavailable: $e',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'No rclone remotes configured. Use NEW REMOTE… to open the '
                'rclone wizard and create one (Google Drive, OneDrive, '
                'Dropbox, Terabox, …).',
              ),
            ],
          );
        }
        final effective = list.any((r) => r.name == selected)
            ? selected
            : list.first.name;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: AcDropdown<String>(
                label: 'RCLONE REMOTE',
                value: effective!,
                options: {for (final r in list) r.name: r.toString()},
                onChanged: onSelect,
              ),
            ),
            IconButton(
              tooltip: 'rclone settings',
              onPressed: () => showRcloneSettings(context),
              icon: const Icon(Icons.settings_outlined),
            ),
            IconButton(
              tooltip: 'Refresh remotes',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        );
      },
    );
  }
}

/// Current remote folder + navigation (up / refresh).
class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.remotePath,
    required this.onUp,
    required this.onRefresh,
  });

  final String? remotePath;
  final VoidCallback? onUp;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Up',
          onPressed: onUp,
          icon: const Icon(Icons.arrow_upward),
        ),
        IconButton(
          tooltip: 'Refresh listing',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            remotePath ?? 'Select a remote to browse its folders.',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// The folder + `.ac` file listing of the current remote location.
class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.entries,
    required this.busy,
    required this.onEnterDir,
    required this.onOpenVault,
    required this.onSaveAs,
    required this.onDelete,
    required this.onRetry,
  });

  final AsyncValue<List<RcloneEntry>> entries;
  final bool busy;
  final ValueChanged<RcloneEntry> onEnterDir;
  final ValueChanged<RcloneEntry> onOpenVault;
  final ValueChanged<RcloneEntry> onSaveAs;
  final ValueChanged<RcloneEntry> onDelete;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return entries.when(
      loading: () => const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Failed to list remote folder: $e',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
      data: (list) {
        final folders = [
          for (final e in list)
            if (e.isDir && e.name != '.' && e.name != '..') e,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final vaults = [
          for (final e in list)
            if (!e.isDir && e.isVault) e,
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final all = [...folders, ...vaults];

        if (all.isEmpty) {
          return const SizedBox(
            height: 120,
            child: Center(
              child: Text('Empty folder — use CREATE VAULT HERE to add one.'),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in all)
              e.isDir
                  ? _FolderTile(entry: e, onOpen: onEnterDir)
                  : _VaultTile(
                      entry: e,
                      busy: busy,
                      onOpen: onOpenVault,
                      onSaveAs: onSaveAs,
                      onDelete: onDelete,
                    ),
          ],
        );
      },
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.entry, required this.onOpen});

  final RcloneEntry entry;
  final ValueChanged<RcloneEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.folder_outlined),
      title: Text(entry.name),
      onTap: () => onOpen(entry),
    );
  }
}

class _VaultTile extends ConsumerWidget {
  const _VaultTile({
    required this.entry,
    required this.busy,
    required this.onOpen,
    required this.onSaveAs,
    required this.onDelete,
  });

  final RcloneEntry entry;
  final bool busy;
  final ValueChanged<RcloneEntry> onOpen;
  final ValueChanged<RcloneEntry> onSaveAs;
  final ValueChanged<RcloneEntry> onDelete;

  /// The `remote:folder/name` of this vault row.
  String _remotePath(WidgetRef ref) {
    final location = ref.read(cloudBrowserProvider.notifier).currentRemotePath;
    if (location == null) return entry.name;
    final (remote, dir) = splitRemotePath(location);
    return remotePathOf(remote, [dir, entry.name]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remotePath = _remotePath(ref);
    final pins = ref.watch(cloudPinProvider).value ?? const {};
    final offline =
        pins[remotePath]?.mode == CloudPinMode.offline;

    return ListTile(
      dense: true,
      leading: Icon(
        offline ? Icons.offline_pin : Icons.cloud_outlined,
        color: offline ? Colors.green.shade700 : null,
      ),
      title: Text(entry.name),
      subtitle: Text(
        '${formatBytes(entry.size)} · '
        '${offline ? 'available offline' : 'online only'}',
      ),
      trailing: IconButton(
        tooltip: 'Actions',
        onPressed: busy
            ? null
            : () => showModalBottomSheet<void>(
                context: context,
                builder: (sheetContext) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.lock_open_outlined),
                      title: const Text('Open in acui…'),
                      subtitle: const Text('Download, unlock, and edit'),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onOpen(entry);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined),
                      title: const Text('Online only'),
                      subtitle: const Text(
                        'Uses no device storage; needs internet to open '
                        '(cache purged when locked)',
                      ),
                      trailing: offline ? const Icon(Icons.check) : null,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        if (offline) {
                          ref
                              .read(cloudPinProvider.notifier)
                              .setMode(remotePath, CloudPinMode.onlineOnly);
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.offline_pin),
                      title: const Text('Available offline'),
                      subtitle: const Text(
                        'Keeps a copy on this device — open it without the '
                        'network; edits sync when back online',
                      ),
                      trailing: offline ? null : const Icon(Icons.check),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        if (!offline) {
                          ref
                              .read(cloudPinProvider.notifier)
                              .setMode(remotePath, CloudPinMode.offline);
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: const Text('Save as…'),
                      subtitle: const Text('Download to a local folder'),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onSaveAs(entry);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('Delete from cloud…'),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onDelete(entry);
                      },
                    ),
                  ],
                ),
              ),
        icon: const Icon(Icons.more_vert),
      ),
      onTap: busy ? null : () => onOpen(entry),
    );
  }
}
