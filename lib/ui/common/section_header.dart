import 'package:flutter/material.dart';

/// Bold, letter-spaced uppercase heading used as a section/card/sheet title.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.small = false});

  final String text;

  /// Smaller variant (11px, tighter spacing) for sub-sections like
  /// "KEY DERIVATION PARAMETERS".
  final bool small;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: small ? 11 : 13,
        fontWeight: FontWeight.bold,
        letterSpacing: small ? 1 : 1.5,
        color: cs.onSurfaceVariant,
      ),
    );
  }
}