import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/photos.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../customers/customer_picker.dart' show pickCustomer;
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

const _orange = Color(0xFFD9822B);

/// Lien Google Maps vers une adresse écrite.
String mapsLink(String address, String? city) {
  final q = [address, if ((city ?? '').isNotEmpty) city].join(', ');
  return 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeQueryComponent(q).replaceAll('+', '%20')}';
}

/// Message WhatsApp au livreur : tout ce qu'il faut pour la course.
String courierMessage(Delivery d, {required String business, String? city}) {
  final lines = [
    '🛵 *Course $business*${d.orderNumber == null ? '' : ' (${d.orderNumber})'}',
    'Client : ${d.customerName}${(d.customerPhone ?? '').isEmpty ? '' : ' · ${d.customerPhone}'}',
    'Adresse : ${d.address}',
    'Carte : ${mapsLink(d.address, city)}',
    if (d.amountToCollect > 0)
      '💰 À encaisser : *${moneyShort(d.amountToCollect).replaceAll(' ', ' ')}*'
    else
      'Rien à encaisser (déjà payé)',
    if ((d.note ?? '').isNotEmpty) 'Note : ${d.note}',
  ];
  return lines.join('\n');
}

Color deliveryColor(DeliveryStatus s) => switch (s) {
  DeliveryStatus.pending => AppColors.warn,
  DeliveryStatus.assigned => const Color(0xFF2F6FDB),
  DeliveryStatus.picked => _orange,
  DeliveryStatus.delivered => AppColors.green,
  DeliveryStatus.failed => AppColors.danger,
  DeliveryStatus.cancelled => AppColors.muted,
};

IconData vehicleIcon(String v) => switch (v) {
  'voiture' => Icons.directions_car_rounded,
  'velo' => Icons.pedal_bike_rounded,
  'pied' => Icons.directions_walk_rounded,
  _ => Icons.two_wheeler_rounded,
};

/// Choisir un livreur actif (ou en ajouter un tout de suite).
Future<Courier?> pickCourier(BuildContext context, WidgetRef ref) async {
  final couriers = (await ref.read(couriersProvider.future)).where((c) => c.active).toList();
  if (!context.mounted) return null;
  return showModalBottomSheet<Courier>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Quel livreur ?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          for (final c in couriers)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: _orange.withValues(alpha: 0.14),
                child: Icon(vehicleIcon(c.vehicle), color: _orange),
              ),
              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: c.phone == null ? null : Text(c.phone!),
              onTap: () => Navigator.pop(ctx, c),
            ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_add_rounded)),
            title: const Text('Ajouter un livreur'),
            onTap: () async {
              final c = await courierDialog(ctx, ref);
              if (c != null && ctx.mounted) Navigator.pop(ctx, c);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Ajouter (ou modifier) un livreur.
Future<Courier?> courierDialog(BuildContext context, WidgetRef ref, {Courier? courier}) async {
  final name = TextEditingController(text: courier?.name ?? '');
  final phone = TextEditingController(text: courier?.phone ?? '');
  var vehicle = courier?.vehicle ?? 'moto';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(courier == null ? 'Nouveau livreur' : 'Modifier le livreur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('courier_name'),
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nom'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('courier_phone'),
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone (WhatsApp)'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in vehicleLabels.entries)
                  Pill(label: e.value, selected: vehicle == e.key, onTap: () => setState(() => vehicle = e.key)),
              ],
            ),
          ],
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Enregistrer', onPressed: () => Navigator.pop(ctx, name.text.trim().length >= 2)),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  try {
    final repo = ref.read(repoProvider);
    final c = courier == null
        ? await repo.addCourier(name: name.text.trim(), phone: phone.text.trim(), vehicle: vehicle)
        : await repo.updateCourier(courier.id, {
            'name': name.text.trim(),
            'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
            'vehicle': vehicle,
          });
    ref.invalidate(couriersProvider);
    return c;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

// ---------- Suivi des livraisons ----------

