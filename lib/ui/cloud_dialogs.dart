// Dialogs for the CLOUD tab: the vault-password prompt shown after a remote
// vault is downloaded, and the create-in-cloud form. Both are self-contained
// StatefulWidgets that own their controllers and call back into the cloud
// browser notifier; errors (wrong password, upload failure) stay inside the
// dialog so the user can retry.

import 'package:autocipher_dart/autocipher_dart.dart';
import 'package:flutter/material.dart';

import 'common/section_header.dart';
import 'format.dart';

/// Ask for the password of a downloaded remote vault, then open it.
class CloudOpenVaultDialog extends StatefulWidget {
  const CloudOpenVaultDialog({
    super.key,
    required this.vaultName,
    required this.onSubmit,
  });

  final String vaultName;

  /// Opens the vault (throws [AutocipherException] on a wrong password).
  final Future<void> Function(String password) onSubmit;

  @override
  State<CloudOpenVaultDialog> createState() => _CloudOpenVaultDialogState();
}

class _CloudOpenVaultDialogState extends State<CloudOpenVaultDialog> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = exceptionText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.vaultName),
      content: TextField(
        controller: _password,
        autofocus: true,
        obscureText: _obscure,
        enabled: !_busy,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Vault password',
          errorText: _error,
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show password' : 'Hide password',
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('OPEN'),
        ),
      ],
    );
  }
}

/// Create a new vault in the current remote folder: name + password (+ KDF),
/// mirroring the local CREATE form.
class CloudCreateDialog extends StatefulWidget {
  const CloudCreateDialog({super.key, required this.onSubmit});

  /// Creates + uploads + opens the vault (throws on failure).
  final Future<void> Function(String name, String password, KdfPreset preset)
  onSubmit;

  @override
  State<CloudCreateDialog> createState() => _CloudCreateDialogState();
}

class _CloudCreateDialogState extends State<CloudCreateDialog> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  KdfPreset _preset = KdfPreset.kdf256;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _name.text.trim().isNotEmpty &&
      _password.text.isNotEmpty &&
      _password.text == _confirm.text;

  Future<void> _submit() async {
    if (_busy || !_canSubmit) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_name.text.trim(), _password.text, _preset);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = exceptionText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New cloud vault'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text(
              'The vault is created encrypted and uploaded to the '
              'current remote folder.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            TextField(
              controller: _name,
              enabled: !_busy,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Vault name',
                hintText: 'vault.ac',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            TextField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Confirm password',
                errorText:
                    _confirm.text.isNotEmpty && _confirm.text != _password.text
                    ? 'Passwords do not match'
                    : _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const Divider(),
            const SectionHeader('KEY DERIVATION PARAMETERS', small: true),
            DropdownMenu<KdfPreset>(
              expandedInsets: EdgeInsets.zero,
              enabled: !_busy,
              label: const Text('Memory cost'),
              initialSelection: _preset,
              dropdownMenuEntries: [
                for (final c in kdfPresetChoices)
                  DropdownMenuEntry<KdfPreset>(value: c.preset, label: c.label),
              ],
              onSelected: (p) {
                if (p != null) setState(() => _preset = p);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || !_canSubmit ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('CREATE & UPLOAD'),
        ),
      ],
    );
  }
}
