import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';

/// Barre de navigation du bas : Accueil, Caisse, Stock, Crédits (le profil s'ouvre depuis l'avatar).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => AuroraScaffold(
    // Les pages passent sous la barre : le verre floute leur fond.
    extendBody: true,
    padBottom: false,
    body: shell,
    // Barre flottante en verre dépoli.
    bottomNavigationBar: SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        child: Glass(
          radius: 30,
          blur: 24,
          child: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Accueil',
              ),
              NavigationDestination(
                icon: Icon(Icons.point_of_sale_outlined),
                selectedIcon: Icon(Icons.point_of_sale),
                label: 'Caisse',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: 'Stock',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: 'Crédits',
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
