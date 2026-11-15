import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';

/// Barre de navigation du bas : Accueil, Caisse, Stock, Crédits, Compte.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: shell,
    bottomNavigationBar: DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Color(0x1413241C), blurRadius: 24, offset: Offset(0, -4))],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Compte'),
          ],
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
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SamaLogo(size: 36),
            const SizedBox(height: 24),
            if (auth.hasError)
              ErrorPanel(message: errorMessage(auth.error!), onRetry: () => ref.read(authProvider.notifier).reload())
            else
              const CircularProgressIndicator(),
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
    return Scaffold(
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
