// Back office de l'équipe Sama360 : application web à part, servie sur /admin.
// Rien de commun à l'écran avec l'app des commerçants : sa propre connexion, ses propres écrans.
// Construction : flutter build web -t lib/admin_main.dart --base-href /admin/ -o build/admin
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api/session_store.dart';
import 'core/display.dart' show syncPalette;
import 'core/models.dart' show OtpTarget;
import 'core/glass.dart';
import 'core/offline/kv_store.dart';
import 'core/offline/pending_sales.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'features/admin/admin_feedback.dart';
import 'features/admin/admin_dashboard.dart';
import 'features/admin/admin_merchant.dart';
import 'features/admin/admin_merchants.dart';
import 'features/admin/admin_payments.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Safari sur iPhone : sans flou ni fond animé (voir main.dart)
  if (Motion.iosWeb) {
    Motion.blur = false;
    Motion.enabled = false;
  }
  await initializeDateFormatting('fr');
  KeyValueStore store;
  try {
    store = PrefsStore(await SharedPreferences.getInstance());
  } catch (_) {
    store = MemoryStore();
  }
  runApp(
    ProviderScope(
      overrides: [
        // Session propre au back office (clé différente de l'app web des commerçants)
        sessionStoreProvider.overrideWithValue(PrefsSessionStore(prefix: 'admin.')),
        keyValueStoreProvider.overrideWithValue(store),
      ],
      child: const AdminApp(),
    ),
  );
}

/// Où envoyer la personne : connexion, puis back office si son numéro est administrateur.
String? adminRedirect(AsyncValue<AuthState> auth, AsyncValue<bool> admin, String location) {
  const publicRoutes = ['/login', '/otp'];
  if (auth.isLoading && !auth.hasValue) return location == '/splash' ? null : '/splash';
  if (auth.hasError && !auth.hasValue) return location == '/splash' ? null : '/splash';
  if (!auth.value!.signedIn) return publicRoutes.contains(location) ? null : '/login';
  if (!admin.hasValue) return location == '/splash' ? null : '/splash';
  if (admin.value != true) return location == '/denied' ? null : '/denied';
  if (publicRoutes.contains(location) || location == '/splash' || location == '/denied' || location == '/') {
    return '/admin';
  }
  return null;
}

class _Refresh extends ChangeNotifier {
  void notify() => notifyListeners();
}

final adminRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _Refresh();
  ref.listen(authProvider, (prev, next) {
    // Nouvelle connexion (ou déconnexion) : revérifier si ce numéro est administrateur
    if (prev?.value?.signedIn != next.value?.signedIn) ref.invalidate(platformAdminProvider);
    refresh.notify();
  });
  ref.listen(platformAdminProvider, (_, _) => refresh.notify());
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (_, state) =>
        adminRedirect(ref.read(authProvider), ref.read(platformAdminProvider), state.matchedLocation),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const _AdminSplash()),
      GoRoute(path: '/splash', builder: (_, _) => const _AdminSplash()),
      GoRoute(path: '/denied', builder: (_, _) => const _AdminDenied()),
      GoRoute(
        path: '/login',
        builder: (_, _) => const PhoneScreen(tagline: 'Back office · équipe Sama360'),
      ),
      GoRoute(
        path: '/otp',
        builder: (_, s) =>
            OtpScreen(target: s.extra is OtpTarget ? s.extra! as OtpTarget : OtpTarget(s.extra as String? ?? '')),
      ),
      GoRoute(path: '/admin', builder: (_, _) => const AdminDashboardScreen()),
      GoRoute(path: '/admin/merchants', builder: (_, _) => const AdminMerchantsScreen()),
      GoRoute(
        path: '/admin/merchants/:id',
        builder: (_, s) => AdminMerchantScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(path: '/admin/payments', builder: (_, _) => const AdminPaymentsScreen()),
      GoRoute(path: '/admin/feedback', builder: (_, _) => const AdminFeedbackScreen()),
    ],
  );
});

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key, this.googleFonts = true});
  final bool googleFonts;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Sama360 · Back office',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.build(SamaPalette.light(), googleFonts: googleFonts),
    themeMode: ThemeMode.light,
    routerConfig: ref.watch(adminRouterProvider),
    locale: const Locale('fr'),
    supportedLocales: const [Locale('fr')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) {
      syncPalette(Brightness.light, defaultBrand);
      return child!;
    },
  );
}

class _AdminSplash extends StatelessWidget {
  const _AdminSplash();
  @override
  Widget build(BuildContext context) => const AuroraScaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(size: 64),
          SizedBox(height: 18),
          SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.6)),
        ],
      ),
    ),
  );
}

/// Connecté, mais ce numéro n'est pas dans ADMIN_PHONES.
class _AdminDenied extends ConsumerWidget {
  const _AdminDenied();
  @override
  Widget build(BuildContext context, WidgetRef ref) => AuroraScaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Glass(
            radius: 28,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded, size: 48, color: AppColors.muted),
                const SizedBox(height: 12),
                const Text(
                  'Réservé à l’équipe Sama360',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
                ),
                const SizedBox(height: 6),
                Text(
                  'Ce numéro n’a pas accès au back office. Les commerçants utilisent l’application Sama360.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  key: const Key('admin_denied_logout'),
                  onPressed: () => ref.read(authProvider.notifier).signOut(),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Changer de numéro'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
