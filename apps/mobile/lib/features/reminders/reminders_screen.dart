import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/privacy.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

enum ReminderStyle {
  gentle('Aimable'),
  firm('Ferme');

  const ReminderStyle(this.label);
  final String label;
}

/// « il y a 3 j », « hier », « aujourd’hui ».
String agoText(DateTime at, DateTime now) {
  final a = DateTime(at.toLocal().year, at.toLocal().month, at.toLocal().day);
  final b = DateTime(now.year, now.month, now.day);
  final d = b.difference(a).inDays;
  if (d <= 0) return 'aujourd’hui';
  if (d == 1) return 'hier';
  return 'il y a $d j';
}

/// Ligne d'état : depuis quand le client doit, ou où en est l'échéance de la facture.
String lateText(ReminderItem i) {
  if (!i.isInvoice) {
    if (i.daysLate <= 0) return 'Crédit du jour';
    return 'Crédit · doit depuis ${i.daysLate} j';
  }
  final n = i.invoiceNumber ?? 'Facture';
  if (i.daysLate > 0) return '$n · en retard de ${i.daysLate} j';
  if (i.daysLate == 0) return '$n · à payer aujourd’hui';
  return '$n · échéance dans ${-i.daysLate} j';
}

/// Message de relance prêt à envoyer par WhatsApp ou SMS.
String reminderMessage(ReminderItem i, String business, {ReminderStyle style = ReminderStyle.gentle}) {
  // Factures : souvent des entreprises, on garde le nom complet
  final name = i.isInvoice ? i.name : firstName(i.name);
  final due = moneyShort(i.amount);
  final day = i.since == null ? null : DateFormat('d MMMM', 'fr').format(i.since!.toLocal());
  if (i.isInvoice) {
    final n = i.invoiceNumber ?? 'votre facture';
    return switch (style) {
      ReminderStyle.gentle =>
        'Bonjour $name, c’est $business. Petit rappel : la facture $n '
            '${day == null ? '' : 'était à régler le $day '}(reste $due). '
            'Vous pouvez payer par Wave, Orange Money ou en boutique. Merci et bonne journée !',
      ReminderStyle.firm =>
        'Bonjour $name, $business vous informe que la facture $n '
            '(reste $due) est en retard${i.daysLate > 0 ? ' de ${i.daysLate} jour${i.daysLate > 1 ? 's' : ''}' : ''}. '
            'Merci de la régler au plus vite.',
    };
  }
  return switch (style) {
    ReminderStyle.gentle =>
      'Bonjour $name, c’est $business. Petit rappel : il vous reste $due à régler. '
          'Vous pouvez payer en boutique, par Wave ou Orange Money. Merci et bonne journée !',
    ReminderStyle.firm =>
      'Bonjour $name, $business vous rappelle que votre solde de $due est en attente'
          '${day == null ? '' : ' depuis le $day'}${i.daysLate > 1 ? ' (${i.daysLate} jours)' : ''}. '
          'Merci de le régler au plus vite.',
  };
}

enum _Tab { due, all, history }

