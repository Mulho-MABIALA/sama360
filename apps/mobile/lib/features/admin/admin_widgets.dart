import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/admin_models.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';

/// Largeur à partir de laquelle le back office passe en mise en page bureau (menu latéral).
const adminWide = 900.0;

enum AdminSection {
  dashboard('Tableau de bord', Icons.space_dashboard_rounded, '/admin'),
  merchants('Commerçants', Icons.storefront_rounded, '/admin/merchants'),
  payments('Paiements', Icons.payments_rounded, '/admin/payments');

  const AdminSection(this.label, this.icon, this.path);
  final String label;
  final IconData icon;
  final String path;
}

/// Coque du back office : menu latéral sur grand écran, barre d'onglets en bas sur téléphone.
class AdminShell extends ConsumerWidget {
  const AdminShell({
    super.key,
    required this.section,
    required this.title,
    required this.child,
    this.actions = const [],
    this.subtitle,
    this.back = false,
  });
  final AdminSection section;
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  /// Écran secondaire (fiche) : flèche retour au lieu du menu.
  final bool back;

  void _open(BuildContext context, AdminSection s) {
    if (s == section && !back) return;
    context.pushReplacement(s.path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    final allowed = ref.watch(platformAdminProvider);
    final pending = ref.watch(adminPaymentsProvider('pending')).value?.length ?? 0;

    final body = allowed.value == false ? const _Forbidden() : child;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(wide ? 28 : 16, wide ? 22 : 4, wide ? 28 : 16, 12),
      child: Row(
        children: [
          if (back)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                tooltip: 'Retour',
                onPressed: () => context.canPop() ? context.pop() : context.pushReplacement(section.path),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            )
          else if (!wide)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: IconButton(
                tooltip: 'Quitter le back office',
                onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: wide ? 26 : 22, fontWeight: FontWeight.w900, letterSpacing: -0.6),
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );

    final content = SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: body),
        ],
      ),
    );

    if (wide) {
      return AuroraScaffold(
        body: Row(
          children: [
            _Sidebar(current: section, pending: pending, onOpen: (s) => _open(context, s)),
            Expanded(child: content),
          ],
        ),
      );
    }
    return AuroraScaffold(
      extendBody: true,
      body: content,
      bottomNavigationBar: back
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Glass(
                radius: 26,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  children: [
                    for (final s in AdminSection.values)
                      Expanded(
                        child: _NavTab(
                          section: s,
                          selected: s == section,
                          badge: s == AdminSection.payments ? pending : 0,
                          onTap: () => _open(context, s),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Forbidden extends StatelessWidget {
  const _Forbidden();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 44, color: AppColors.muted),
          const SizedBox(height: 10),
          const Text('Réservé à l’équipe Sama360', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ],
      ),
    ),
  );
}

class _NavTab extends StatelessWidget {
  const _NavTab({required this.section, required this.selected, required this.badge, required this.onTap});
  final AdminSection section;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      key: Key('admin_tab_${section.name}'),
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.green.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Badged(
              count: badge,
              child: Icon(section.icon, color: selected ? AppColors.green : AppColors.muted, size: 22),
            ),
            const SizedBox(height: 2),
            Text(
              section.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? AppColors.green : AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Badged extends StatelessWidget {
  const _Badged({required this.count, required this.child});
  final int count;
  final Widget child;
  @override
  Widget build(BuildContext context) => count == 0
      ? child
      : Badge(label: Text('$count'), backgroundColor: AppColors.danger, textColor: Colors.white, child: child);
}

/// Menu latéral (bureau) : vert profond, comme la carte « chiffre d'affaires » de l'app.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.current, required this.pending, required this.onOpen});
  final AdminSection current;
  final int pending;
  final ValueChanged<AdminSection> onOpen;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFCDE9DD);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 0, 14),
      child: SizedBox(
        width: 248,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: AuroraBackground(
            tone: AuroraTone.deep,
            child: SafeArea(
              right: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        BrandMark(size: 38),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Sama360',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18),
                              ),
                              Text('Back office', style: TextStyle(color: muted, fontSize: 12.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    for (final s in AdminSection.values)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _SideItem(
                          section: s,
                          selected: s == current,
                          badge: s == AdminSection.payments ? pending : 0,
                          onTap: () => onOpen(s),
                        ),
                      ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Toutes les actions de l’équipe sont enregistrées dans la fiche de la boutique.',
                        style: TextStyle(color: muted.withValues(alpha: 0.9), fontSize: 11.5, height: 1.35),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      key: const Key('admin_exit'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                      icon: const Icon(Icons.logout_rounded, size: 19),
                      label: const Text('Retour à l’app'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({required this.section, required this.selected, required this.badge, required this.onTap});
  final AdminSection section;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? Colors.white.withValues(alpha: 0.14) : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: Key('admin_side_${section.name}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(section.icon, size: 21, color: selected ? AppColors.glow : const Color(0xFFCDE9DD)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.label,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
              ),
              if (badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.orange, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    '$badge',
                    style: const TextStyle(color: Color(0xFF3A1700), fontWeight: FontWeight.w900, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─────────────────────────────── briques visuelles

/// Carte de section en verre, avec titre et action facultative.
class AdminCard extends StatelessWidget {
  const AdminCard({super.key, required this.title, required this.child, this.trailing, this.padding});
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: padding ?? const EdgeInsets.fromLTRB(16, 14, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

/// Indicateur clé : icône colorée, valeur, légende, évolution.
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.hint,
    this.change,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? hint;
  final int? change;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 20,
    blur: 12,
    onTap: onTap,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: color),
            ),
            const Spacer(),
            if (change != null) TrendChip(pct: change!),
          ],
        ),
        const SizedBox(height: 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.ink, letterSpacing: -0.5),
          ),
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: AppColors.ink, fontWeight: FontWeight.w700),
        ),
        if (hint != null)
          Text(
            hint!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: AppColors.muted),
          ),
      ],
    ),
  );
}

