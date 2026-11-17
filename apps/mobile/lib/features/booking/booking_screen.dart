import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../customers/customer_picker.dart' show pickCustomer;
import '../sales/cart.dart' show cartProvider;
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

const _blue = Color(0xFF2F6FDB);
const durations = [15, 30, 45, 60, 90, 120, 180];

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String _key(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// « 10:30 ».
String timeLabel(DateTime d) => DateFormat('HH:mm').format(d);

/// « 1 h 30 », « 45 min ».
String durationLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')}';
}

/// « Aujourd’hui », « Demain », sinon « Jeudi 19 novembre ».
String dayTitle(DateTime d, DateTime today) {
  final diff = dayOnly(d).difference(dayOnly(today)).inDays;
  if (diff == 0) return 'Aujourd’hui';
  if (diff == 1) return 'Demain';
  if (diff == -1) return 'Hier';
  final s = DateFormat('EEEE d MMMM', 'fr').format(d);
  return s[0].toUpperCase() + s.substring(1);
}

/// Message de rappel WhatsApp au client.
String reminderMessage(Appointment a, String business, DateTime today) {
  final first = a.customerName.trim().split(' ').first;
  final when = switch (dayOnly(a.startsAt).difference(dayOnly(today)).inDays) {
    0 => 'aujourd’hui',
    1 => 'demain',
    _ => 'le ${DateFormat('EEEE d MMMM', 'fr').format(a.startsAt)}',
  };
  return 'Bonjour $first, petit rappel : votre rendez-vous (${a.serviceName}) chez $business est prévu '
      '$when à ${DateFormat("H 'h' mm", 'fr').format(a.startsAt).replaceAll(' h 00', ' h')}. À bientôt !';
}

Color statusColor(AppointmentStatus s) => switch (s) {
  AppointmentStatus.booked => _blue,
  AppointmentStatus.done => AppColors.green,
  AppointmentStatus.noShow => AppColors.warn,
  AppointmentStatus.cancelled => AppColors.muted,
};

// ---------- Agenda ----------

class BookingScreen extends ConsumerStatefulWidget {
  const BookingScreen({super.key});

