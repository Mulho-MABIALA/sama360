import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

import 'core/api/session_store.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr');
  runApp(
    ProviderScope(
      overrides: [sessionStoreProvider.overrideWithValue(SecureSessionStore())],
      child: const SamaApp(),
    ),
  );
}

class SamaApp extends ConsumerWidget {
  const SamaApp({super.key, this.googleFonts = true});
  final bool googleFonts;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Sama360',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(googleFonts: googleFonts),
    routerConfig: ref.watch(routerProvider),
    locale: const Locale('fr'),
    supportedLocales: const [Locale('fr'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
  );
}
