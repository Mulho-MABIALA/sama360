import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Contraste WCAG entre deux couleurs (1 à 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Ajuste la luminosité de [c] (même teinte) jusqu'à respecter les contrastes demandés.
/// [towardsDark] : on assombrit (mode clair) ou on éclaircit (mode sombre).
Color _tuned(Color c, bool Function(Color) ok, {required bool towardsDark}) {
  var hsl = HSLColor.fromColor(c);
  for (var i = 0; i < 60 && !ok(hsl.toColor()); i++) {
    final l = (hsl.lightness + (towardsDark ? -0.015 : 0.015)).clamp(0.0, 1.0);
    if (l == hsl.lightness) break;
    hsl = hsl.withLightness(l);
  }
  return hsl.toColor();
}

/// Couleur de marque par défaut (vert émeraude Sama360).
const defaultBrand = Color(0xFF097E4F);

/// Couleurs de l'app selon le mode (clair / sombre) et la couleur de la boutique.
class SamaPalette {
  SamaPalette._({
    required this.dark,
    required this.brand,
    required this.green,
    required this.onGreen,
    required this.greenDark,
    required this.greenSoft,
    required this.leaf,
    required this.mint,
    required this.ink,
    required this.muted,
    required this.ground,
    required this.line,
    required this.card,
    required this.sheet,
    required this.peach,
    required this.sky,
    required this.warnBg,
    required this.warnLine,
    required this.warnText,
    required this.warn,
    required this.danger,
    required this.glassLine,
  });

  final bool dark;
  final Color brand, green, onGreen, greenDark, greenSoft, leaf, mint;
  final Color ink, muted, ground, line, card, sheet, peach, sky;
  final Color warnBg, warnLine, warnText, warn, danger, glassLine;

  factory SamaPalette.light([Color brand = defaultBrand]) {
    const ground = Color(0xFFF4F8F5);
    // Texte et boutons : au moins 4,5:1 sur blanc et sur le fond.
    final green = _tuned(
      brand,
      (c) => contrastRatio(c, Colors.white) >= 4.5 && contrastRatio(c, ground) >= 4.5,
      towardsDark: true,
    );
    final hsl = HSLColor.fromColor(green);
    final isDefault = brand.toARGB32() == defaultBrand.toARGB32();
    return SamaPalette._(
      dark: false,
      brand: brand,
      green: green,
      onGreen: Colors.white,
      greenDark: isDefault ? const Color(0xFF0B6E47) : hsl.withLightness((hsl.lightness - 0.06).clamp(0, 1)).toColor(),
      greenSoft: isDefault
          ? const Color(0xFFE4F5EC)
          : hsl.withLightness(0.93).withSaturation((hsl.saturation * 0.6).clamp(0, 1)).toColor(),
      leaf: isDefault ? const Color(0xFF19B56F) : hsl.withLightness((hsl.lightness + 0.14).clamp(0, 0.7)).toColor(),
      mint: isDefault
          ? const Color(0xFFD6F1E3)
          : hsl.withLightness(0.89).withSaturation((hsl.saturation * 0.6).clamp(0, 1)).toColor(),
      ink: const Color(0xFF13241C),
      muted: const Color(0xFF5E6E66),
      ground: ground,
      line: const Color(0xFFE3EBE6),
      card: Colors.white,
      sheet: const Color(0xFFF7FBF9),
      peach: const Color(0xFFFFE9D6),
      sky: const Color(0xFFE6F6EE),
      warnBg: const Color(0xFFFDF1DD),
      warnLine: const Color(0xFFF3D9A8),
      warnText: const Color(0xFF6B3A00),
      warn: const Color(0xFFB25E00),
      danger: const Color(0xFFB42318),
      glassLine: const Color(0xB3FFFFFF),
    );
  }

  factory SamaPalette.dark([Color brand = defaultBrand]) {
    const ground = Color(0xFF0A1410);
    // Texte coloré lisible sur le fond sombre, et texte blanc encore lisible dessus (boutons).
    // Réglée sur la surface sombre la plus claire (cartes) : lisible partout.
    const card = Color(0xFF14211B);
    final green = _tuned(brand, (c) => contrastRatio(c, card) >= 4.6, towardsDark: false);
    final onGreen = contrastRatio(green, Colors.white) >= 3 ? Colors.white : const Color(0xFF04140E);
    final hsl = HSLColor.fromColor(green);
    return SamaPalette._(
      dark: true,
      brand: brand,
      green: green,
      onGreen: onGreen,
      greenDark: hsl.withLightness((hsl.lightness + 0.08).clamp(0, 0.85)).toColor(),
      greenSoft: hsl.withLightness(0.16).withSaturation((hsl.saturation * 0.7).clamp(0, 1)).toColor(),
      leaf: hsl.withLightness((hsl.lightness + 0.05).clamp(0, 0.75)).toColor(),
      mint: hsl.withLightness(0.2).withSaturation((hsl.saturation * 0.6).clamp(0, 1)).toColor(),
      ink: const Color(0xFFE8F2ED),
      muted: const Color(0xFFA3B6AC),
      ground: ground,
      line: const Color(0xFF223229),
      card: card,
      sheet: const Color(0xFF111C17),
      peach: const Color(0xFF3A2616),
      sky: const Color(0xFF12302A),
      warnBg: const Color(0xFF33240E),
      warnLine: const Color(0xFF5C4113),
      warnText: const Color(0xFFF7CF94),
      warn: const Color(0xFFF2A65A),
      danger: const Color(0xFFFF8A80),
      glassLine: const Color(0x2EFFFFFF),
    );
  }
}

/// Palette des maquettes Sama360. Les couleurs qui dépendent du mode ou de la boutique
/// sont lues dans la palette courante ([AppColors.palette]), mise à jour par l'app.
abstract final class AppColors {
  static SamaPalette palette = SamaPalette.light();

  static bool get isDark => palette.dark;
  static Color get green => palette.green; // texte et boutons : contraste ≥ 4,5:1
  static Color get onGreen => palette.onGreen; // texte posé sur [green]
  static Color get leaf => palette.leaf; // décoratif uniquement (dégradés, illustrations)
  static Color get greenDark => palette.greenDark;
  static Color get greenSoft => palette.greenSoft;
  static Color get mint => palette.mint;
  static Color get ink => palette.ink;
  static Color get muted => palette.muted;
  static Color get ground => palette.ground;
  static Color get line => palette.line;
  static Color get peach => palette.peach;
  static Color get sky => palette.sky;
  static Color get card => palette.card;
  static Color get sheet => palette.sheet;
  static Color get warnBg => palette.warnBg;
  static Color get warnLine => palette.warnLine;
  static Color get warnText => palette.warnText;
  static Color get warn => palette.warn;
  static Color get danger => palette.danger;
  static Color get glassLine => palette.glassLine;

  /// Surface claire translucide (cartes, boutons secondaires) ; vert nuit en mode sombre.
  static Color surface([double alpha = 1]) =>
      isDark ? palette.card.withValues(alpha: math.max(alpha, 0.85)) : Colors.white.withValues(alpha: alpha);

  /// Pastille colorée (fond doux, texte vif). En mode sombre, les deux sont recalculés
  /// à partir de la couleur vive pour rester lisibles sur fond nuit.
  static (Color, Color) tone(Color soft, Color strong) {
    if (!isDark) return (soft, strong);
    // Fond : la teinte vive à 20 % sur la carte ; texte éclairci jusqu'à 4,5:1 sur ce fond.
    final bg = Color.alphaBlend(strong.withValues(alpha: 0.2), palette.card);
    final fg = _tuned(strong, (c) => contrastRatio(c, bg) >= 4.6, towardsDark: false);
    return (bg, fg);
  }

  static Color softOf(Color soft, Color strong) => tone(soft, strong).$1;
  static Color strongOf(Color soft, Color strong) => tone(soft, strong).$2;

  // Fixes, quel que soit le mode
  static const orange = Color(0xFFFF8A3D);
  static const saffron = Color(0xFFF2A93B);
  static const whatsapp = Color(0xFF25D366);

  /// Texte et icônes sur le vert WhatsApp (contraste 6,8:1 ; le blanc n'atteint que 2:1).
  static const onWhatsapp = Color(0xFF08361A);

  // Thème verre / aurora
  static const glow = Color(0xFF7DF0B5); // menthe lumineuse (sur fond sombre)
  static const deep = Color(0xFF052E24); // émeraude profond
}

abstract final class AppTheme {
  /// [googleFonts] = false dans les tests (pas de téléchargement de police).
  static ThemeData light({bool googleFonts = true}) => build(SamaPalette.light(), googleFonts: googleFonts);

  static ThemeData dark({bool googleFonts = true}) => build(SamaPalette.dark(), googleFonts: googleFonts);

  /// Thème complet pour une palette (mode clair ou sombre, couleur de la boutique).
  static ThemeData build(SamaPalette p, {bool googleFonts = true}) {
    final dark = p.dark;
    final base = ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: p.green,
        brightness: dark ? Brightness.dark : Brightness.light,
        primary: p.green,
        onPrimary: p.onGreen,
        surface: p.ground,
        onSurface: p.ink,
        error: p.danger,
      ),
      scaffoldBackgroundColor: p.ground,
    );
    // Voile des surfaces « verre » : blanc en mode clair, vert nuit en mode sombre.
    Color veil(double light) =>
        dark ? Colors.white.withValues(alpha: light * 0.1) : Colors.white.withValues(alpha: light);
    final text = googleFonts ? GoogleFonts.plusJakartaSansTextTheme(base.textTheme) : base.textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: p.glassLine, width: 1.2),
    );
    return base.copyWith(
      textTheme: text.apply(bodyColor: p.ink, displayColor: p.ink),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: veil(0.82),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: p.green, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.green,
          foregroundColor: p.onGreen,
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: text.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          backgroundColor: veil(0.7),
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: p.glassLine, width: 1.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: p.line),
      ),
      // Cartes « verre givré » : voile blanc translucide et liseré lumineux.
      cardTheme: CardThemeData(
        color: dark ? p.card.withValues(alpha: 0.82) : Colors.white.withValues(alpha: 0.74),
        shadowColor: const Color(0x260B3D2E),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: p.glassLine, width: 1.2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: p.green.withValues(alpha: 0.13),
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
            color: s.contains(WidgetState.selected) ? p.green : p.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? p.green : p.muted),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.sheet,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.sheet,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      // Boutons flottants : couleur de la boutique ; ombre douce (pas d'anneau noir en mode sombre)
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.green,
        foregroundColor: p.onGreen,
        elevation: dark ? 1 : 4,
        focusElevation: dark ? 1 : 4,
        hoverElevation: dark ? 2 : 6,
        highlightElevation: dark ? 2 : 8,
        extendedTextStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