class TrendChip extends StatelessWidget {
  const TrendChip({super.key, required this.pct, this.onDark = false});
  final int pct;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final color = onDark
        ? (up ? AppColors.glow : const Color(0xFFFFB4A8))
        : (up ? AppColors.greenDark : AppColors.danger);
    return Semantics(
      label: '${up ? 'Hausse' : 'Baisse'} de ${pct.abs()} % sur la période précédente',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(up ? Icons.north_east_rounded : Icons.south_east_rounded, size: 13, color: color),
            const SizedBox(width: 2),
            Text(
              '${up ? '+' : ''}$pct %',
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grille de tuiles qui s'adapte à la largeur (2 colonnes sur téléphone, jusqu'à [max] sur bureau).
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.children, this.max = 4, this.minTile = 170, this.height = 140});
  final List<Widget> children;
  final int max;
  final double minTile;
  final double height;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = (c.maxWidth / minTile).floor().clamp(2, max);
      const gap = 12.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final child in children) SizedBox(width: w, height: height, child: child)],
      );
    },
  );
}

/// Pastille d'état d'abonnement.
class PlanBadge extends StatelessWidget {
  const PlanBadge(this.plan, {super.key, this.daysLeft, this.onDark = false});
  final AdminPlan plan;
  final int? daysLeft;

  /// Posée sur un fond vert profond : pastille pleine, texte blanc.
  final bool onDark;

  static Color colorOf(AdminPlan p) => switch (p) {
    AdminPlan.active => const Color(0xFFB7791F),
    AdminPlan.trial => const Color(0xFF2563EB),
    AdminPlan.expired => const Color(0xFFDC2626),
    AdminPlan.free => const Color(0xFF64748B),
  };

