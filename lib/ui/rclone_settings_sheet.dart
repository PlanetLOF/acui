// rclone settings: binary path override, the config wizard launcher, and the
// list of configured remotes (with delete). Opened from the CLOUD tab.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../provider/cloud_browser_provider.dart';
import '../provider/file_provider.dart';
import '../provider/rclone_provider.dart';
import 'common/section_header.dart';
import 'format.dart';

/// Show the modal rclone settings sheet.
Future<void> showRcloneSettings(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const RcloneSettingsSheet(),
  );
}

class RcloneSettingsSheet extends ConsumerWidget {
  const RcloneSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remotes = ref.watch(cloudRemotesProvider);
    final binary = ref.watch(rcloneSettingsProvider);
    final service = ref.read(rcloneServiceProvider);

    ref.listen<String?>(
      cloudRemotesProvider.select(
        (s) => s.hasError ? s.error.toString() : null,
      ),
      (_, error) {
        if (error != null) showSnack(context, 'Failed to read remotes: $error');
      },
    );

    final configPath = Platform.environment['APPDATA'] != null
        ? '${Platform.environment['APPDATA']}${Platform.pathSeparator}'
              'rclone${Platform.pathSeparator}rclone.conf'
        : '~/.config/rclone/rclone.conf';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: SectionHeader('RCLONE SETTINGS'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 6),
              child: Divider(),
            ),
            Text(
              'Config file: $configPath',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => _launchWizard(context, ref),
              icon: const Icon(Icons.terminal),
              label: const Text('Open rclone config wizard…'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => ref.invalidate(cloudRemotesProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh remotes'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(),
            ),
            _BinaryPathRow(binary: binary, service: service),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(),
            ),
            const _CacheDirRow(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(),
            ),
            const SectionHeader('REMOTES', small: true),
            const SizedBox(height: 8),
            remotes.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (e, _) => Text(
                'Unable to list remotes: $e',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              data: (list) => list.isEmpty
                  ? const Text('No remotes configured yet.')
                  : Column(
                      children: [
                        for (final r in list)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.cloud_outlined),
                            title: Text(r.name),
                            subtitle: Text(
                              r.type.isEmpty ? 'rclone remote' : r.type,
                            ),
                            trailing: IconButton(
                              tooltip: 'Delete remote',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  _deleteRemote(context, ref, r.name),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchWizard(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(rcloneServiceProvider).launchRcloneConfig();
      if (context.mounted) {
        showSnack(
          context,
          'rclone config opened in a terminal — create your remote, close '
          'the window, then tap Refresh remotes.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Could not open rclone config: $e');
      }
    }
  }

  Future<void> _deleteRemote(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete remote'),
        content: Text(
          'Remove the rclone remote "$name"? It only deletes the stored '
          'credentials — cloud files stay untouched.',
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
      try {
        await ref.read(rcloneServiceProvider).deleteRemote(name);
        ref.invalidate(cloudRemotesProvider);
        if (context.mounted) showSnack(context, 'Deleted remote $name.');
      } catch (e) {
        if (context.mounted) showSnack(context, 'Delete failed: $e');
      }
    }
  }
}

/// rclone binary path override row: current value (or PATH), BROWSE to pick
/// an exe, SAVE/CLEAR.
class _BinaryPathRow extends ConsumerStatefulWidget {
  const _BinaryPathRow({required this.binary, required this.service});

  final AsyncValue<String?> binary;
  final RcloneService service;

  @override
  ConsumerState<_BinaryPathRow> createState() => _BinaryPathRowState();
}

class _BinaryPathRowState extends ConsumerState<_BinaryPathRow> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.binary.whenData((v) => _controller.text = v ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final path = await ref.read(fileServiceProvider).pickExecutable();
    if (path != null) {
      setState(() => _controller.text = path);
    }
  }

  Future<void> _save() async {
    await ref.read(rcloneSettingsProvider.notifier).setPath(_controller.text);
    if (mounted) showSnack(context, 'rclone binary updated.');
  }

  Future<void> _clear() async {
    await ref.read(rcloneSettingsProvider.notifier).setPath(null);
    setState(() => _controller.text = '');
    if (mounted) showSnack(context, 'Using rclone from PATH.');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('RCLONE BINARY', small: true),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            labelText: 'Path to rclone executable',
            hintText: 'rclone (from PATH)',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _browse,
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse…'),
            ),
            const Spacer(),
            TextButton(
              onPressed: _clear,
              child: const Text('Clear (use PATH)'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _controller.text.trim().isEmpty ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Cloud-cache folder row: where downloaded vaults are kept. Empty = the app
/// default (`<home>/acui`).
class _CacheDirRow extends ConsumerStatefulWidget {
  const _CacheDirRow();

  @override
  ConsumerState<_CacheDirRow> createState() => _CacheDirRowState();
}

class _CacheDirRowState extends ConsumerState<_CacheDirRow> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(cloudCacheDirProvider).whenData((v) {
      if (mounted) _controller.text = v ?? '';
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final path = await ref.read(fileServiceProvider).pickDirectory();
    if (path != null) setState(() => _controller.text = path);
  }

  Future<void> _save() async {
    final ok = await ref
        .read(cloudCacheDirProvider.notifier)
        .setDir(_controller.text);
    if (!mounted) return;
    showSnack(
      context,
      ok
          ? 'Cloud cache folder updated.'
          : 'Cannot use that folder (must be an absolute path that can be '
                'created) — keeping the current one.',
    );
  }

  Future<void> _reset() async {
    await ref.read(cloudCacheDirProvider.notifier).setDir(null);
    setState(() => _controller.text = '');
    if (mounted) showSnack(context, 'Using the default cloud cache folder.');
  }

  @override
  Widget build(BuildContext context) {
    // Keep the field in sync if the setting changes elsewhere.
    ref.listen<AsyncValue<String?>>(cloudCacheDirProvider, (prev, next) {
      final v = next.value;
      if (v != null && _controller.text != v) _controller.text = v;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('CLOUD CACHE FOLDER', small: true),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            labelText: 'Where downloaded vaults are kept',
            hintText: 'Leave empty for the default',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4),
        Text(
          'Default: ${defaultCloudCacheRoot()}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _browse,
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse…'),
            ),
            const Spacer(),
            TextButton(
              onPressed: _reset,
              child: const Text('Reset (use default)'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _controller.text.trim().isEmpty ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
