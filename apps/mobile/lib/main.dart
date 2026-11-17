import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api/session_store.dart';
import 'core/display.dart';
import 'core/offline/kv_store.dart';
import 'core/offline/pending_sales.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr');
  // Cache hors ligne et ventes en attente : gardés sur le téléphone entre deux lancements.
  KeyValueStore store;
  try {
    store = PrefsStore(await SharedPreferences.getInstance());
  } catch (_) {
    store = MemoryStore();
  }
  runApp(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWithValue(SecureSessionStore()),
        keyValueStoreProvider.overrideWithValue(store),
      ],
      child: const SamaApp(),
    ),
  );
}

class SamaApp extends ConsumerWidget {
  const SamaApp({super.key, this.googleFonts = true});
  final bool googleFonts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = ref.watch(displaySettingsProvider);
    final brand = ref.watch(brandColorProvider);
    return MaterialApp.router(
      title: 'Sama360',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(SamaPalette.light(brand), googleFonts: googleFonts),
      darkTheme: AppTheme.build(SamaPalette.dark(brand), googleFonts: googleFonts),
      themeMode: display.mode,
      routerConfig: ref.watch(routerProvider),
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) {
        // Mode effectif (système, clair ou sombre) et couleur de la boutique → palette de l'app.
        syncPalette(Theme.of(context).brightness, brand);
        if (!display.largeText) return child!;
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear((mq.textScaler.scale(1) * largeTextScale).clamp(1.0, 2.0))),
          child: child!,
        );
      },
    );
  }
}
