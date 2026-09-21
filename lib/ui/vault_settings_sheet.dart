// Vault settings: container statistics (generation, garbage, mirrors, KDF)
// plus maintenance operations — change password, compact, remirror.
//
// All state comes from the vault providers; the sheet is a pure consumer.
// The change-password dialog owns its form through a dedicated provider.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../provider/browser_provider.dart';
import '../provider/change_password_form_provider.dart';
import 'common/section_header.dart';
import 'format.dart';

/// Show the modal settings sheet for the open vault.
Future<void> showVaultSettings(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const VaultSettingsSheet(),
  );
}

class VaultSettingsSheet extends ConsumerWidget {
  const VaultSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(vaultInfoProvider);
    final actions = ref.watch(vaultActionsProvider);
    final notifier = ref.read(vaultActionsProvider.notifier);

    // Surface transient results/failures from maintenance ops as snackbars.
    ref.listen<String?>(vaultActionsProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: const SectionHeader('VAULT SETTINGS'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 6),
              child: Divider(),
            ),
            if (actions.busy) const LinearProgressIndicator(minHeight: 2),
            ...info.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Failed to load info: ${describeEngineError(e)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              data: (i) => [_infoPanel(context, i)],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: actions.busy
                  ? null
                  : () => _openChangePassword(context, ref),
              icon: const Icon(Icons.password),
              label: const Text('Change password…'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: actions.busy ? null : notifier.compact,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Compact'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: actions.busy ? null : notifier.remirror,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('Remirror'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openChangePassword(BuildContext context, WidgetRef ref) async {
    ref.read(changePasswordFormProvider.notifier).reset();
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const ChangePasswordDialog(),
    );
    if (changed == true) {
      ref.invalidate(vaultInfoProvider);
    }
  }

  Widget _infoPanel(BuildContext context, VaultInfoModel info) {
    final style = Theme.of(context).textTheme.bodyMedium;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value, style: style)),
        ],
      ),
    );

    final ratio = (info.garbageRatio * 100).toStringAsFixed(1);
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('Path', info.path),
            row('KDF', info.kdf),
            row('Generation', '${info.generation}'),
            row('Files', '${info.files}'),
            row('Container size', formatBytes(info.sizeBytes)),
            row('Garbage', '${formatBytes(info.garbageBytes)} ($ratio%)'),
            row('Header mirror', info.headerMirror ? 'present' : 'missing'),
            row('Metadata mirror', info.metadataMirror ? 'present' : 'missing'),
          ],
        ),
      ),
    );
  }
}

/// Inline dialog that performs the password change itself (it owns its busy
/// state through [changePasswordFormProvider]); pops `true` once the vault is
/// re-keyed.
class ChangePasswordDialog extends ConsumerWidget {
  const ChangePasswordDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(changePasswordFormProvider);
    final notifier = ref.read(changePasswordFormProvider.notifier);

    // Surface transient failures as snackbars.
    ref.listen<String?>(changePasswordFormProvider.select((s) => s.notice), (
      _,
      notice,
    ) {
      if (notice != null) showSnack(context, notice);
    });

    // Once the vault has been re-keyed, close the dialog with `true`.
    ref.listen<bool>(changePasswordFormProvider.select((s) => s.done), (
      _,
      done,
    ) {
      if (done) Navigator.of(context).pop(true);
    });

    return AlertDialog(
      title: const Text('Change password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Content is not re-encrypted; only the header KDF salt and '
              'master-key wrapping are refreshed.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notifier.password,
              obscureText: state.obscure,
              decoration: InputDecoration(
                labelText: 'New password',
                suffixIcon: IconButton(
                  tooltip: state.obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    state.obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => notifier.setObscure(!state.obscure),
                ),
              ),
              onChanged: (_) => notifier.touch(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notifier.confirm,
              obscureText: state.obscure,
              decoration: const InputDecoration(labelText: 'Confirm password'),
              onChanged: (_) => notifier.touch(),
            ),
            const SizedBox(height: 12),
            DropdownMenu<KdfPreset>(
              label: const Text('Key derivation cost'),
              initialSelection: notifier.preset,
              dropdownMenuEntries: [
                for (final c in kdfPresetChoices)
                  DropdownMenuEntry<KdfPreset>(value: c.preset, label: c.label),
              ],
              onSelected: (p) {
                if (p != null) notifier.setPreset(p);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: state.busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: state.busy ? null : notifier.submit,
          child: const Text('Change'),
        ),
      ],
    );
  }
}
