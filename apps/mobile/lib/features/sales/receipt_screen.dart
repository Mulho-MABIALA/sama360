import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../business/business_logo.dart';
import 'receipt.dart';

/// Actions de partage (remplaçables dans les tests).
class ReceiptActions {
  const ReceiptActions();

  Future<bool> openWhatsApp(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
  Future<void> sharePdf(List<int> bytes, String filename) =>
      Printing.sharePdf(bytes: Uint8List.fromList(bytes), filename: filename);
  Future<void> printPdf(List<int> bytes, String name, {PdfPageFormat format = PdfPageFormat.roll80}) =>
      Printing.layoutPdf(name: name, format: format, onLayout: (_) async => Uint8List.fromList(bytes));
}

final receiptActionsProvider = Provider<ReceiptActions>((ref) => const ReceiptActions());

/// Lien WhatsApp : directement au client si on a son numéro, sinon choix du contact.
Uri whatsAppUri(String text, {String? phone}) {
  final number = phone?.replaceAll(RegExp(r'\D'), '');
  return Uri.parse('https://wa.me/${number ?? ''}?text=${Uri.encodeComponent(text)}');
}

class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, required this.saleId});
  final String saleId;
  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  String? _busy; // action en cours

  Future<void> _run(String action, Future<void> Function() task) async {
    setState(() => _busy = action);
    try {
      await task();
    } catch (e) {
      if (mounted) showError(context, e is Exception ? 'Action impossible : ${e.toString()}' : e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Annuler la vente : motif, puis code secret (ou empreinte).
  Future<void> _void(SaleDetail s) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Annuler la vente ${s.number} ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Les articles reviennent en stock et la vente reste visible, marquée « Annulée ». '
              'Pensez à rendre l’argent au client.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('voidReason'),
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Motif', hintText: 'Ex. erreur de saisie, client a rendu'),
            ),
          ],
        ),
        actions: dialogActions([
          CancelButton(label: 'Retour', onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(
            danger: true,
            label: 'Oui, annuler',
            onPressed: () {
              if (reason.text.trim().length < 3) return;
              Navigator.pop(ctx, true);
            },
          ),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Annuler la vente ${s.number} (${money(s.total)})')) return;
    await _run('void', () async {
      await ref.read(repoProvider).voidSale(s.id, reason.text.trim());
      ref.invalidate(saleProvider(s.id));
      refreshBusinessData(ref);
      if (mounted) showInfo(context, 'Vente annulée');
    });
  }

  /// PDF ticket avec le logo de l'entreprise s'il est disponible.
  Future<List<int>> _pdf(SaleDetail s, CurrentBusiness b) async {
    final logo = b.logoFileId == null ? null : await ref.read(repoProvider).fileBytes(b.logoFileId!);
    return buildReceiptPdf(s, b, logo: logo);
  }

  @override
  Widget build(BuildContext context) {
    final sale = ref.watch(saleProvider(widget.saleId));
    final business = ref.watch(currentBusinessProvider);
    final actions = ref.read(receiptActionsProvider);

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Reçu', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (ref.can('sales:void') && sale.value != null && !sale.value!.voided)
            IconButton(
              tooltip: 'Annuler la vente',
              onPressed: _busy == null ? () => _void(sale.value!) : null,
              icon: const Icon(Icons.block_rounded),
            ),
        ],
      ),
      body: AsyncView<SaleDetail>(
        value: sale,
        onRetry: () => ref.invalidate(saleProvider(widget.saleId)),
        data: (s) => AsyncView<CurrentBusiness>(
          value: business,
          onRetry: () => ref.invalidate(currentBusinessProvider),
          data: (b) => Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ReceiptPaper(sale: s, business: b),
                          const AddLogoHint(
                            key: Key('receipt_add_logo'),
                            message: 'Il apparaîtra en haut de vos reçus (écran, PDF et impression).',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _ActionsBar(
                busy: _busy,
                hasPhone: s.customer?.phone != null,
                onWhatsApp: () => _run('whatsapp', () async {
                  final ok = await actions.openWhatsApp(whatsAppUri(receiptText(s, b), phone: s.customer?.phone));
                  if (!ok && context.mounted) showInfo(context, 'WhatsApp n’a pas pu être ouvert');
                }),
                onShare: () => _run('share', () async {
                  await actions.sharePdf(await _pdf(s, b), receiptFileName(s));
                }),
                onPrint: () => _run('print', () async {
                  await actions.printPdf(await _pdf(s, b), s.number);
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsBar extends StatelessWidget {
  const _ActionsBar({
    required this.busy,
    required this.hasPhone,
    required this.onWhatsApp,
    required this.onShare,
    required this.onPrint,
  });
  final String? busy;
  final bool hasPhone;
  final VoidCallback onWhatsApp;
  final VoidCallback onShare;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    Widget spinner(Color c) =>
        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: c));
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Le reçu en PDF : on choisit WhatsApp puis le contact (pas besoin du numéro du client)
            FilledButton.icon(
              key: const Key('receipt_send_pdf'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.whatsapp, foregroundColor: AppColors.onWhatsapp),
              onPressed: busy == null ? onShare : null,
              icon: busy == 'share' ? spinner(AppColors.onWhatsapp) : const Icon(Icons.send_rounded),
              label: const Text('Envoyer le reçu (PDF)'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                // Client enregistré avec son numéro : message WhatsApp direct, en plus du PDF
                if (hasPhone) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('receipt_whatsapp_text'),
                      onPressed: busy == null ? onWhatsApp : null,
                      icon: busy == 'whatsapp' ? spinner(AppColors.green) : const Icon(Icons.chat_rounded),
                      label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Message au client')),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy == null ? onPrint : null,
                    icon: busy == 'print' ? spinner(AppColors.green) : const Icon(Icons.print_rounded),
                    label: const Text('Imprimer'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Ticket de caisse à l'écran (même contenu que le PDF).
class ReceiptPaper extends StatelessWidget {
  const ReceiptPaper({super.key, required this.sale, required this.business});
  final SaleDetail sale;
  final CurrentBusiness business;

  @override
  Widget build(BuildContext context) {
    final s = sale;
    final b = business;
    final small = TextStyle(fontSize: 12, color: AppColors.muted);
    Widget row(String l, String r, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(l, style: style)),
          const SizedBox(width: 8),
          Text(r, style: style),
        ],
      ),
    );

    final contact = [
      [b.address, b.city].whereType<String>().where((x) => x.isNotEmpty).join(', '),
      if (b.phone != null) 'Tél. ${b.phone}',
      if (b.ninea != null) '${b.country.taxIdLabel} ${b.ninea}',
    ].where((x) => x.isNotEmpty);

    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (b.logoFileId != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Center(child: BusinessLogo(business: b, size: 54, radius: 12)),
                ),
              Text(
                b.name,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              for (final c in contact) Text(c, textAlign: TextAlign.center, style: small),
              const _Dashed(),
              Text(
                'REÇU ${s.number}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(receiptDate(s.soldAt), textAlign: TextAlign.center, style: small),
              const SizedBox(height: 8),
              if (s.cashierName != null) row('Vendeur', s.cashierName!, style: small),
              if (s.customer != null) row('Client', s.customer!.name, style: small),
              const _Dashed(),
              for (final l in s.lines) ...[
                Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                row(lineDetail(l), moneyShort(l.total), style: const TextStyle(fontSize: 13)),
                if (l.discount > 0) row('Réduction', '−${moneyShort(l.discount)}', style: small),
                for (final t in serialLines(l)) Text(t, style: small),
                const SizedBox(height: 4),
              ],
              const _Dashed(),
              if (s.discount > 0) ...[
                row('Sous-total', moneyShort(s.subtotal)),
                row('Réduction', '−${moneyShort(s.discount)}'),
              ],
              row('TOTAL', moneyShort(s.total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              for (final p in s.payments) row('Payé (${paymentLabel(p.method)})', moneyShort(p.amount)),
              if (s.due > 0)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: AppColors.warnBg, borderRadius: BorderRadius.circular(8)),
                  child: row(
                    'Reste à payer',
                    moneyShort(s.due),
                    style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.warnText),
                  ),
                ),
              if (loyaltyLine(s.loyalty) != null)
                Container(
                  key: const Key('receipt_loyalty'),
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.softOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.stars_rounded,
                        size: 18,
                        color: AppColors.strongOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00)),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          loyaltyLine(s.loyalty)!,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              const _Dashed(),
              const Text(
                'Merci de votre confiance !',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                'Reçu émis avec Sama360',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
          ),
        ),
        if (s.voided)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Transform.rotate(
                  angle: -0.35,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.danger, width: 3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'VENTE ANNULÉE',
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Dashed extends StatelessWidget {
  const _Dashed();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: LayoutBuilder(
      builder: (_, c) {
        final count = (c.maxWidth / 8).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(count, (_) => Container(width: 4, height: 1.2, color: AppColors.line)),
        );
      },
    ),
  );
}
