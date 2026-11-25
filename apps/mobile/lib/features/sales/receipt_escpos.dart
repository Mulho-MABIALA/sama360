import '../../core/models.dart';
import '../../core/thermal/escpos.dart';
import 'receipt.dart';

/// Reçu pour imprimante thermique Bluetooth (ESC/POS), même contenu que le reçu PDF.
/// [width] : 32 caractères (rouleau 58 mm) ou 48 (80 mm).
List<int> receiptEscPos(SaleDetail s, CurrentBusiness b, {int width = 32}) {
  final p = EscPos(width: width);
  p.text(b.name, bold: true, center: true, big: true);
  for (final line in [
    [b.address, b.city].whereType<String>().where((x) => x.isNotEmpty).join(', '),
    if (b.phone != null) 'Tél. ${b.phone}',
    if (b.ninea != null) '${b.country.taxIdLabel} ${b.ninea}',
  ].where((x) => x.isNotEmpty)) {
    p.text(line, center: true);
  }
  p.dashes();
  p.text('REÇU ${s.number}', bold: true, center: true);
  p.text(receiptDate(s.soldAt), center: true);
  if (s.voided) p.text('*** VENTE ANNULÉE ***', bold: true, center: true);
  if (s.cashierName != null) p.row('Vendeur', s.cashierName!);
  if (s.customer != null) p.row('Client', s.customer!.name);
  p.dashes();
  for (final l in s.lines) {
    p.text(l.name, bold: true);
    p.row(lineDetail(l), receiptMoney(l.total));
    if (l.discount > 0) p.row('  Remise', '-${receiptMoney(l.discount)}');
    for (final t in serialLines(l)) {
      p.text('  $t');
    }
  }
  p.dashes();
  if (s.discount > 0) {
    p.row('Sous-total', receiptMoney(s.subtotal));
    p.row('Remise', '-${receiptMoney(s.discount)}');
  }
  p.row('TOTAL', receiptMoney(s.total), bold: true, big: true);
  for (final pay in s.payments) {
    p.row('Payé (${paymentLabel(pay.method)})', receiptMoney(pay.amount));
  }
  if (s.due > 0) p.row('Reste à payer', receiptMoney(s.due), bold: true);
  final pts = loyaltyLine(s.loyalty);
  if (pts != null) p.text('Fidélité : $pts');
  p.dashes();
  p.text('Merci de votre confiance !', bold: true, center: true);
  if (!b.isPro) p.text('Reçu émis avec Sama360', center: true);
  p.cut();
  return p.bytes;
}
