import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'offline/pending_sales.dart' show keyValueStoreProvider;
import 'providers.dart';
import 'theme.dart';

/// Préférences d'affichage, propres au téléphone (gardées entre les lancements).
class DisplaySettings {
  // Fond clair par défaut (choix du produit) ; le mode sombre ne s'active que sur demande.
  const DisplaySettings({this.mode = ThemeMode.light, this.largeText = false, this.hideAmounts = false});
  final ThemeMode mode;
  final bool largeText;

  /// Montants masqués (œil barré), comme sur Wave : utile devant les clients.
  final bool hideAmounts;

  DisplaySettings copyWith({ThemeMode? mode, bool? largeText, bool? hideAmounts}) => DisplaySettings(
    mode: mode ?? this.mode,
    largeText: largeText ?? this.largeText,
    hideAmounts: hideAmounts ?? this.hideAmounts,
  );

  Map<String, Object> toJson() => {'mode': mode.name, 'largeText': largeText, 'hideAmounts': hideAmounts};

  factory DisplaySettings.fromJson(Map<String, dynamic> j) => DisplaySettings(
    mode: ThemeMode.values.where((m) => m.name == j['mode']).firstOrNull ?? ThemeMode.light,
    largeText: j['largeText'] == true,
    hideAmounts: j['hideAmounts'] == true,
  );
}

/// Agrandissement du texte avec l'option « grands caractères ».
const largeTextScale = 1.2;

class DisplaySettingsNotifier extends Notifier<DisplaySettings> {
  static const _key = 'display.settings';

  @override
  DisplaySettings build() {
    final raw = ref.watch(keyValueStoreProvider).getString(_key);
    if (raw == null) return const DisplaySettings();
    try {
      return DisplaySettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const DisplaySettings();
    }
  }

  Future<void> update(DisplaySettings s) async {
    state = s;
    await ref.read(keyValueStoreProvider).setString(_key, jsonEncode(s.toJson()));
  }

  Future<void> setMode(ThemeMode m) => update(state.copyWith(mode: m));
  Future<void> setLargeText(bool v) => update(state.copyWith(largeText: v));
  Future<void> toggleAmounts() => update(state.copyWith(hideAmounts: !state.hideAmounts));
}

final displaySettingsProvider = NotifierProvider<DisplaySettingsNotifier, DisplaySettings>(DisplaySettingsNotifier.new);

/// « #0A7E4F » → couleur ; null si absent ou invalide.
Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
  return m == null ? null : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

/// Couleur → « #0A7E4F ».
String toHexColor(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Couleur de la boutique active (vert Sama360 par défaut).
final brandColorProvider = Provider<Color>((ref) {
  final b = ref.watch(currentBusinessProvider).value;
  return parseHexColor(b?.brandColor) ?? defaultBrand;
});

/// Couleurs proposées au commerçant (toutes lisibles avec du texte blanc une fois ajustées).
const brandChoices = <(String, Color)>[
  ('Émeraude', defaultBrand),
  ('Océan', Color(0xFF1565C0)),
  ('Indigo', Color(0xFF4338CA)),
  ('Violet', Color(0xFF7C3AED)),
  ('Prune', Color(0xFF9D174D)),
  ('Rouge', Color(0xFFC62828)),
  ('Terre', Color(0xFFB45309)),
  ('Kola', Color(0xFF8D5524)),
  ('Sarcelle', Color(0xFF0F766E)),
  ('Nuit', Color(0xFF1E293B)),
];

/// Applique la palette (mode + couleur de boutique) aux couleurs lues partout via [AppColors].
/// Si elle change, tout l'arbre est reconstruit au cadre suivant (y compris les widgets
/// qui ne dépendent pas du thème).
void syncPalette(Brightness brightness, Color brand) {
  final dark = brightness == Brightness.dark;
  final current = AppColors.palette;
  if (current.dark == dark && current.brand.toARGB32() == brand.toARGB32()) return;
  AppColors.palette = dark ? SamaPalette.dark(brand) : SamaPalette.light(brand);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    void rebuild(Element e) {
      e.markNeedsBuild();
      e.visitChildren(rebuild);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) rebuild(root);
  });
}
