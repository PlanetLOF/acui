import 'package:flutter/material.dart';

/// Small uppercase label above a control.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            color: cs.onSurfaceVariant,
          ),
        ),
        child,
      ],
    );
  }
}

class AcTextField extends StatelessWidget {
  const AcTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        decoration: InputDecoration(hintText: hint),
      ),
    );
  }
}

/// Text field + button (BROWSE / SAVE AS).
class PathField extends StatelessWidget {
  const PathField({
    super.key,
    required this.label,
    required this.controller,
    required this.buttonLabel,
    required this.onPick,
    this.hint,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String buttonLabel;
  final VoidCallback onPick;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              decoration: InputDecoration(hintText: hint),
            ),
          ),
          OutlinedButton(
            onPressed: onPick,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

class PasswordField extends StatelessWidget {
  const PasswordField({
    super.key,
    required this.label,
    required this.controller,
    required this.obscure,
    required this.onToggle,
    this.hint,
    this.onGenerate,
    this.onChanged,
    this.errorText,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggle;
  final String? hint;

  /// When set, shows a "generate random password" button.
  final VoidCallback? onGenerate;
  final ValueChanged<String>? onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          errorText: errorText,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onGenerate != null)
                IconButton(
                  tooltip: 'Generate random password',
                  icon: const Icon(Icons.casino_outlined),
                  onPressed: onGenerate,
                ),
              IconButton(
                tooltip: 'Toggle visibility',
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: onToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Host + port text fields side by side, port fixed at 96px.
class HostPortField extends StatelessWidget {
  const HostPortField({
    super.key,
    required this.hostLabel,
    required this.hostController,
    required this.portController,
    this.hostHint,
    this.portHint,
    this.onChanged,
  });

  final String hostLabel;
  final TextEditingController hostController;
  final TextEditingController portController;
  final String? hostHint;
  final String? portHint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Expanded(
          child: AcTextField(
            label: hostLabel,
            controller: hostController,
            hint: hostHint,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 96,
          child: AcTextField(
            label: 'PORT',
            controller: portController,
            hint: portHint,
            keyboardType: TextInputType.number,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// Material 3 DropdownMenu, styled through AppTheme.
class AcDropdown<T> extends StatelessWidget {
  const AcDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: DropdownMenu<T>(
        expandedInsets: EdgeInsets.zero,
        initialSelection: value,
        requestFocusOnTap: false,
        dropdownMenuEntries: [
          for (final e in options.entries)
            DropdownMenuEntry<T>(value: e.key, label: e.value),
        ],
        onSelected: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
