// The vault browser: list plaintext entries, import from the host filesystem,
// extract / preview / rename / delete individual files, and open settings.
//
// The scene is mounted by the app shell whenever a vault session is open.
// Every engine operation is dispatched through the vault providers on a
// worker isolate, so this widget is a pure consumer of Riverpod state — no
// local mutable state beyond the transient file dialogs.
//
// File pickers come from `FileService` (file_selector).

import 'dart:convert';

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../provider/browser_provider.dart';
import '../provider/session_provider.dart';
import 'common/action_sheet.dart';
import 'format.dart';
import 'vault_settings_sheet.dart';

/// The open vault's file browser.
class VaultBrowserScreen extends ConsumerWidget {
  const VaultBrowserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(vaultFilesProvider);
    final info = ref.watch(vaultInfoProvider);
    final actions = ref.watch(vaultActionsProvider);

    // Surface transient results/failures from vault mutations as snackbars.
    ref.listen<String?>(vaultActionsProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    final title = info.maybeWhen(
      data: (i) => basenameOf(i.path),
      orElse: () => 'Vault',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          tooltip: 'Lock vault',
          onPressed: actions.busy
              ? null
              : () => ref.read(vaultSessionProvider.notifier).close(),
          icon: const Icon(Icons.lock_outline),
        ),
        actions: [
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
          Expanded(child: _buildBody(context, ref, files)),
        ],
      ),
    );
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
        return RefreshIndicator(
          onRefresh: () => _pullToRefresh(ref),
          child: ListView.builder(
            // Clearance so the floating IMPORT button never covers the last
            // row's Actions (⋯) popup.
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            itemBuilder: (context, index) {
              final file = list[index];
              return ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(file.name),
                subtitle: Text(formatBytes(file.size)),
                trailing: IconButton(
                  tooltip: 'Actions',
                  onPressed: () => _showFileActions(context, ref, file),
                  icon: const Icon(Icons.more_vert),
                ),
                onTap: () => _preview(context, ref, file),
              );
            },
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
            subtitle: const Text('Walk a folder, preserving structure'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              notifier.importFolder();
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
              _fileAction(context, ref, 'preview', file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Extract…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _fileAction(context, ref, 'extract', file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Rename…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _fileAction(context, ref, 'rename', file);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete…'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _fileAction(context, ref, 'delete', file);
            },
          ),
        ],
      ),
    );
  }

  void _preview(BuildContext context, WidgetRef ref, VaultFileInfo file) {
    showDialog<void>(
      context: context,
      builder: (_) => _PreviewDialog(name: file.name),
    );
  }

  Future<void> _renameDialog(
    BuildContext context,
    WidgetRef ref,
    VaultFileInfo file,
  ) async {
    final notifier = ref.read(vaultActionsProvider.notifier);
    final controller = TextEditingController(text: file.name);
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
    if (newName == null || newName.isEmpty || newName == file.name) {
      return;
    }
    await notifier.rename(file.name, newName);
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
        content: Text('Remove "${file.name}" from the vault?'),
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

  void _fileAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    VaultFileInfo file,
  ) {
    switch (action) {
      case 'preview':
        _preview(context, ref, file);
      case 'extract':
        ref.read(vaultActionsProvider.notifier).extract(file);
      case 'rename':
        _renameDialog(context, ref, file);
      case 'delete':
        _deleteFile(context, ref, file);
    }
  }
}

/// Modal preview of a plaintext entry; reads the file through
/// [vaultPreviewProvider] so the loading/error states live inside the dialog.
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
            final text = utf8.decode(p.bytes, allowMalformed: true);
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
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
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
