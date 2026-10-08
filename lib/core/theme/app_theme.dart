import 'package:flutter/material.dart';

import '../../services/git/git_models.dart';

/// Gitty's look: soft colors, generous spacing, rounded shapes.
class AppTheme {
  AppTheme._();

  static const seed = Color(0xFF5B6CFF); // calm periwinkle
  static const radius = 16.0;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(shape: shape),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: 460,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }
}

/// Semantic colors for repository states that read well in light and dark.
class StatusColors {
  const StatusColors._(this.background, this.foreground);

  final Color background;
  final Color foreground;

  static StatusColors forSync(SyncState state, ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    Color tone(Color base) => dark
        ? Color.lerp(base, Colors.black, 0.55)!
        : Color.lerp(base, Colors.white, 0.82)!;
    Color text(Color base) => dark
        ? Color.lerp(base, Colors.white, 0.45)!
        : Color.lerp(base, Colors.black, 0.35)!;

    final base = switch (state) {
      SyncState.upToDate => const Color(0xFF2E9E6A), // green
      SyncState.ahead => const Color(0xFF3B7BE0), // blue
      SyncState.behind => const Color(0xFFD9901A), // amber
      SyncState.diverged => const Color(0xFFE0574F), // coral
      SyncState.noUpstream => const Color(0xFF8A8FA3), // grey
      SyncState.detached => const Color(0xFF9B59B6), // purple
    };
    return StatusColors._(tone(base), text(base));
  }
}