/// Relances : qui doit de l'argent, qui relancer aujourd'hui, et qui a déjà été relancé.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});
  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  _Tab _tab = _Tab.due;

  Future<void> _call(ReminderItem i) async {
    final ok = await ref.read(receiptActionsProvider).openWhatsApp(Uri(scheme: 'tel', path: i.phone));
    if (!ok) {
      if (mounted) showInfo(context, 'Impossible de lancer l’appel');
      return;
    }
    await _record(i, 'call');
  }

  Future<void> _compose(ReminderItem i, String channel) async {
    final business = (await ref.read(currentBusinessProvider.future)).name;
    if (!mounted) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReminderComposer(item: i, business: business, channel: channel),
    );
    if (sent == true) await _record(i, channel);
  }

  Future<void> _record(ReminderItem i, String channel) async {
    try {
      await ref.read(repoProvider).recordReminder(kind: i.kind, id: i.id, channel: channel);
      if (mounted) showInfo(context, 'Rappel noté pour ${i.name}');
    } catch (_) {
      // Le message est parti ; l'enregistrement pourra être refait plus tard.
    }
    ref.invalidate(remindersProvider);
  }

  void _open(ReminderItem i) => context.push(i.isInvoice ? '/invoices/${i.id}' : '/customers/${i.customerId}');

  @override
  Widget build(BuildContext context) {
    final q = ref.watch(remindersProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Relances', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<ReminderQueue>(
        value: q,
        onRetry: () => ref.invalidate(remindersProvider),
        data: (data) {
          final now = DateTime.now();
          final items = _tab == _Tab.due ? data.dueItems : data.items;
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(remindersProvider);
              await ref.read(remindersProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                _Summary(queue: data),
                const SizedBox(height: 14),
                SegmentedButton<_Tab>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: _Tab.due, label: Text('À relancer (${data.dueCount})')),
                    ButtonSegment(value: _Tab.all, label: Text('Tous (${data.items.length})')),
                    const ButtonSegment(value: _Tab.history, label: Text('Historique')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) => setState(() => _tab = s.first),
                ),
                const SizedBox(height: 14),
                if (_tab == _Tab.history)
                  ...(data.history.isEmpty
                      ? [
                          const _Empty(
                            icon: Icons.history_rounded,
                            title: 'Aucun rappel envoyé',
                            text: 'Les rappels envoyés depuis Sama360 s’afficheront ici.',
                          ),
                        ]
                      : [
                          for (final h in data.history)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _LogTile(log: h, now: now),
                            ),
                        ])
                else if (items.isEmpty)
                  _tab == _Tab.due
                      ? const _Empty(
                          icon: Icons.verified_rounded,
                          title: 'Personne à relancer aujourd’hui',
                          text: 'Les clients en retard de paiement apparaîtront ici, au plus une fois par semaine.',
                        )
                      : const _Empty(
                          icon: Icons.savings_rounded,
                          title: 'Aucun impayé',
                          text: 'Ni crédit client, ni facture en attente : tout est encaissé.',
                        )
                else
                  for (final i in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: ReminderTile(
                        item: i,
                        now: now,
                        onOpen: () => _open(i),
                        onWhatsApp: () => _compose(i, 'whatsapp'),
                        onSms: () => _compose(i, 'sms'),
                        onCall: () => _call(i),
                        onAddPhone: () async {
                          await context.push('/customers/${i.customerId}/edit');
                          ref.invalidate(remindersProvider);
                        },
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.queue});
  final ReminderQueue queue;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.all(18),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: const Color(0x1FE5484D), borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.campaign_rounded, color: Color(0xFFE5484D), size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabelWithEye(
                'À relancer aujourd’hui',
                style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              MaskedText(
                moneyShort(queue.dueAmount),
                key: const Key('reminders_due_amount'),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                '${queue.dueCount} relance${queue.dueCount > 1 ? 's' : ''} · '
                '${moneyShort(queue.totalAmount)} d’impayés en tout · '
                '${queue.remindedThisWeek} rappel${queue.remindedThisWeek > 1 ? 's' : ''} cette semaine',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ReminderTile extends StatelessWidget {
  const ReminderTile({
    super.key,
    required this.item,
    required this.now,
    this.onOpen,
    this.onWhatsApp,
    this.onSms,
    this.onCall,
    this.onAddPhone,
  });
  final ReminderItem item;
  final DateTime now;
  final VoidCallback? onOpen;
  final VoidCallback? onWhatsApp;
  final VoidCallback? onSms;
  final VoidCallback? onCall;
  final VoidCallback? onAddPhone;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final color = i.isInvoice ? const Color(0xFF7A5AF8) : const Color(0xFF2F6FDB);
    return Glass(
      radius: 20,
      onTap: onOpen,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(i.isInvoice ? Icons.receipt_long_rounded : Icons.menu_book_rounded, color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(i.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      lateText(i),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: i.daysLate > 0 ? AppColors.danger : AppColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (i.lastRemindedAt != null)
                      Text(
                        'Relancé ${agoText(i.lastRemindedAt!, now)}',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                  ],
                ),
              ),
              Text(
                moneyShort(i.amount),
                style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.warn),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (i.hasPhone)
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.whatsapp,
                      foregroundColor: AppColors.onWhatsapp,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: onWhatsApp,
                    icon: const Icon(Icons.chat_rounded, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Relancer par SMS',
                  onPressed: onSms,
                  icon: const Icon(Icons.sms_rounded),
                ),
                IconButton.filledTonal(
                  tooltip: 'Appeler ${i.name}',
                  onPressed: onCall,
                  icon: const Icon(Icons.call_rounded),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAddPhone,
                icon: const Icon(Icons.add_call, size: 18),
                label: const Text('Pas de numéro : en ajouter un'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Feuille de rédaction : ton du message, texte modifiable, envoi par WhatsApp ou SMS.
class ReminderComposer extends ConsumerStatefulWidget {
  const ReminderComposer({super.key, required this.item, required this.business, required this.channel});
  final ReminderItem item;
  final String business;
  final String channel; // whatsapp, sms
  @override
  ConsumerState<ReminderComposer> createState() => _ReminderComposerState();
}

class _ReminderComposerState extends ConsumerState<ReminderComposer> {
  ReminderStyle _style = ReminderStyle.gentle;
  late final _text = TextEditingController(text: reminderMessage(widget.item, widget.business));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final phone = widget.item.phone!;
    final uri = widget.channel == 'sms'
        ? Uri(scheme: 'sms', path: phone, queryParameters: {'body': _text.text})
        : whatsAppUri(_text.text, phone: phone);
    final ok = await ref.read(receiptActionsProvider).openWhatsApp(uri);
    if (!mounted) return;
    if (!ok) {
      showInfo(context, 'Impossible d’ouvrir l’application');
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.channel == 'sms' ? 'Relance par SMS' : 'Relance WhatsApp',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          Text(
            '${i.name} · ${money(i.amount)}${i.isInvoice ? ' · ${i.invoiceNumber}' : ''}',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final s in ReminderStyle.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: _style == s,
                  onSelected: (_) => setState(() {
                    _style = s;
                    _text.text = reminderMessage(i, widget.business, style: s);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('reminder_text'),
            controller: _text,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              CancelButton(onPressed: () => Navigator.pop(context, false)),
              const SizedBox(width: 10),
              Expanded(
                child: ConfirmButton(label: 'Envoyer', onPressed: _send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log, required this.now});
  final ReminderLog log;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (log.channel) {
      'sms' => (Icons.sms_rounded, 'SMS'),
      'call' => (Icons.call_rounded, 'Appel'),
      _ => (Icons.chat_rounded, 'WhatsApp'),
    };
    return Glass(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: () => context.push(log.invoiceId != null ? '/invoices/${log.invoiceId}' : '/customers/${log.customerId}'),
      child: Row(
        children: [
          Icon(icon, color: AppColors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.invoiceNumber == null ? log.customerName : '${log.customerName} · ${log.invoiceNumber}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '$label${log.byName == null ? '' : ' · par ${firstName(log.byName)}'} · ${agoText(log.at, now)}',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          Text(moneyShort(log.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
    child: Column(
      children: [
        Icon(icon, size: 52, color: AppColors.green),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const SizedBox(height: 6),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted),
        ),
      ],
    ),
  );
}
