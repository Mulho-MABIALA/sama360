import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import 'shop_screen.dart';

/// Message WhatsApp au client selon l'étape de sa commande.
String shopCustomerMessage(ShopOrder o, String shop) {
  final name = firstName(o.customerName);
  final total = moneyShort(o.total);
  return switch (o.status) {
    ShopOrderStatus.newOrder || ShopOrderStatus.confirmed =>
      'Bonjour $name, ici $shop. Votre commande ${o.number} est bien confirmée ($total). '
          '${o.delivery ? 'Nous vous appelons avant de livrer.' : 'Nous vous prévenons dès qu’elle est prête.'}',
    ShopOrderStatus.ready =>
      o.delivery
          ? 'Bonjour $name, votre commande ${o.number} est prête : elle part bientôt en livraison.'
          : 'Bonjour $name, votre commande ${o.number} est prête : vous pouvez passer la récupérer ($total).',
    ShopOrderStatus.delivering =>
      'Bonjour $name, votre commande ${o.number} est en route. Montant à payer : $total. À tout de suite !',
    ShopOrderStatus.completed => 'Merci $name pour votre commande ${o.number} ! À très bientôt chez $shop.',
    ShopOrderStatus.cancelled =>
      'Bonjour $name, votre commande ${o.number} a été annulée. N’hésitez pas à nous écrire.',
  };
}

String _stepLabel(ShopOrderStatus s, bool delivery) => switch (s) {
  ShopOrderStatus.confirmed => 'Confirmer la commande',
  ShopOrderStatus.ready => 'Commande prête',
  ShopOrderStatus.delivering => 'Partie en livraison',
  ShopOrderStatus.completed => delivery ? 'Livrée et encaissée' : 'Retirée et encaissée',
  _ => s.label,
};

/// Une commande reçue sur la boutique : client, articles, étapes jusqu'à la vente.
class ShopOrderScreen extends ConsumerStatefulWidget {
  const ShopOrderScreen({super.key, required this.orderId});
  final String orderId;
  @override
  ConsumerState<ShopOrderScreen> createState() => _ShopOrderScreenState();
}

class _ShopOrderScreenState extends ConsumerState<ShopOrderScreen> {
  bool _busy = false;

