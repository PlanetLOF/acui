import 'package:flutter/material.dart';

import 'section_header.dart';

/// Modal action bottom sheet: a bold section header, a divider, and a list of
/// tappable rows (used by the vault import menu and per-file actions).
class ActionSheet extends StatelessWidget {
  const ActionSheet({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.titleIsLabel = true,
  });

  final String title;
  final List<Widget> children;

  /// Optional secondary line shown below an entry-oriented title.
  final String? subtitle;

  /// Section labels use the app's compact uppercase style. Set false for a
  /// filename/folder name that should retain its original casing.
  final bool titleIsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      // Action sheets can contain more rows than fit in the default
      // bottom-sheet height (for example, the file/folder menus). Keep the
      // header and rows scrollable together so large text and short windows
      // cannot overflow the route's bounded height.
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: titleIsLabel
                  ? SectionHeader(title)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Divider(),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
