import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';

/// Couverture de la vitrine, comme en haut de la page publique : photo plein cadre,
/// voile sombre, petit surtitre, grand titre (les deux derniers mots en italique).
class ShopCover extends ConsumerWidget {
  const ShopCover({
    super.key,
    required this.headline,
    this.coverFileId,
    this.kicker,
    this.subtitle,
    this.bottom,
    this.height = 260,
    this.radius = 26,
  });
  final String headline;
  final String? coverFileId;
  final String? kicker;
  final String? subtitle;
  final Widget? bottom;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.green, Color.lerp(AppColors.green, Colors.black, 0.6)!],
        ),
      ),
    );
    final words = headline.trim().split(RegExp(r'\s+'));
    const serif = TextStyle(
      fontFamily: 'serif',
      fontFamilyFallback: ['Georgia', 'Times New Roman'],
      color: Colors.white,
      fontSize: 28,
      height: 1.1,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.3,
      shadows: [Shadow(color: Color(0x55000000), blurRadius: 16)],
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverFileId == null)
              placeholder
            else
              Image.network(
                ref.watch(repoProvider).fileUrl(coverFileId!),
                key: ValueKey(coverFileId),
                fit: BoxFit.cover,
                loadingBuilder: (_, child, p) => p == null ? child : placeholder,
                errorBuilder: (_, _, _) => placeholder,
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x59000000), Color(0x33000000), Color(0xA6000000)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if ((kicker ?? '').isNotEmpty)
                    Text(
                      kicker!.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text.rich(
                    words.length < 4
                        ? TextSpan(text: headline.trim())
                        : TextSpan(
                            children: [
                              TextSpan(text: '${words.sublist(0, words.length - 2).join(' ')} '),
                              TextSpan(
                                text: words.sublist(words.length - 2).join(' '),
                                style: const TextStyle(fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                    key: const Key('shop_cover_headline'),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: serif,
                  ),
                  if ((subtitle ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 13, height: 1.35),
                    ),
                  ],
                  if (bottom != null) ...[const SizedBox(height: 14), bottom!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bouton crème « Découvrir la boutique › », comme sur la page publique.
class ShopCoverButton extends StatelessWidget {
  const ShopCoverButton({super.key, required this.label, this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFE9F0C9),
    shape: const StadiumBorder(),
    elevation: 4,
    shadowColor: const Color(0x55000000),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 5, 5, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(color: Color(0xFF0F1A15), fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(width: 10),
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(color: Color(0xFF0F1A15), shape: BoxShape.circle),
              child: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 20),
            ),
          ],
        ),
      ),
    ),
  );
}
