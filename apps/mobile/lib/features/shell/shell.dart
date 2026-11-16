import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';

/// Barre de navigation du bas : Accueil, Caisse, Stock, Crédits, Compte.
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
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Compte',
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

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).value;
    final me = auth?.me;
    final business = ref.watch(currentBusinessProvider).value;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Compte', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              leading: Avatar(name: me?.fullName),
              title: Text(me?.fullName ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(me == null ? '' : '+221 ${displayPhone(me.phone)}'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.storefront_outlined, color: AppColors.green),
                  title: Text(auth?.business?.name ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(auth?.business?.roleName ?? ''),
                  trailing: const Text('Changer'),
                  onTap: () => context.push('/business'),
                ),
                if (business != null) ...[
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.link, color: AppColors.green),
                    title: const Text('Ma boutique en ligne'),
                    subtitle: Text('sama360.com/${business.slug}'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Se déconnecter ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Déconnexion')),
                  ],
                ),
              );
              if (ok == true) await ref.read(authProvider.notifier).signOut();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Se déconnecter'),
          ),
        ],
      ),
    );
  }
}
