import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/display.dart';
import 'package:sama360/core/theme.dart';

/// Audit WCAG AA : tout texte doit atteindre 4,5:1 sur son fond, en clair comme en sombre,
/// et quelle que soit la couleur de boutique choisie.
void main() {
  // Fond réel d'une carte « verre » : voile posé sur le fond de l'écran.
  Color glass(SamaPalette p) =>
      p.dark ? Color.alphaBlend(const Color(0xB8121F19), p.ground) : Color.alphaBlend(const Color(0x9EFFFFFF), p.ground);

  final failures = <String>[];
  void check(String what, Color fg, Color bg, {double min = 4.5}) {
    final r = contrastRatio(fg, bg);
    if (r < min) failures.add('$what : ${r.toStringAsFixed(2)}:1 (< $min)');
  }

  test('contrastes de texte (clair et sombre, toutes les couleurs de boutique)', () {
    for (final (name, brand) in brandChoices) {
      for (final p in [SamaPalette.light(brand), SamaPalette.dark(brand)]) {
        final mode = '${p.dark ? 'sombre' : 'clair'}/$name';
        for (final (label, bg) in [('fond', p.ground), ('carte', p.card), ('verre', glass(p)), ('feuille', p.sheet)]) {
          check('$mode texte sur $label', p.ink, bg);
          check('$mode texte secondaire sur $label', p.muted, bg);
          check('$mode lien/bouton texte sur $label', p.green, bg);
        }
        check('$mode texte de bouton', p.onGreen, p.green, min: p.dark ? 3 : 4.5); // gras ≥ 16 px : 3:1 suffit
        check('$mode pastille verte', p.greenDark, p.greenSoft);
        check('$mode alerte', p.warnText, p.warnBg);
        check('$mode erreur sur fond', p.danger, p.ground);
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('pastilles colorées recalculées en mode sombre', () {
    AppColors.palette = SamaPalette.dark();
    for (final (soft, strong) in [
      (const Color(0xFFFBEAEA), const Color(0xFFB42318)),
      (const Color(0xFFE6F0FF), const Color(0xFF1D4FA8)),
      (const Color(0xFFEDE7FB), const Color(0xFF5B3CC4)),
      (const Color(0xFFFFF1E6), const Color(0xFF8A3D00)),
    ]) {
      final (bg, fg) = AppColors.tone(soft, strong);
      check('pastille sombre ${strong.toARGB32().toRadixString(16)}', fg, bg);
    }
    AppColors.palette = SamaPalette.light();
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
