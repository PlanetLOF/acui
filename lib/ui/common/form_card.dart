import 'package:flutter/material.dart';

import 'section_header.dart';

/// Card shell shared by every connection form.
class FormCard extends StatelessWidget {
  const FormCard({
    super.key,
    required this.title,
    required this.children,
    required this.actionLabel,
    required this.onAction,
    this.busy = false,
  });

  final String title;
  final List<Widget> children;
  final String actionLabel;

  /// Pass null to disable the action button.
  final VoidCallback? onAction;

  /// Shows a progress spinner inside the action button and disables it.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 448),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              SectionHeader(title),
              const Divider(),
              ...children,
              const Divider(),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: busy ? null : onAction,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
