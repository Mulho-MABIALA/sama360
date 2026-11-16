import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
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

  @override
  Widget build(BuildContext context) {
    final sale = ref.watch(saleProvider(widget.saleId));
    final business = ref.watch(currentBusinessProvider);
    final actions = ref.read(receiptActionsProvider);

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Reçu', style: TextStyle(fontWeight: FontWeight.w800)),
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
                      child: ReceiptPaper(sale: s, business: b),
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
                  await actions.sharePdf(await buildReceiptPdf(s, b), receiptFileName(s));
                }),
                onPrint: () => _run('print', () async {
                  await actions.printPdf(await buildReceiptPdf(s, b), s.number);
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
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.whatsapp,
                foregroundColor: const Color(0xFF08361A),
              ),
              onPressed: busy == null ? onWhatsApp : null,
              icon: busy == 'whatsapp' ? spinner(const Color(0xFF08361A)) : const Icon(Icons.chat_rounded),
              label: Text(hasPhone ? 'Envoyer au client par WhatsApp' : 'Envoyer par WhatsApp'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy == null ? onShare : null,
                    icon: busy == 'share' ? spinner(AppColors.green) : const Icon(Icons.ios_share_rounded),
                    label: const Text('Partager le PDF'),
                  ),
                ),
                const SizedBox(width: 10),
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
    const small = TextStyle(fontSize: 12, color: AppColors.muted);
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
      if (b.ninea != null) 'NINEA ${b.ninea}',
    ].where((x) => x.isNotEmpty);

    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                if (l.discount > 0) row('Remise', '−${moneyShort(l.discount)}', style: small),
                const SizedBox(height: 4),
              ],
              const _Dashed(),
              if (s.discount > 0) ...[
                row('Sous-total', moneyShort(s.subtotal)),
                row('Remise', '−${moneyShort(s.discount)}'),
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
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.warnText),
                  ),
                ),
              const _Dashed(),
              const Text(
                'Merci de votre confiance !',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const Text(
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
                    child: const Text(
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
