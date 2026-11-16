import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/glass.dart';
import '../../core/theme.dart';
import 'monuments_data.dart';

/// Une photo de monument (Wikimedia Commons, licence libre) embarquée dans l'app.
class Monument {
  const Monument({
    required this.name,
    required this.place,
    required this.asset,
    required this.author,
    required this.license,
    required this.source,
  });
  final String name;
  final String place;
  final String asset;
  final String author;
  final String license;
  final String source;
}

/// Jour de référence : ce jour-là, l'accueil montre le premier monument de la liste.
final _origin = DateTime.utc(2026, 11, 16);

/// Le monument du jour : il change à minuit (heure du téléphone) et revient
/// tous les `monuments.length` jours.
Monument monumentOfDay(DateTime date, [List<Monument> list = monuments]) {
  final day = DateTime.utc(date.year, date.month, date.day);
  final index = day.difference(_origin).inDays % list.length;
  return list[index];
}

/// Date utilisée pour choisir le monument (remplaçable dans les tests).
final monumentDateProvider = Provider<DateTime>((ref) => DateTime.now());

/// Photo du monument du jour en plein fond, assombrie pour que le texte blanc
/// reste lisible. Si l'image ne se charge pas, le dégradé vert d'origine reste visible.
class MonumentBackdrop extends ConsumerWidget {
  const MonumentBackdrop({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = monumentOfDay(ref.watch(monumentDateProvider));
    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            m.asset,
            key: ValueKey(m.asset),
            fit: BoxFit.cover,
            alignment: const Alignment(0, -0.2),
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 500),
                    child: child,
                  ),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          // Voile : sombre en haut (logo, salutation), vert profond en bas (carte caisse).
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.3, 0.6, 1],
                colors: [
                  Color(0x8C000000),
                  Color(0x1A000000),
                  Color(0x33052A1F),
                  Color(0xB3052A1F),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Petite étiquette « 📍 nom du monument » ; un appui affiche le lieu et le crédit photo.
class MonumentChip extends ConsumerWidget {
  const MonumentChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = monumentOfDay(ref.watch(monumentDateProvider));
    return Tooltip(
      message: 'Monument du jour',
      child: Glass(
        tone: GlassTone.dark,
        radius: 20,
        blur: 10,
        shadow: false,
        onTap: () => showMonumentCredits(context, m),
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.place_rounded, size: 14, color: AppColors.glow),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showMonumentCredits(BuildContext context, Monument m) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.asset(m.asset, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
            ),
          ),
          const SizedBox(height: 14),
          Text('Monument du jour', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 2),
          Text(m.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(Icons.place_rounded, size: 16, color: AppColors.green),
              const SizedBox(width: 4),
              Expanded(child: Text(m.place, style: const TextStyle(color: AppColors.muted))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Photo : ${m.author} — ${m.license}, via Wikimedia Commons',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => launchUrl(Uri.parse(m.source), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Voir la photo et sa licence'),
          ),
          const SizedBox(height: 4),
          const Text('Un nouveau monument chaque jour.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
        ],
      ),
    ),
  ),
);