  Future<void> _move(ShopOrder o, ShopOrderStatus to) async {
    ({int amount, PayMethod method})? payment;
    String? reason;
    if (to == ShopOrderStatus.completed) {
      payment = await showModalBottomSheet<({int amount, PayMethod method})>(
        useRootNavigator: true,
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _CollectSheet(order: o),
      );
      if (payment == null) return;
    }
    if (to == ShopOrderStatus.cancelled) {
      reason = await _askReason();
      if (reason == null) return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).setShopOrderStatus(o.id, to, reason: reason, payment: payment);
      refreshShop(ref);
      if (to == ShopOrderStatus.completed) refreshBusinessData(ref);
      if (mounted) {
        showInfo(context, switch (to) {
          ShopOrderStatus.completed => 'Vente enregistrée : stock et caisse à jour',
          ShopOrderStatus.cancelled => 'Commande annulée',
          _ => 'Commande « ${to.label.toLowerCase()} »',
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askReason() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Annuler la commande ?'),
        content: TextField(
          key: const Key('cancelReason'),
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Raison', hintText: 'Ex. produit épuisé, client injoignable'),
        ),
        actions: [
          CancelButton(label: 'Retour', onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(
            danger: true,
            label: 'Oui, annuler',
            onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? 'Annulée par la boutique' : c.text.trim()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(shopOrderProvider(widget.orderId));
    final canAct = ref.watch(canProvider('sales:create'));
    final o = order.value;
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(o?.number ?? 'Commande', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<ShopOrder>(
        value: order,
        onRetry: () => ref.invalidate(shopOrderProvider(widget.orderId)),
        data: (o) => Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => ref.invalidate(shopOrderProvider(widget.orderId)),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    _Customer(o: o),
                    const SizedBox(height: 12),
                    _Progress(o: o),
                    const SizedBox(height: 12),
                    Card(
                      child: Column(
                        children: [
                          for (final l in o.lines)
                            ListTile(
                              leading: ProductThumb(name: l.name, fileId: l.imageFileId, size: 42),
                              title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                              subtitle: Text(
                                '${qty(l.quantity)} × ${moneyShort(l.unitPrice)}',
                                style: const TextStyle(fontSize: 12.5),
                              ),
                              trailing: Text(moneyShort(l.total), style: const TextStyle(fontWeight: FontWeight.w800)),
                            ),
                          const Divider(height: 1, indent: 14, endIndent: 14),
                          if (o.deliveryFee > 0)
                            ListTile(
                              dense: true,
                              title: const Text('Livraison'),
                              trailing: Text(
                                moneyShort(o.deliveryFee),
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ListTile(
                            title: const Text('Total à encaisser', style: TextStyle(fontWeight: FontWeight.w800)),
                            trailing: Text(
                              money(o.total),
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if ((o.note ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Glass(
                        radius: 18,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(Icons.sticky_note_2_outlined, size: 20, color: AppColors.muted),
                            const SizedBox(width: 10),
                            Expanded(child: Text(o.note!, style: const TextStyle(fontSize: 13.5))),
                          ],
                        ),
                      ),
                    ],
                    if (o.status == ShopOrderStatus.cancelled && o.cancelReason != null) ...[
                      const SizedBox(height: 10),
                      Text('Annulée : ${o.cancelReason}', style: TextStyle(color: AppColors.muted)),
                    ],
                    if (o.saleId != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () => context.push('/sales/${o.saleId}'),
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: const Text('Voir la vente et le reçu'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (canAct && !o.status.done)
              Padding(
                padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                child: Glass(
                  radius: 28,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final next in o.nextSteps)
                        BusyButton(label: _stepLabel(next, o.delivery), busy: _busy, onPressed: () => _move(o, next)),
                      // Une commande confirmée peut aussi être remise directement (client passé en boutique)
                      if (o.status == ShopOrderStatus.confirmed || (o.status == ShopOrderStatus.ready && o.delivery))
                        TextButton(
                          onPressed: _busy ? null : () => _move(o, ShopOrderStatus.completed),
                          child: Text(o.delivery ? 'Déjà livrée et encaissée' : 'Déjà retirée et encaissée'),
                        ),
                      ConfirmButton(
                        danger: true,
                        label: 'Annuler la commande',
                        onPressed: _busy ? null : () => _move(o, ShopOrderStatus.cancelled),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Customer extends ConsumerWidget {
  const _Customer({required this.o});
  final ShopOrder o;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ref.read(receiptActionsProvider);
    final shop = shopDisplayName(ref.watch(shopProvider).value?.settings, ref.watch(shopBusinessNameProvider));
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(name: o.customerName, size: 46, bg: AppColors.greenSoft, fg: AppColors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.customerName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    Text(intlPhone(o.customerPhone), style: TextStyle(color: AppColors.muted)),
                  ],
                ),
              ),
              ShopStatusChip(status: o.status),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                o.delivery ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
                size: 20,
                color: AppColors.green,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  o.delivery ? 'Livraison : ${o.address ?? ''}' : 'Retrait en boutique',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          Text('Commandée le ${dateTime(o.createdAt)}', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => actions.openWhatsApp(Uri(scheme: 'tel', path: o.customerPhone)),
                icon: const Icon(Icons.call_rounded, size: 18),
                label: const Text('Appeler'),
              ),
              TextButton.icon(
                onPressed: () =>
                    actions.openWhatsApp(whatsAppUri(shopCustomerMessage(o, shop), phone: o.customerPhone)),
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: const Text('WhatsApp'),
              ),
              if (o.contactId != null)
                TextButton.icon(
                  onPressed: () => context.push('/customers/${o.contactId}'),
                  icon: const Icon(Icons.person_outline_rounded, size: 18),
                  label: const Text('Fiche'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.o});
  final ShopOrder o;

  @override
  Widget build(BuildContext context) {
    if (o.status == ShopOrderStatus.cancelled) return const SizedBox.shrink();
    final steps = [
      ShopOrderStatus.newOrder,
      ShopOrderStatus.confirmed,
      ShopOrderStatus.ready,
      if (o.delivery) ShopOrderStatus.delivering,
      ShopOrderStatus.completed,
    ];
    final at = steps.indexOf(o.status);
    return Glass(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Row(
        children: [
          for (final (i, s) in steps.indexed)
            Expanded(
              child: Column(
                children: [
                  Icon(
                    i <= at ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                    color: i <= at ? AppColors.green : AppColors.line,
                    size: 22,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s == ShopOrderStatus.newOrder ? 'Reçue' : s.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: i == at ? FontWeight.w800 : FontWeight.w500,
                      color: i <= at ? AppColors.ink : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Encaissement à la livraison : montant reçu (tout par défaut) et moyen de paiement.
class _CollectSheet extends StatefulWidget {
  const _CollectSheet({required this.order});
  final ShopOrder order;
  @override
  State<_CollectSheet> createState() => _CollectSheetState();
}

class _CollectSheetState extends State<_CollectSheet> {
  late final _amount = TextEditingController(text: '${widget.order.total}');
  PayMethod _method = PayMethod.cash;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _value => int.tryParse(_amount.text) ?? 0;

  @override
  Widget build(BuildContext context) {
    final rest = widget.order.total - _value;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Encaisser la commande', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text('Total : ${money(widget.order.total)}', style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 14),
          TextField(
            key: const Key('collectAmount'),
            controller: _amount,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Montant reçu', suffixText: 'FCFA'),
            onChanged: (_) => setState(() {}),
          ),
          if (rest > 0 && _value >= 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Le reste (${money(rest)}) va au carnet de crédit de ${firstName(widget.order.customerName)}',
                style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in const [PayMethod.cash, PayMethod.wave, PayMethod.orangeMoney, PayMethod.freeMoney])
                Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: () {
              if (_value > widget.order.total) {
                showInfo(context, 'Le montant dépasse le total');
                return;
              }
              Navigator.pop(context, (amount: _value, method: _method));
            },
            child: const Text('Enregistrer la vente'),
          ),
        ],
      ),
    );
  }
}
