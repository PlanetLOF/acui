// The cloud banner shown on top of the vault browser for cloud-backed
// sessions: the remote location, sync status, a manual SYNC NOW, conflict
// resolution, and "make a local copy".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../provider/cloud_sync_provider.dart';
import '../provider/file_provider.dart';
import '../provider/session_provider.dart';
import 'format.dart';

class CloudSyncBanner extends ConsumerWidget {
  const CloudSyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(vaultSessionProvider);
    final origin = session?.cloud;
    if (origin == null) return const SizedBox.shrink();
    final sync = ref.watch(cloudSyncProvider);

    ref.listen<CloudSyncState>(cloudSyncProvider, (_, state) {
      if (state.notice != null) showSnack(context, state.notice!);
    });

    final String status;
    if (sync.busy) {
      status = 'Syncing…';
    } else if (sync.conflict) {
      status =
          'The cloud copy changed since you opened it — resolve the '
          'conflict before syncing.';
    } else if (sync.offline) {
      status = "Offline — changes will sync when you're back online.";
    } else if (sync.dirty) {
      status = 'Changes pending…';
    } else if (sync.lastSync != null) {
      final t = sync.lastSync!;
      status =
          'Synced at ${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
    } else {
      status = 'Opened from cloud — changes sync automatically.';
    }

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(
              sync.conflict
                  ? Icons.error_outline
                  : sync.offline
                  ? Icons.cloud_off_outlined
                  : sync.dirty
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
              size: 20,
              color: sync.conflict ? scheme.error : scheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    origin.remotePath,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    status,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (sync.conflict)
              FilledButton.tonal(
                onPressed: sync.busy
                    ? null
                    : () => _resolveDialog(context, ref),
                child: const Text('Resolve…'),
              )
            else
              TextButton(
                onPressed: sync.busy
                    ? null
                    : () => ref.read(cloudSyncProvider.notifier).syncNow(),
                child: const Text('SYNC NOW'),
              ),
            IconButton(
              tooltip: 'Make a local copy…',
              onPressed: sync.busy ? null : () => _makeLocalCopy(context, ref),
              icon: const Icon(Icons.save_alt),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _makeLocalCopy(BuildContext context, WidgetRef ref) async {
    final origin = ref.read(vaultSessionProvider)?.cloud;
    final session = ref.read(vaultSessionProvider);
    if (origin == null || session == null) return;
    var destName = origin.remotePath;
    final i = destName.lastIndexOf('/');
    if (i != -1) destName = destName.substring(i + 1);
    if (destName.isEmpty) destName = 'vault.ac';

    final loc = await ref.read(fileServiceProvider).saveVaultAs(destName);
    if (loc == null) return;
    try {
      await File(origin.cachePath).copy(loc);
      if (context.mounted) showSnack(context, 'Local copy saved to $loc');
    } catch (e) {
      if (context.mounted) showSnack(context, 'Save failed: $e');
    }
  }

  Future<void> _resolveDialog(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(cloudSyncProvider.notifier);
    final choice = await showDialog<_ResolveChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cloud conflict'),
        content: const Text(
          'The cloud copy of this vault changed since you opened it. '
          'Choose how to resolve:',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ResolveChoice.reload),
            child: const Text('Reload from cloud'),
          ),
          FilledButton.tonal(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ResolveChoice.overwrite),
            child: const Text('Overwrite cloud'),
          ),
        ],
      ),
    );

    switch (choice) {
      case _ResolveChoice.overwrite:
        final reason = await notifier.overwriteRemote();
        if (reason != null && context.mounted) {
          showSnack(context, 'Upload failed — $reason');
        }
        break;
      case _ResolveChoice.reload:
        await notifier.reloadFromRemote();
        break;
      case null:
        break;
    }
  }
}

enum _ResolveChoice { overwrite, reload }