class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});

  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  bool _done = false;

  Future<void> _run(Future<void> Function() task, String done) async {
    try {
      await task();
      refreshDeliveries(ref);
      ref.invalidate(shopProvider);
      if (mounted) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _assignOrder(OrderToDeliver o) async {
    final c = await pickCourier(context, ref);
    if (c == null) return;
    final d = await ref.read(repoProvider).createDelivery({'orderId': o.orderId, 'courierId': c.id}).catchError((
      Object e,
    ) {
      if (mounted) showError(context, e);
      throw e;
    });
    refreshDeliveries(ref);
    if (mounted) await _sendToCourier(d);
  }

  Future<void> _sendToCourier(Delivery d) async {
    final b = await ref.read(currentBusinessProvider.future);
    final ok = await ref
        .read(receiptActionsProvider)
        .openWhatsApp(
          whatsAppUri(
            courierMessage(d, business: b.name, city: b.city),
            phone: d.courierPhone,
          ),
        );
    if (!ok && mounted) showInfo(context, 'Impossible d’ouvrir WhatsApp');
  }

  Future<void> _settle(CourierBalance c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c.name} vous a remis ${moneyShort(c.owed)} ?'),
        content: Text(
          'Encaissé sur ${c.deliveries} livraison${c.deliveries > 1 ? 's' : ''}. Pensez à le mettre en caisse.',
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Argent reçu', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) await _run(() => ref.read(repoProvider).settleCourier(c.courierId), 'Argent reçu de ${c.name}');
  }

  Future<String?> _failureReason() async {
    final ctrl = TextEditingController();
    const reasons = ['Client absent', 'Client injoignable', 'Adresse introuvable', 'Client a refusé'];
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Que s’est-il passé ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final r in reasons) Pill(label: r, selected: false, onTap: () => Navigator.pop(ctx, r))],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Autre raison'),
            ),
          ],
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(
            label: 'Valider',
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'Échec' : ctrl.text.trim()),
          ),
        ],
      ),
    );
  }

  Future<void> _actions(Delivery d) async {
    final active = d.status != DeliveryStatus.delivered && d.status != DeliveryStatus.cancelled;
    final canAssign =
        d.status == DeliveryStatus.pending || d.status == DeliveryStatus.failed || d.status == DeliveryStatus.assigned;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
                child: Text(d.customerName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '${d.address}${d.amountToCollect > 0 ? ' · à encaisser ${moneyShort(d.amountToCollect)}' : ''}',
                  style: TextStyle(color: AppColors.muted),
                ),
              ),
              if (d.courierId != null && active)
                ListTile(
                  leading: Icon(Icons.chat_rounded, color: AppColors.whatsapp),
                  title: Text('Envoyer la course à ${d.courierName}'),
                  subtitle: const Text('Adresse, carte, client, montant'),
                  onTap: () => Navigator.pop(ctx, 'send'),
                ),
              if ((d.customerPhone ?? '').isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.phone_in_talk_rounded),
                  title: const Text('Écrire au client'),
                  onTap: () => Navigator.pop(ctx, 'client'),
                ),
              if (canAssign)
                ListTile(
                  leading: const Icon(Icons.two_wheeler_rounded),
                  title: Text(d.courierId == null ? 'Choisir un livreur' : 'Changer de livreur'),
                  onTap: () => Navigator.pop(ctx, 'assign'),
                ),
              if (d.status == DeliveryStatus.assigned)
                ListTile(
                  leading: const Icon(Icons.local_shipping_rounded, color: _orange),
                  title: const Text('Colis récupéré : en route'),
                  onTap: () => Navigator.pop(ctx, 'picked'),
                ),
              if (d.status == DeliveryStatus.assigned || d.status == DeliveryStatus.picked) ...[
                ListTile(
                  leading: Icon(Icons.check_circle_rounded, color: AppColors.green),
                  title: const Text('Livrée'),
                  subtitle: d.amountToCollect > 0
                      ? Text('${moneyShort(d.amountToCollect)} encaissés par le livreur')
                      : null,
                  onTap: () => Navigator.pop(ctx, 'delivered'),
                ),
                ListTile(
                  leading: Icon(Icons.report_rounded, color: AppColors.danger),
                  title: const Text('Échec de livraison'),
                  onTap: () => Navigator.pop(ctx, 'failed'),
                ),
              ],
              if (active)
                ListTile(
                  leading: Icon(Icons.close_rounded, color: AppColors.muted),
                  title: const Text('Annuler la livraison'),
                  onTap: () => Navigator.pop(ctx, 'cancel'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final repo = ref.read(repoProvider);
    switch (choice) {
      case 'send':
        await _sendToCourier(d);
      case 'client':
        await ref
            .read(receiptActionsProvider)
            .openWhatsApp(
              whatsAppUri(
                'Bonjour ${d.customerName.split(' ').first}, votre livraison est en route.',
                phone: d.customerPhone,
              ),
            );
      case 'assign':
        final c = await pickCourier(context, ref);
        if (c == null) return;
        await _run(() async {
          final updated = await repo.updateDelivery(d.id, {'courierId': c.id});
          if (mounted) await _sendToCourier(updated);
        }, 'Livraison confiée à ${c.name}');
      case 'picked':
        await _run(() => repo.updateDelivery(d.id, {'status': 'picked'}), 'Livraison en route');
      case 'delivered':
        await _run(() => repo.updateDelivery(d.id, {'status': 'delivered'}), 'Livraison terminée');
      case 'failed':
        final why = await _failureReason();
        if (why == null) return;
        await _run(() => repo.updateDelivery(d.id, {'status': 'failed', 'failureReason': why}), 'Échec noté');
      case 'cancel':
        await _run(() => repo.updateDelivery(d.id, {'status': 'cancelled'}), 'Livraison annulée');
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(deliveryBoardProvider(_done));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Livraisons', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Mes livreurs',
            onPressed: () => context.push('/deliveries/couriers'),
            icon: const Icon(Icons.groups_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new_delivery'),
        onPressed: () async {
          await context.push('/deliveries/new');
          refreshDeliveries(ref);
        },
        icon: const Icon(Icons.add_rounded),
        label: const Text('Livraison'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(deliveryBoardProvider(_done));
          await ref.read(deliveryBoardProvider(_done).future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            Row(
              children: [
                Pill(label: 'En cours', selected: !_done, onTap: () => setState(() => _done = false)),
                const SizedBox(width: 8),
                Pill(label: 'Terminées', selected: _done, onTap: () => setState(() => _done = true)),
              ],
            ),
            const SizedBox(height: 14),
            AsyncView<DeliveryBoard>(
              value: board,
              onRetry: () => ref.invalidate(deliveryBoardProvider(_done)),
              data: (b) {
                final empty = b.items.isEmpty && (_done || (b.toAssign.isEmpty && b.withCouriers.isEmpty));
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_done && b.withCouriers.isNotEmpty) ...[
                      _Title(Icons.payments_rounded, 'Argent chez les livreurs'),
                      for (final c in b.withCouriers) _OwedTile(balance: c, onSettle: () => _settle(c)),
                      const SizedBox(height: 14),
                    ],
                    if (!_done && b.toAssign.isNotEmpty) ...[
                      _Title(Icons.shopping_bag_rounded, 'Commandes en ligne à livrer'),
                      for (final o in b.toAssign) _OrderTile(order: o, onAssign: () => _assignOrder(o)),
                      const SizedBox(height: 14),
                    ],
                    if (b.items.isNotEmpty) ...[
                      if (!_done) _Title(Icons.local_shipping_rounded, 'Courses'),
                      for (final d in b.items) _DeliveryTile(delivery: d, onTap: () => _actions(d)),
                    ],
                    if (empty)
                      Glass(
                        radius: 22,
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            const PhotoThumb(Photos.livraison, size: 84, radius: 22, color: _orange),
                            const SizedBox(height: 8),
                            Text(
                              _done ? 'Aucune livraison ces 30 derniers jours' : 'Aucune livraison en cours',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Confiez une course à un livreur : il reçoit l’adresse, la carte et le montant à encaisser '
                              'sur WhatsApp.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.muted),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Row(
      children: [
        Icon(icon, size: 19, color: _orange),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
      ],
    ),
  );
}

class _OwedTile extends StatelessWidget {
  const _OwedTile({required this.balance, required this.onSettle});
  final CourierBalance balance;
  final VoidCallback onSettle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Glass(
      radius: 18,
      tint: const Color(0xFFF2A93B),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(balance.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  '${moneyShort(balance.owed)} · ${balance.deliveries} livraison${balance.deliveries > 1 ? 's' : ''}',
                  style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ],
            ),
          ),
          FilledButton(
            key: Key('settle_${balance.courierId}'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            onPressed: onSettle,
            child: const Text('Argent reçu'),
          ),
        ],
      ),
    ),
  );
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order, required this.onAssign});
  final OrderToDeliver order;
  final VoidCallback onAssign;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Glass(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${order.customerName} · ${order.number}', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(
                  order.address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
                Text(moneyShort(order.total), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          FilledButton.icon(
            key: Key('assign_${order.orderId}'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            onPressed: onAssign,
            icon: const Icon(Icons.two_wheeler_rounded, size: 18),
            label: const Text('Assigner'),
          ),
        ],
      ),
    ),
  );
}

