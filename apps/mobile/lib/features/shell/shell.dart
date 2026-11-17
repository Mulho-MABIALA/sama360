import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../offline/offline_ui.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../sales/cart.dart';

/// Barre de navigation du bas : Accueil, Stock, gros bouton « Vendre » au centre, Clients, Ventes
/// (le profil s'ouvre depuis l'avatar). Vendre est l'action principale : toujours à un pouce.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  void _go(int branch) => shell.goBranch(branch, initialLocation: branch == shell.currentIndex);

  @override
  Widget build(BuildContext context) => AuroraScaffold(
    // Les pages passent sous la barre : le verre floute leur fond.
    extendBody: true,
    padBottom: false,
    body: SyncScheduler(child: shell),
    // Barre flottante en verre dépoli, bouton Vendre en relief au centre.
    bottomNavigationBar: SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            Glass(
              radius: 30,
              blur: 24,
              child: SizedBox(
                height: 66,
                child: Row(
                  children: [
                    _Tab(
                      label: 'Accueil',
                      icon: Icons.home_outlined,
                      selectedIcon: Icons.home_rounded,
                      selected: shell.currentIndex == 0,
                      onTap: () => _go(0),
                    ),
                    _Tab(
                      label: 'Stock',
                      icon: Icons.inventory_2_outlined,
                      selectedIcon: Icons.inventory_2,
                      selected: shell.currentIndex == 2,
                      onTap: () => _go(2),
                    ),
                    const SizedBox(width: 78), // place du bouton Vendre
                    _Tab(
                      label: 'Clients',
                      icon: Icons.people_alt_outlined,
                      selectedIcon: Icons.people_alt,
                      selected: shell.currentIndex == 3,
                      onTap: () => _go(3),
                    ),
                    _Tab(
                      label: 'Ventes',
                      icon: Icons.receipt_long_outlined,
                      selectedIcon: Icons.receipt_long,
                      selected: false,
                      onTap: () => context.push('/sales'),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 14,
              child: SellButton(selected: shell.currentIndex == 1, onTap: () => _go(1)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.green : AppColors.muted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkResponse(
          onTap: onTap,
          radius: 34,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: selected ? AppColors.green.withValues(alpha: 0.13) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(selected ? selectedIcon : icon, color: color, size: 24),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gros bouton rond « Vendre » : couleur de la boutique, relief, nombre d'articles du panier.
class SellButton extends ConsumerWidget {
  const SellButton({super.key, required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(cartProvider).itemCount;
    final n = items.ceil();
    return Semantics(
      button: true,
      selected: selected,
      label: n > 0 ? 'Vendre, $n article${n > 1 ? 's' : ''} au panier' : 'Vendre',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.leaf, AppColors.green],
                    ),
                    border: Border.all(color: AppColors.isDark ? AppColors.ground : Colors.white, width: 4),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.green.withValues(alpha: selected ? 0.55 : 0.4),
                        blurRadius: selected ? 22 : 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(Icons.point_of_sale_rounded, color: AppColors.onGreen, size: 28),
                ),
                if (n > 0)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      key: const Key('cart_badge'),
                      constraints: const BoxConstraints(minWidth: 22),
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.orange,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: AppColors.isDark ? AppColors.ground : Colors.white, width: 2),
                      ),
                      child: Text(
                        n > 99 ? '99+' : '$n',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Vendre',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: AppColors.green),
            ),
          ],
        ),
      ),
    );
  }
}

/// Démarrage : chargement de la session, ou erreur réseau avec « Réessayer ».
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return AuroraScaffold(
      tone: AuroraTone.deep,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MirrorReflection(size: 84, child: BrandMark(size: 84)),
            const SizedBox(height: 8),
            const SamaLogo(size: 36, onDark: true),
            const SizedBox(height: 6),
            const Text('Un seul compte. Plusieurs services.', style: TextStyle(color: Color(0xFFCDE9DD))),
            const SizedBox(height: 28),
            if (auth.hasError)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Glass(
                  padding: const EdgeInsets.all(16),
                  child: ErrorPanel(
                    message: errorMessage(auth.error!),
                    onRetry: () => ref.read(authProvider.notifier).reload(),
                  ),
                ),
              )
            else
              const CircularProgressIndicator(color: AppColors.glow),
          ],
        ),
      ),
    );
  }
}