  @override
  ConsumerState<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends ConsumerState<BookingScreen> {
  DateTime _day = dayOnly(DateTime.now());

  DateTime get _monday => _day.subtract(Duration(days: _day.weekday - 1));

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(appointmentsProvider(_day));
    final today = dayOnly(DateTime.now());
    final canBook = ref.can('sales:create');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Réservations', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (_day != today)
            TextButton(onPressed: () => setState(() => _day = today), child: const Text('Aujourd’hui')),
          if (ref.can('business:update'))
            IconButton(
              tooltip: 'Réservation en ligne',
              onPressed: () => context.push('/booking/settings'),
              icon: const Icon(Icons.public_rounded),
            ),
        ],
      ),
      floatingActionButton: canBook
          ? FloatingActionButton.extended(
              key: const Key('new_appointment'),
              onPressed: () => context.push('/booking/new?day=${_key(_day)}'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Rendez-vous'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(appointmentsProvider(_day));
          await ref.read(appointmentsProvider(_day).future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            _WeekStrip(
              monday: _monday,
              selected: _day,
              today: today,
              counts: list.value?.bookedByDay ?? const {},
              onSelect: (d) => setState(() => _day = d),
              onShift: (weeks) => setState(() => _day = _day.add(Duration(days: 7 * weeks))),
            ),
            const SizedBox(height: 14),
            Text(
              dayTitle(_day, today),
              key: const Key('booking_day'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            AsyncView<AppointmentList>(
              value: list,
              onRetry: () => ref.invalidate(appointmentsProvider(_day)),
              data: (l) {
                if (l.items.isEmpty) {
                  return Glass(
                    radius: 22,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Icon(Icons.event_available_rounded, size: 38, color: _blue),
                        const SizedBox(height: 8),
                        const Text('Aucun rendez-vous', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 4),
                        Text(
                          'Notez les rendez-vous de vos clients : rappel WhatsApp, encaissement en un geste.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted),
                        ),
                      ],
                    ),
                  );
                }
                final active = l.items.where((a) => a.status == AppointmentStatus.booked).toList();
                final expected = active.fold<int>(0, (s, a) => s + a.price);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (active.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          '${active.length} à venir · ${moneyShort(expected)} attendus',
                          style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                        ),
                      ),
                    for (final a in l.items) _AppointmentTile(appointment: a, onTap: () => _actions(a)),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _set(Appointment a, AppointmentStatus s, String done) async {
    try {
      await ref.read(repoProvider).updateAppointment(a.id, {'status': s.key});
      ref.invalidate(appointmentsProvider);
      if (mounted) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Encaisser : panier prérempli (prestation du catalogue, client), rendez-vous marqué « Venu ».
  Future<void> _checkout(Appointment a) async {
    final cart = ref.read(cartProvider.notifier);
    if (a.serviceId != null) {
      final products = await ref.read(productsProvider.future);
      final p = products.where((x) => x.id == a.serviceId).firstOrNull;
      if (p != null) cart.add(p);
    }
    if (a.customerId != null) {
      cart.setCustomer(Contact(id: a.customerId!, name: a.customerName, phone: a.customerPhone));
    }
    if (a.status == AppointmentStatus.booked) {
      try {
        await ref.read(repoProvider).updateAppointment(a.id, {'status': AppointmentStatus.done.key});
        ref.invalidate(appointmentsProvider);
      } catch (_) {
        // pas grave : la vente reste possible, le statut se corrige à la main
      }
    }
    if (!mounted) return;
    if (a.serviceId == null) showInfo(context, 'Ajoutez « ${a.serviceName} » au panier');
    context.go('/pos');
  }

  Future<void> _remind(Appointment a) async {
    final business = (await ref.read(currentBusinessProvider.future)).name;
    HapticFeedback.selectionClick();
    final ok = await ref
        .read(receiptActionsProvider)
        .openWhatsApp(whatsAppUri(reminderMessage(a, business, DateTime.now()), phone: a.customerPhone));
    if (!ok && mounted) showInfo(context, 'Impossible d’ouvrir WhatsApp');
  }

  Future<void> _actions(Appointment a) async {
    final canBook = ref.can('sales:create');
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(a.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${a.serviceName} · ${timeLabel(a.startsAt)} – ${timeLabel(a.endsAt)}'
                '${a.price > 0 ? ' · ${moneyShort(a.price)}' : ''}',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
            if ((a.note ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(a.note!, style: const TextStyle(fontStyle: FontStyle.italic)),
              ),
            if ((a.customerPhone ?? '').isNotEmpty)
              ListTile(
                leading: Icon(Icons.chat_rounded, color: AppColors.whatsapp),
                title: const Text('Rappel WhatsApp'),
                onTap: () => Navigator.pop(ctx, 'remind'),
              ),
            if (canBook && a.status == AppointmentStatus.booked) ...[
              ListTile(
                leading: Icon(Icons.point_of_sale_rounded, color: AppColors.green),
                title: const Text('Client venu : encaisser'),
                onTap: () => Navigator.pop(ctx, 'checkout'),
              ),
              ListTile(
                leading: Icon(Icons.check_circle_rounded, color: AppColors.green),
                title: const Text('Client venu'),
                subtitle: const Text('Déjà encaissé ou gratuit'),
                onTap: () => Navigator.pop(ctx, 'done'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_calendar_rounded),
                title: const Text('Déplacer ou modifier'),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
              ListTile(
                leading: Icon(Icons.person_off_rounded, color: AppColors.warn),
                title: const Text('Client absent'),
                onTap: () => Navigator.pop(ctx, 'no_show'),
              ),
              ListTile(
                leading: Icon(Icons.event_busy_rounded, color: AppColors.danger),
                title: const Text('Annuler le rendez-vous'),
                onTap: () => Navigator.pop(ctx, 'cancel'),
              ),
            ] else if (canBook)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('Remettre en « Prévu »'),
                onTap: () => Navigator.pop(ctx, 'rebook'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'remind':
        await _remind(a);
      case 'checkout':
        await _checkout(a);
      case 'done':
        await _set(a, AppointmentStatus.done, 'Rendez-vous terminé');
      case 'no_show':
        await _set(a, AppointmentStatus.noShow, 'Client noté absent');
      case 'cancel':
        await _set(a, AppointmentStatus.cancelled, 'Rendez-vous annulé');
      case 'rebook':
        await _set(a, AppointmentStatus.booked, 'Rendez-vous remis en « Prévu »');
      case 'edit':
        await context.push('/booking/edit', extra: a);
    }
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.monday,
    required this.selected,
    required this.today,
    required this.counts,
    required this.onSelect,
    required this.onShift,
  });
  final DateTime monday;
  final DateTime selected;
  final DateTime today;
  final Map<String, int> counts;
  final ValueChanged<DateTime> onSelect;
  final ValueChanged<int> onShift;

  @override
  Widget build(BuildContext context) {
    final month = DateFormat('MMMM y', 'fr').format(selected);
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Semaine précédente',
                onPressed: () => onShift(-1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  month[0].toUpperCase() + month.substring(1),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Semaine suivante',
                onPressed: () => onShift(1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final d = monday.add(Duration(days: i));
                      final isSel = d == selected;
                      final isToday = d == today;
                      final n = counts[_key(d)] ?? 0;
                      return InkWell(
                        key: Key('day_${_key(d)}'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => onSelect(d),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: isSel ? _blue : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            border: isToday && !isSel ? Border.all(color: _blue.withValues(alpha: 0.5)) : null,
                          ),
                          child: Column(
                            children: [
                              Text(
                                DateFormat('E', 'fr').format(d).substring(0, 3),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isSel ? Colors.white70 : AppColors.muted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${d.day}',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: isSel ? Colors.white : AppColors.ink,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: n == 0 ? Colors.transparent : (isSel ? Colors.white : _blue),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppointmentTile extends StatelessWidget {
  const _AppointmentTile({required this.appointment, required this.onTap});
  final Appointment appointment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = appointment;
    final color = statusColor(a.status);
    final faded = a.status == AppointmentStatus.cancelled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: faded ? 0.55 : 1,
        child: Glass(
          radius: 18,
          onTap: onTap,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 52,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(timeLabel(a.startsAt), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      Text(durationLabel(a.durationMinutes), style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
                    ],
                  ),
                ),
                Container(
                  width: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        a.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          decoration: faded ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (a.online)
                        Text(
                          'Réservé en ligne',
                          style: TextStyle(color: _blue, fontSize: 11.5, fontWeight: FontWeight.w800),
                        ),
                      Text(
                        a.price > 0 ? '${a.serviceName} · ${moneyShort(a.price)}' : a.serviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                      if (a.overlaps && a.status == AppointmentStatus.booked)
                        Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warn),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'Même heure qu’un autre rendez-vous',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: AppColors.warnText, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      a.status.label,
                      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Prise de rendez-vous ----------

class AppointmentEditorScreen extends ConsumerStatefulWidget {
  /// [day] : nouveau rendez-vous ce jour-là ; [appointment] : modification.
  const AppointmentEditorScreen({super.key, this.day, this.appointment});
  final DateTime? day;
  final Appointment? appointment;

  @override
  ConsumerState<AppointmentEditorScreen> createState() => _AppointmentEditorScreenState();
}

class _AppointmentEditorScreenState extends ConsumerState<AppointmentEditorScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _service = TextEditingController();
  final _price = TextEditingController();
  final _note = TextEditingController();
  Contact? _customer;
  Product? _product;
  late DateTime _date;
  TimeOfDay? _time;
  int _duration = 30;
  bool _busy = false;

  bool get _isNew => widget.appointment == null;

  @override
  void initState() {
    super.initState();
    final a = widget.appointment;
    if (a == null) {
      _date = dayOnly(widget.day ?? DateTime.now());
    } else {
      _date = dayOnly(a.startsAt);
      _time = TimeOfDay.fromDateTime(a.startsAt);
      _duration = a.durationMinutes;
      _name.text = a.customerName;
      _phone.text = a.customerPhone ?? '';
      _service.text = a.serviceName;
      _price.text = a.price > 0 ? '${a.price}' : '';
      _note.text = a.note ?? '';
      if (a.customerId != null) _customer = Contact(id: a.customerId!, name: a.customerName, phone: a.customerPhone);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _service, _price, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCustomer() async {
    final c = await pickCustomer(context);
    if (c != null) setState(() => _customer = c);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time ?? const TimeOfDay(hour: 10, minute: 0));
    if (t != null) setState(() => _time = t);
  }

  Future<void> _save() async {
    if (_customer == null && _name.text.trim().isEmpty) return showInfo(context, 'Indiquez le client');
    if (_product == null && _service.text.trim().isEmpty) return showInfo(context, 'Indiquez la prestation');
    if (_time == null) return showInfo(context, 'Choisissez l’heure');
    final starts = DateTime(_date.year, _date.month, _date.day, _time!.hour, _time!.minute);
    final price = int.tryParse(_price.text.replaceAll(RegExp(r'\D'), ''));
    final d = AppointmentDraft(
      customerId: _customer?.id,
      customerName: _name.text.trim(),
      customerPhone: _phone.text.trim(),
      serviceId: _product?.id,
      serviceName: _service.text.trim(),
      price: _product != null && _price.text.trim().isEmpty ? null : (price ?? 0),
      startsAt: starts,
      durationMinutes: _duration,
      note: _note.text,
    );
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      if (_isNew) {
        await repo.createAppointment(d);
      } else {
        await repo.updateAppointment(
          widget.appointment!.id,
          {
            ...d.toJson(),
            // On garde la prestation du catalogue si on ne l'a pas changée
            if (_product == null &&
                widget.appointment!.serviceId != null &&
                _service.text == widget.appointment!.serviceName)
              'serviceId': widget.appointment!.serviceId,
          }..removeWhere((k, v) => k == 'serviceName' && v == null),
        );
      }
      ref.invalidate(appointmentsProvider);
      if (!mounted) return;
      showInfo(context, _isNew ? 'Rendez-vous noté' : 'Rendez-vous modifié');
      context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = (ref.watch(productsProvider).value ?? const <Product>[]).where((p) => p.isService).toList();
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nouveau rendez-vous' : 'Modifier', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          const _Label('Client'),
          if (_customer != null)
            Glass(
              radius: 18,
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Avatar(name: _customer!.name, size: 38),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_customer!.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        if ((_customer!.phone ?? '').isNotEmpty)
                          Text(_customer!.phone!, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Changer de client',
                    onPressed: () => setState(() => _customer = null),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            )
          else ...[
            TextField(
              key: const Key('appt_name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nom du client'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('appt_phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone (pour le rappel WhatsApp)'),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pickCustomer,
                icon: const Icon(Icons.person_search_rounded),
                label: const Text('Choisir dans mes clients'),
              ),
            ),
          ],
          const SizedBox(height: 10),
          const _Label('Prestation'),
          if (services.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in services)
                  Pill(
                    label: '${p.name} · ${moneyShort(p.price)}',
                    selected: _product?.id == p.id,
                    onTap: () => setState(() {
                      _product = _product?.id == p.id ? null : p;
                      _service.text = _product?.name ?? '';
                      _price.text = _product == null ? '' : '${p.price}';
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('appt_service'),
                  controller: _service,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) {
                    if (_product != null) setState(() => _product = null);
                  },
                  decoration: const InputDecoration(labelText: 'Prestation', hintText: 'Ex. Tresses, retouche…'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('appt_price'),
                  controller: _price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Prix (F)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _Label('Quand ?'),
          Row(
            children: [
              Expanded(
                child: Glass(
                  radius: 16,
                  onTap: _pickDate,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.event_rounded, color: _blue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          dayTitle(_date, DateTime.now()),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Glass(
                  key: const Key('appt_time'),
                  radius: 16,
                  onTap: _pickTime,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.schedule_rounded, color: _blue),
                      const SizedBox(width: 8),
                      Text(
                        _time == null ? 'Heure' : _time!.format(context),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _time == null ? AppColors.muted : AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in durations)
                Pill(label: durationLabel(m), selected: _duration == m, onTap: () => setState(() => _duration = m)),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note (facultatif)', hintText: 'Ex. mèches fournies'),
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 52,
            child: BusyButton(
              icon: Icons.check_rounded,
              label: _isNew ? 'Noter le rendez-vous' : 'Enregistrer',
              busy: _busy,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
    ),
  );
}

// ---------- Réglages de la réservation en ligne ----------

const _dayNames = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

/// « 09:00 » → « 9 h », « 18:30 » → « 18 h 30 ».
String hourText(String hhmm) {
  final p = hhmm.split(':');
  final h = int.parse(p[0]);
  return p[1] == '00' ? '$h h' : '$h h ${p[1]}';
}

/// « 1 h avant », « la veille »…
String noticeLabel(int minutes) => switch (minutes) {
  0 => 'Sans délai',
  < 60 => '$minutes min avant',
  1440 => 'La veille',
  _ => '${minutes ~/ 60} h avant',
};

class BookingSettingsScreen extends ConsumerStatefulWidget {
  const BookingSettingsScreen({super.key});

  @override
  ConsumerState<BookingSettingsScreen> createState() => _BookingSettingsScreenState();
}

class _BookingSettingsScreenState extends ConsumerState<BookingSettingsScreen> {
  BookingSettings? _s;
  bool _busy = false;

  Future<void> _time(bool open) async {
    final s = _s!;
    final parts = (open ? s.openTime : s.closeTime).split(':').map(int.parse).toList();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: parts[0], minute: parts[1]),
    );
    if (t == null) return;
    final v = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() => _s = open ? _s!.copyWith(openTime: v) : _s!.copyWith(closeTime: v));
  }

  Future<void> _save() async {
    final s = _s!;
    if (s.closeTime.compareTo(s.openTime) <= 0) {
      return showInfo(context, 'L’heure de fermeture doit suivre l’ouverture');
    }
    if (s.openDays.isEmpty) return showInfo(context, 'Choisissez au moins un jour');
    setState(() => _busy = true);
    try {
      final saved = await ref.read(repoProvider).saveBookingSettings(s);
      ref.invalidate(bookingSettingsProvider);
      if (!mounted) return;
      setState(() {
        _s = saved;
        _busy = false;
      });
      showInfo(context, saved.onlineEnabled ? 'Réservation en ligne ouverte' : 'Réglages enregistrés');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _share(String url) async {
    final business = (await ref.read(currentBusinessProvider.future)).name;
    final ok = await ref
        .read(receiptActionsProvider)
        .openWhatsApp(whatsAppUri('Prenez rendez-vous chez $business directement en ligne : $url'));
    if (!ok && mounted) showInfo(context, 'Impossible d’ouvrir WhatsApp');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(bookingSettingsProvider);
    if (_s == null && async.value != null) _s = async.value;
    final services = (ref.watch(productsProvider).value ?? const <Product>[]).where((p) => p.isService).length;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Réservation en ligne', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: _s == null
          ? AsyncView<BookingSettings>(
              value: async,
              onRetry: () => ref.invalidate(bookingSettingsProvider),
              data: (_) => const SizedBox.shrink(),
            )
          : Builder(
              builder: (context) {
                final s = _s!;
                final url = s.bookingPath == null
                    ? null
                    : '${ref.watch(apiBaseUrlProvider).replaceAll(RegExp(r'/+$'), '')}${s.bookingPath}';
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    Glass(
                      radius: 22,
                      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                      child: SwitchListTile(
                        key: const Key('booking_online'),
                        contentPadding: EdgeInsets.zero,
                        value: s.onlineEnabled,
                        onChanged: (v) => setState(() => _s = _s!.copyWith(onlineEnabled: v)),
                        title: const Text(
                          'Les clients réservent en ligne',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          'Ils choisissent la prestation et un créneau libre ; le rendez-vous arrive dans votre agenda.',
                          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                        ),
                      ),
                    ),
                    if (services == 0) ...[
                      const SizedBox(height: 10),
                      Material(
                        color: AppColors.warnBg,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'Ajoutez d’abord vos prestations dans le catalogue (type « Service », avec leur durée) : '
                            'ce sont elles que vos clients pourront réserver.',
                            key: const Key('booking_no_services'),
                            style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                    if (url != null && s.onlineEnabled) ...[
                      const SizedBox(height: 10),
                      Glass(
                        radius: 20,
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Votre lien de réservation', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                            const SizedBox(height: 4),
                            SelectableText(
                              url,
                              key: const Key('booking_url'),
                              style: const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(ClipboardData(text: url));
                                      if (context.mounted) showInfo(context, 'Lien copié');
                                    },
                                    icon: const Icon(Icons.copy_rounded, size: 18),
                                    label: const Text('Copier'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.whatsapp,
                                      foregroundColor: const Color(0xFF08361A),
                                    ),
                                    onPressed: () => _share(url),
                                    icon: const Icon(Icons.chat_rounded, size: 18),
                                    label: const Text('WhatsApp'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    const _Label('Jours d’ouverture'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var d = 1; d <= 7; d++)
                          Pill(
                            label: _dayNames[d - 1],
                            selected: s.openDays.contains(d),
                            onTap: () => setState(
                              () => _s = _s!.copyWith(
                                openDays: _s!.openDays.contains(d)
                                    ? (_s!.openDays.where((x) => x != d).toList())
                                    : ([..._s!.openDays, d]..sort()),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _Label('Horaires'),
                    Row(
                      children: [
                        for (final open in [true, false]) ...[
                          Expanded(
                            child: Glass(
                              radius: 16,
                              onTap: () => _time(open),
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    open ? 'Ouverture' : 'Fermeture',
                                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                                  ),
                                  Text(
                                    hourText(open ? s.openTime : s.closeTime),
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (open) const SizedBox(width: 10),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _Label('Créneaux proposés toutes les'),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final m in const [15, 30, 60])
                          Pill(
                            label: durationLabel(m),
                            selected: s.slotMinutes == m,
                            onTap: () => setState(() => _s = _s!.copyWith(slotMinutes: m)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _Label('Clients reçus en même temps'),
                    Glass(
                      radius: 16,
                      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.capacity == 1
                                  ? '1 à la fois'
                                  : '${s.capacity} à la fois (ex. ${s.capacity} coiffeuses)',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                            key: const Key('capacity_minus'),
                            tooltip: 'Un client de moins en même temps',
                            onPressed: s.capacity > 1
                                ? () => setState(() => _s = _s!.copyWith(capacity: _s!.capacity - 1))
                                : null,
                            icon: const Icon(Icons.remove_circle_outline_rounded),
                          ),
                          Text(
                            '${s.capacity}',
                            key: const Key('booking_capacity'),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                          IconButton(
                            key: const Key('capacity_plus'),
                            tooltip: 'Un client de plus en même temps',
                            onPressed: s.capacity < 20
                                ? () => setState(() => _s = _s!.copyWith(capacity: _s!.capacity + 1))
                                : null,
                            icon: const Icon(Icons.add_circle_outline_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _Label('Réserver au plus tard'),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in const [0, 30, 60, 120, 1440])
                          Pill(
                            label: noticeLabel(m),
                            selected: s.minNoticeMinutes == m,
                            onTap: () => setState(() => _s = _s!.copyWith(minNoticeMinutes: m)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const _Label('Jusqu’à combien de jours à l’avance'),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final d in const [7, 14, 30, 60])
                          Pill(
                            label: '$d jours',
                            selected: s.maxDaysAhead == d,
                            onTap: () => setState(() => _s = _s!.copyWith(maxDaysAhead: d)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      height: 52,
                      child: BusyButton(icon: Icons.check_rounded, label: 'Enregistrer', busy: _busy, onPressed: _save),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
