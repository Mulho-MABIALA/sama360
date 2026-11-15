import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette des maquettes Sama360.
abstract final class AppColors {
  static const green = Color(0xFF0F6E56);
  static const greenDark = Color(0xFF0A5241);
  static const greenSoft = Color(0xFFE3F1EC);
  static const ink = Color(0xFF14201C);
  static const muted = Color(0xFF5B6762);
  static const ground = Color(0xFFF6F5F1);
  static const line = Color(0xFFE6E3DA);
  static const card = Colors.white;
  static const saffron = Color(0xFFF2A93B);
  static const warnBg = Color(0xFFFDF1DD);
  static const warnLine = Color(0xFFF3D9A8);
  static const warnText = Color(0xFF6B3A00);
  static const warn = Color(0xFFB25E00);
  static const danger = Color(0xFFB42318);
  static const whatsapp = Color(0xFF25D366);
}

abstract final class AppTheme {
  /// [googleFonts] = false dans les tests (pas de téléchargement de police).
  static ThemeData light({bool googleFonts = true}) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.green,
        primary: AppColors.green,
        surface: AppColors.ground,
        onSurface: AppColors.ink,
      ),
      scaffoldBackgroundColor: AppColors.ground,
    );
    final text = googleFonts ? GoogleFonts.plusJakartaSansTextTheme(base.textTheme) : base.textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppColors.line),
    );
    return base.copyWith(
      textTheme: text.apply(bodyColor: AppColors.ink, displayColor: AppColors.ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.ground,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: const BorderSide(color: AppColors.green, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: text.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: const BorderSide(color: AppColors.line),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.greenSoft,
        height: 68,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