class _DeliveryTile extends StatelessWidget {
  const _DeliveryTile({required this.delivery, required this.onTap});
  final Delivery delivery;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    final color = deliveryColor(d.status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 18,
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                PhotoThumb(
                  Photos.livraison,
                  size: 46,
                  radius: 14,
                  fallback: Icons.local_shipping_rounded,
                  color: color,
                ),
                if (d.status == DeliveryStatus.delivered)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.check_rounded, size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.orderNumber == null ? d.customerName : '${d.customerName} · ${d.orderNumber}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    d.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                  Text(
                    [
                      d.courierName ?? 'Sans livreur',
                      if (d.amountToCollect > 0) 'à encaisser ${moneyShort(d.amountToCollect)}',
                      if (d.status == DeliveryStatus.failed && d.failureReason != null) d.failureReason!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: d.courierName == null ? AppColors.warnText : AppColors.ink),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(9)),
              child: Text(
                d.status.label,
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Nouvelle livraison (à la main) ----------

class NewDeliveryScreen extends ConsumerStatefulWidget {
  const NewDeliveryScreen({super.key});

  @override
  ConsumerState<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

class _NewDeliveryScreenState extends ConsumerState<NewDeliveryScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _note = TextEditingController();
  final _amount = TextEditingController();
  final _fee = TextEditingController();
  Courier? _courier;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _note, _amount, _fee]) {
      c.dispose();
    }
    super.dispose();
  }

  int _int(TextEditingController c) => int.tryParse(c.text.replaceAll(RegExp(r'\D'), '')) ?? 0;

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return showInfo(context, 'Indiquez le client');
    if (_address.text.trim().isEmpty) return showInfo(context, 'Indiquez l’adresse de livraison');
    setState(() => _busy = true);
    try {
      final d = await ref.read(repoProvider).createDelivery({
        'customerName': _name.text.trim(),
        'customerPhone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'address': _address.text.trim(),
        'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'amountToCollect': _int(_amount),
        'fee': _int(_fee),
        'courierId': _courier?.id,
      });
      refreshDeliveries(ref);
      if (_courier != null) {
        final b = await ref.read(currentBusinessProvider.future);
        await ref
            .read(receiptActionsProvider)
            .openWhatsApp(
              whatsAppUri(
                courierMessage(d, business: b.name, city: b.city),
                phone: _courier!.phone,
              ),
            );
      }
      if (!mounted) return;
      showInfo(context, 'Livraison notée');
      context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AuroraScaffold(
    appBar: AppBar(
      title: const Text('Nouvelle livraison', style: TextStyle(fontWeight: FontWeight.w800)),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('dl_name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Client'),
              ),
            ),
            IconButton(
              tooltip: 'Choisir dans mes clients',
              onPressed: () async {
                final c = await pickCustomer(context);
                if (c == null) return;
                setState(() {
                  _name.text = c.name;
                  _phone.text = c.phone ?? '';
                });
              },
              icon: const Icon(Icons.person_search_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('dl_phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Téléphone du client'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('dl_address'),
          controller: _address,
          minLines: 1,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Adresse', hintText: 'Quartier, rue, repère'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('dl_amount'),
                controller: _amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'À encaisser (F)', hintText: '0 si déjà payé'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _fee,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Frais de livraison (F)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _note,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Note pour le livreur (facultatif)'),
        ),
        const SizedBox(height: 14),
        Glass(
          key: const Key('dl_courier'),
          radius: 16,
          onTap: () async {
            final c = await pickCourier(context, ref);
            if (c != null) setState(() => _courier = c);
          },
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(vehicleIcon(_courier?.vehicle ?? 'moto'), color: _orange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _courier?.name ?? 'Choisir le livreur (facultatif)',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _courier == null ? AppColors.muted : AppColors.ink,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 52,
          child: BusyButton(
            icon: _courier == null ? Icons.check_rounded : Icons.send_rounded,
            label: _courier == null ? 'Noter la livraison' : 'Envoyer au livreur',
            busy: _busy,
            onPressed: _save,
          ),
        ),
      ],
    ),
  );
}

