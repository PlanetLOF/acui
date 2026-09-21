import 'package:flutter/material.dart';

import 'section_header.dart';

/// Modal action bottom sheet: a bold section header, a divider, and a list of
/// tappable rows (used by the vault import menu and per-file actions).
class ActionSheet extends StatelessWidget {
  const ActionSheet({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SectionHeader(title),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Divider(),
          ),
          ...children,
        ],
      ),
    );
  }
}