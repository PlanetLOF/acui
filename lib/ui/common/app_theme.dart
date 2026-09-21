import 'package:flutter/material.dart';

/// The palette from acui.css / the Tailwind arbitrary values.
abstract final class AppColors {
  static const background = Color(0xFF111C18);
  static const selected = Color(0xFF213027);
  static const text = Color(0xFFB5D8BD);
  static const muted = Color(0xFF79947D);
  static const divider = Color(0xFF1F3128);
  static const border = Color(0xFF23372B);
  static const borderHover = Color(0xFF3B5A47);
  static const borderFocus = Color(0xFF486953);
  static const accent = Color(0xFF509274);
}

abstract final class AppTheme {
  static ThemeData get dark {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ).copyWith(
          surface: AppColors.background,
          onSurface: AppColors.text,
          onSurfaceVariant: AppColors.muted,
          primary: AppColors.accent,
          onPrimary: AppColors.background,
          primaryContainer: AppColors.selected,
          onPrimaryContainer: AppColors.text,
          secondaryContainer: AppColors.selected,
          onSecondaryContainer: AppColors.text,
          outline: AppColors.border,
          outlineVariant: AppColors.divider,
          surfaceContainerHighest: AppColors.selected,
        );

    OutlineInputBorder outline(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: c),
    );

    // If the analyzer asks for InputDecorationThemeData on your Flutter
    // version, change the type here; it is only used in this file.
    final inputTheme = InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: outline(AppColors.border),
      enabledBorder: outline(AppColors.border),
      focusedBorder: outline(AppColors.borderFocus),
      hintStyle: const TextStyle(color: AppColors.divider),
    );

    const buttonText = TextStyle(fontSize: 14, letterSpacing: 1);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 24, vertical: 18);
    const square = RoundedRectangleBorder();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: 'Courier New',
      fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      cardTheme: const CardThemeData(
        color: AppColors.background,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: AppColors.divider),
        ),
      ),
      inputDecorationTheme: inputTheme,
      dropdownMenuTheme: DropdownMenuThemeData(
        inputDecorationTheme: inputTheme,
        menuStyle: const MenuStyle(
          backgroundColor: WidgetStatePropertyAll(AppColors.background),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(side: BorderSide(color: AppColors.divider)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.selected,
          foregroundColor: AppColors.text,
          shape: const RoundedRectangleBorder(
            side: BorderSide(color: AppColors.borderFocus),
          ),
          padding: buttonPadding,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: AppColors.muted,
              shape: square,
              padding: buttonPadding,
              textStyle: buttonText,
            ).copyWith(
              side: WidgetStateProperty.resolveWith<BorderSide?>(
                (s) => BorderSide(
                  color: s.contains(WidgetState.hovered)
                      ? AppColors.borderHover
                      : AppColors.border,
                ),
              ),
            ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.muted,
          selectedBackgroundColor: AppColors.selected,
          selectedForegroundColor: AppColors.text,
          side: const BorderSide(color: AppColors.border),
          shape: square,
          textStyle: buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.muted,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: square,
        checkColor: const WidgetStatePropertyAll(AppColors.text),
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.selected
              : AppColors.background,
        ),
        side: WidgetStateBorderSide.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.selected)
                ? AppColors.borderFocus
                : AppColors.border,
          ),
        ),
      ),
      // Flat, squared-off action button (Import FAB etc.) — no floating
      // shadow; styled like the FilledButton actions in the open/create
      // forms (selected fill, borderFocus border, mono label).
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.selected,
        foregroundColor: AppColors.text,
        disabledElevation: 0,
        elevation: 0,
        focusElevation: 0,
        highlightElevation: 0,
        hoverElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.borderFocus),
        ),
        extendedPadding: EdgeInsets.symmetric(horizontal: 24),
      ),
      // Bottom sheets (import menu, settings) share the card look: flat,
      // square, bordered, no drag handle.
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        showDragHandle: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.divider),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: AppColors.divider),
        ),
        titleTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
          color: AppColors.text,
        ),
        contentTextStyle: TextStyle(fontSize: 13, color: AppColors.text),
      ),
      textButtonTheme: TextButtonThemeData(
        style:
            TextButton.styleFrom(
              foregroundColor: AppColors.muted,
              shape: square,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: buttonText,
            ).copyWith(
              foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                (s) =>
                    s.contains(WidgetState.hovered) ||
                        s.contains(WidgetState.pressed)
                    ? AppColors.text
                    : AppColors.muted,
              ),
            ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.selected,
        contentTextStyle: const TextStyle(fontSize: 13, color: AppColors.text),
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: AppColors.border),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.muted,
        textColor: AppColors.text,
        subtitleTextStyle: TextStyle(fontSize: 12, color: AppColors.muted),
        selectedColor: AppColors.text,
        selectedTileColor: AppColors.selected,
      ),
    );
  }
}
