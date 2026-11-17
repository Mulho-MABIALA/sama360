import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Une bannière du carrousel. Aujourd'hui définies dans l'app ;
/// demain servies par l'API (campagnes gérées depuis le back-office).
class PromoSlide {
  const PromoSlide({
    required this.id,
    required this.tag,
    required this.title,
    required this.body,
    required this.cta,
    required this.colors,
    required this.ink,
    required this.icon,
    required this.iconColor,
    this.route,
    this.comingSoon,
  });

  final String id;
  final String tag; // petite étiquette au-dessus du titre
  final String title;
  final String body;
  final String cta;
  final List<Color> colors; // dégradé de fond (clair)
  final Color ink; // couleur du texte (contraste ≥ 4,5:1 sur le fond)
  final IconData icon;
  final Color iconColor;
  final String? route; // action : ouvrir un écran de l'app
  final String? comingSoon; // ou : message « bientôt »
}

final defaultPromos = [
  PromoSlide(
    id: 'pro',
    tag: 'OFFRE',
    title: 'Passez à Sama360 Pro',
    body: 'Plusieurs vendeurs, factures illimitées et rapports détaillés.',
    cta: 'Découvrir',
    colors: [Color(0xFFFFF1E2), Color(0xFFFFD9B8)],
    ink: Color(0xFF6B2D00),
    icon: Icons.rocket_launch_rounded,
    iconColor: AppColors.orange,
    comingSoon: 'Les offres Sama360 Pro arrivent bientôt',
  ),
  PromoSlide(
    id: 'photos',
    tag: 'ASTUCE',
    title: 'Ajoutez vos photos',
    body: 'Retrouvez chaque produit d’un coup d’œil à la caisse.',
    cta: 'Aller au stock',
    colors: [Color(0xFFE8F1FF), Color(0xFFCFE0FF)],
    ink: Color(0xFF123B7A),
    icon: Icons.add_a_photo_rounded,
    iconColor: Color(0xFF2F6FDB),
    route: '/stock',
  ),
  PromoSlide(
    id: 'team',
    tag: 'ÉQUIPE',
    title: 'Invitez votre vendeur',
    body: 'Il encaisse, vous gardez la main sur les bénéfices.',
    cta: 'Inviter',
    colors: [Color(0xFFE6F7EE), Color(0xFFC9EEDB)],
    ink: Color(0xFF0B4D33),
    icon: Icons.group_add_rounded,
    iconColor: AppColors.green,
    comingSoon: "L'invitation depuis l'app arrive bientôt",
  ),
  PromoSlide(
    id: 'shop',
    tag: 'BIENTÔT',
    title: 'Votre boutique en ligne',
    body: 'Un lien à partager sur WhatsApp, vos clients commandent.',
    cta: 'En savoir plus',
    colors: [Color(0xFFF1ECFF), Color(0xFFDDD3FF)],
    ink: Color(0xFF3B2A86),
    icon: Icons.storefront_rounded,
    iconColor: Color(0xFF7A5AF8),
    comingSoon: 'La boutique en ligne arrive bientôt sur Sama360',
  ),
];

/// Bannières affichées sur l'accueil (remplaçable par un appel API plus tard).
final promosProvider = Provider<List<PromoSlide>>((ref) => defaultPromos);

/// Carrousel : glisser pour changer, défilement automatique toutes les 5 s
/// (désactivé si l'utilisateur a réduit les animations ou utilise un lecteur d'écran).
class PromoCarousel extends ConsumerStatefulWidget {
  const PromoCarousel({super.key, this.interval = const Duration(seconds: 5)});
  final Duration interval;

  @override
  ConsumerState<PromoCarousel> createState() => _PromoCarouselState();
}

class _PromoCarouselState extends ConsumerState<PromoCarousel> {
  final _controller = PageController();
  Timer? _timer;
  int _index = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    final media = MediaQuery.of(context);
    if (media.disableAnimations || media.accessibleNavigation) return;
    _timer = Timer.periodic(widget.interval, (_) {
      final count = ref.read(promosProvider).length;
      if (!mounted || count < 2 || !_controller.hasClients) return;
      _controller.animateToPage(
        (_index + 1) % count,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _open(PromoSlide s) {
    if (s.route != null) {
      context.go(s.route!);
    } else if (s.comingSoon != null) {
      showInfo(context, s.comingSoon!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slides = ref.watch(promosProvider);
    if (slides.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          // La hauteur suit la taille de texte choisie dans le téléphone (accessibilité).
          height: 160 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8),
          child: Listener(
            // L'utilisateur prend la main : on relance le minuteur pour ne pas lui couper la lecture.
            onPointerDown: (_) => _restartTimer(),
            child: PageView.builder(
              controller: _controller,
              itemCount: slides.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _Slide(slide: slides[i], position: i + 1, count: slides.length, onTap: () => _open(slides[i])),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < slides.length; i++)
              Semantics(
                button: true,
                selected: i == _index,
                label: 'Bannière ${i + 1} sur ${slides.length}',
                child: GestureDetector(
                  onTap: () =>
                      _controller.animateToPage(i, duration: const Duration(milliseconds: 350), curve: Curves.easeOut),
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: i == _index ? 20 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _index ? AppColors.green : const Color(0xFFC9D6CF),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Slide extends StatelessWidget {
  const _Slide({required this.slide, required this.position, required this.count, required this.onTap});
  final PromoSlide slide;
  final int position;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${slide.title}. ${slide.body} ${slide.cta}',
    excludeSemantics: true,
    child: Sheen(
      radius: 22,
      period: const Duration(seconds: 7),
      strength: 0.4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.2),
              gradient: LinearGradient(colors: slide.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            child: Stack(
              children: [
                // Illustration à droite : cercles décoratifs + grande icône
                Positioned(
                  right: -26,
                  top: -18,
                  child: Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.35)),
                  ),
                ),
                Positioned(
                  right: 18,
                  bottom: 18,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.75),
                      boxShadow: [
                        BoxShadow(
                          color: slide.iconColor.withValues(alpha: 0.18),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(slide.icon, size: 42, color: slide.iconColor),
                  ),
                ),
                Positioned(left: 18, top: 16, child: _Dots(color: slide.ink.withValues(alpha: 0.35))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 30, 116, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slide.tag,
                        style: TextStyle(
                          color: slide.ink,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slide.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: slide.ink, fontSize: 18, fontWeight: FontWeight.w800, height: 1.15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        slide.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: slide.ink, fontSize: 12.5, height: 1.3),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: slide.ink, borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          slide.cta,
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
                // Reflet miroir sur le haut de la bannière
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 70,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Petite grille de points décorative (comme sur les bannières d'inspiration).
class _Dots extends StatelessWidget {
  const _Dots({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var r = 0; r < 2; r++)
        Row(
          children: [
            for (var c = 0; c < 4; c++)
              Container(
                width: 3,
                height: 3,
                margin: const EdgeInsets.only(right: 4, bottom: 3),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
          ],
        ),
    ],
  );
}