// ---------- Livreurs ----------

class CouriersScreen extends ConsumerWidget {
  const CouriersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final couriers = ref.watch(couriersProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Mes livreurs', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_courier'),
        onPressed: () => courierDialog(context, ref),
        icon: const Icon(Icons.person_add_rounded),
        label: const Text('Livreur'),
      ),
      body: AsyncView<List<Courier>>(
        value: couriers,
        onRetry: () => ref.invalidate(couriersProvider),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            if (list.isEmpty)
              Glass(
                radius: 22,
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Ajoutez les livreurs avec qui vous travaillez (moto, voiture…) : vous leur enverrez les courses sur WhatsApp.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
              ),
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Opacity(
                  opacity: c.active ? 1 : 0.55,
                  child: Glass(
                    radius: 18,
                    onTap: () => courierDialog(context, ref, courier: c),
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: _orange.withValues(alpha: 0.14),
                          child: Icon(vehicleIcon(c.vehicle), color: _orange),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                              Text(
                                [vehicleLabels[c.vehicle] ?? 'Moto', ?c.phone, if (!c.active) 'inactif'].join(' · '),
                                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: c.active,
                          onChanged: (v) async {
                            HapticFeedback.selectionClick();
                            try {
                              await ref.read(repoProvider).updateCourier(c.id, {'active': v});
                              ref.invalidate(couriersProvider);
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