  @override
  Widget build(BuildContext context) {
    final c = onDark ? Colors.white : AppColors.strongOf(colorOf(plan).withValues(alpha: 0.14), _darker(colorOf(plan)));
    final bg = onDark ? _darker(colorOf(plan)) : AppColors.softOf(colorOf(plan).withValues(alpha: 0.14), colorOf(plan));
    final days = daysLeft != null && (plan == AdminPlan.trial || plan == AdminPlan.active) ? ' · ${daysLeft}j' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (plan == AdminPlan.active) ...[
            Icon(Icons.workspace_premium_rounded, size: 13, color: c),
            const SizedBox(width: 3),
          ],
          Text(
            '${plan.label}$days',
            style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

Color _darker(Color c) => Color.lerp(c, Colors.black, 0.28)!;

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key, this.onDark = false});
  final AdminStatus status;
  final bool onDark;
  @override
  Widget build(BuildContext context) {
    if (status == AdminStatus.active) return const SizedBox.shrink();
    final base = status == AdminStatus.suspended ? const Color(0xFFC2410C) : const Color(0xFFDC2626);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: onDark ? base : base.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: onDark ? Colors.white : AppColors.strongOf(base.withValues(alpha: 0.13), _darker(base)),
          fontWeight: FontWeight.w800,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

/// Initiales de la boutique sur fond coloré (stable pour un même nom).
class ShopAvatar extends StatelessWidget {
  const ShopAvatar(this.name, {super.key, this.size = 42});
  final String name;
  final double size;

  static const _hues = [
    Color(0xFF0F9D6B),
    Color(0xFF2563EB),
    Color(0xFFDB2777),
    Color(0xFFB7791F),
    Color(0xFF7C3AED),
    Color(0xFF0891B2),
    Color(0xFFEA580C),
  ];

  @override
  Widget build(BuildContext context) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final initials = words.isEmpty
        ? '?'
        : (words.length == 1
                  ? words.first.substring(0, math.min(2, words.first.length))
                  : '${words[0][0]}${words[1][0]}')
              .toUpperCase();
    final c = _hues[name.codeUnits.fold<int>(0, (s, u) => s + u) % _hues.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(c, Colors.white, 0.25)!, c],
        ),
      ),
      child: Text(
        initials,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.36),
      ),
    );
  }
}

/// Courbe d'une série par jour : touchez (ou survolez) un point pour lire sa valeur.
class DailyChart extends StatefulWidget {
  const DailyChart({
    super.key,
    required this.points,
    required this.color,
    required this.format,
    this.height = 180,
    this.bars = false,
  });
  final List<DayValue> points;

  /// Barres (montants ponctuels, ex. paiements) au lieu d'une courbe.
  final bool bars;
  final Color color;
  final String Function(int) format;
  final double height;

  @override
  State<DailyChart> createState() => _DailyChartState();
}

class _DailyChartState extends State<DailyChart> {
  int? _sel;

  void _pick(Offset p, double width) {
    final n = widget.points.length;
    if (n < 2) return;
    final i = widget.bars ? (p.dx / width * n).floor() : ((p.dx / width) * (n - 1)).round();
    setState(() => _sel = i.clamp(0, n - 1));
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    final total = pts.fold<int>(0, (s, p) => s + p.value);
    final sel = _sel == null ? null : pts[_sel!];
    final df = DateFormat(pts.length > 60 ? 'MMM' : 'd MMM', 'fr');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          sel == null
              ? 'Total : ${widget.format(total)}'
              : '${DateFormat('EEEE d MMMM', 'fr').format(sel.date)} : ${widget.format(sel.value)}',
          style: TextStyle(fontSize: 12.5, color: AppColors.muted, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Semantics(
          label: 'Graphique, total ${widget.format(total)}',
          child: LayoutBuilder(
            builder: (context, c) => MouseRegion(
              onHover: (e) => _pick(e.localPosition, c.maxWidth),
              onExit: (_) => setState(() => _sel = null),
              child: GestureDetector(
                onTapDown: (d) => _pick(d.localPosition, c.maxWidth),
                onHorizontalDragUpdate: (d) => _pick(d.localPosition, c.maxWidth),
                child: SizedBox(
                  height: widget.height,
                  width: c.maxWidth,
                  child: CustomPaint(
                    painter: _LinePainter(
                      bars: widget.bars,
                      values: [for (final p in pts) p.value],
                      color: widget.color,
                      selected: _sel,
                      grid: AppColors.line,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (pts.length >= 2) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final p in [pts.first, pts[pts.length ~/ 2], pts.last])
                Text(df.format(p.date), style: TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
          ),
        ],
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.values,
    required this.color,
    required this.selected,
    required this.grid,
    this.bars = false,
  });
  final bool bars;
  final List<int> values;
  final Color color;
  final int? selected;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    if (values.length < 2) return;
    final maxV = math.max(1, values.reduce(math.max)).toDouble();
    if (bars) {
      final slot = size.width / values.length;
      final w = math.max(2.0, math.min(18.0, slot * 0.62));
      for (var i = 0; i < values.length; i++) {
        final h = (size.height - 8) * (values[i] / maxV);
        final x = slot * i + (slot - w) / 2;
        final on = selected == null || selected == i;
        final paint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: on ? 1 : 0.35),
              color.withValues(alpha: on ? 0.55 : 0.2),
            ],
          ).createShader(Rect.fromLTWH(x, size.height - h, w, h));
        if (values[i] > 0) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(x, size.height - math.max(h, 3), w, math.max(h, 3)),
              topLeft: Radius.circular(w / 3),
              topRight: Radius.circular(w / 3),
            ),
            paint,
          );
        }
      }
      return;
    }
    Offset at(int i) =>
        Offset(size.width * i / (values.length - 1), size.height - 6 - (size.height - 14) * (values[i] / maxV));
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      final a = at(i - 1), b = at(i);
      final mx = (a.dx + b.dx) / 2;
      path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round,
    );
    final s = selected;
    if (s != null) {
      final p = at(s);
      canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), Paint()..color = color.withValues(alpha: 0.35));
      canvas.drawCircle(p, 6.5, Paint()..color = Colors.white);
      canvas.drawCircle(p, 4.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.bars != bars || old.values != values || old.selected != selected || old.color != color;
}

