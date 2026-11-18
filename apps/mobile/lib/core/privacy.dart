import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'display.dart';

/// Montants masqués partout dans l'app (réglage du téléphone, gardé entre les lancements).
final amountsHiddenProvider = Provider<bool>((ref) => ref.watch(displaySettingsProvider).hideAmounts);

/// Ce qui s'affiche à la place d'un montant masqué.
const hiddenAmount = '•••••';

/// « 86 500 F » ou « ••••• F » selon le réglage (garde l'unité pour que la mise en page ne saute pas).
String maskMoney(bool hidden, String text) {
  if (!hidden) return text;
  final unit = RegExp(r'(FCFA|F)\s*$').firstMatch(text)?.group(1);
  return unit == null ? hiddenAmount : '$hiddenAmount $unit';
}

/// Œil pour afficher ou masquer les montants (un appui les masque dans toute l'app).
class AmountsEye extends ConsumerWidget {
  const AmountsEye({super.key, this.color, this.size = 20});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(amountsHiddenProvider);
    return IconButton(
      tooltip: hidden ? 'Afficher les montants' : 'Masquer les montants',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: EdgeInsets.zero,
      onPressed: () {
        HapticFeedback.selectionClick();
        ref.read(displaySettingsProvider.notifier).toggleAmounts();
      },
      icon: Icon(hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: size, color: color),
    );
  }
}

/// Texte d'un montant, masqué quand l'œil est barré.
class MaskedText extends ConsumerWidget {
  const MaskedText(this.text, {super.key, this.style, this.textAlign, this.maxLines});
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text(maskMoney(ref.watch(amountsHiddenProvider), text), style: style, textAlign: textAlign, maxLines: maxLines);
}

/// Libellé d'un montant suivi de l'œil (en-têtes des cartes de synthèse).
class LabelWithEye extends StatelessWidget {
  const LabelWithEye(this.label, {super.key, required this.style, this.eyeColor});
  final String label;
  final TextStyle style;
  final Color? eyeColor;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(label, style: style)),
      const SizedBox(width: 2),
      AmountsEye(color: eyeColor ?? style.color, size: 17),
    ],
  );
}