/// Anneau de répartition (ex. abonnements) avec légende.
class Donut extends StatelessWidget {
  const Donut({super.key, required this.parts, required this.center, this.size = 132});
  final List<({String label, int value, Color color})> parts;
  final String center;
  final double size;

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<int>(0, (s, p) => s + p.value);
    return Wrap(
      spacing: 20,
      runSpacing: 14,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(size: Size.square(size), painter: _DonutPainter(parts, AppColors.line)),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 24)),
                  Text('au total', style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
                ],
              ),
            ],
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in parts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: p.color, borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 74,
                      child: Text(p.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Text('${p.value}', style: const TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(width: 6),
                    Text(
                      total == 0 ? '' : '${(p.value * 100 / total).round()} %',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.parts, this.track);
  final List<({String label, int value, Color color})> parts;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final total = parts.fold<int>(0, (s, p) => s + p.value);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (final p in parts) {
      if (p.value == 0) continue;
      final sweep = math.pi * 2 * p.value / total;
      canvas.drawArc(
        rect,
        start + 0.03,
        math.max(0.001, sweep - 0.06),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = p.color,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => true;
}

/// Barre de proportion horizontale avec libellé et valeur.
class ShareBar extends StatelessWidget {
  const ShareBar({
    super.key,
    required this.label,
    required this.value,
    required this.ratio,
    required this.color,
    this.leading,
  });
  final String label;
  final String value;
  final double ratio;
  final Color color;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: ratio.clamp(0, 1),
            minHeight: 7,
            backgroundColor: AppColors.line.withValues(alpha: 0.6),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    ),
  );
}

/// « il y a 3 j », « aujourd'hui »…
String sinceLabel(DateTime? d, {DateTime? now}) {
  if (d == null) return 'jamais';
  final n = now ?? DateTime.now();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return 'aujourd’hui';
  if (days == 1) return 'hier';
  if (days < 30) return 'il y a $days j';
  if (days < 365) return 'il y a ${days ~/ 30} mois';
  return 'il y a ${days ~/ 365} an${days >= 730 ? 's' : ''}';
}

String compactMoney(int v) {
  if (v.abs() >= 1000000) {
    return '${(v / 1000000).toStringAsFixed(v.abs() >= 10000000 ? 0 : 1).replaceAll('.', ',')} M F';
  }
  if (v.abs() >= 10000) return '${(v / 1000).round()} k F';
  return moneyShort(v);
}
