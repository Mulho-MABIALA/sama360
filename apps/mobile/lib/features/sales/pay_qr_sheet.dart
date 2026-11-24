import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/widgets.dart';

/// Numéro de paiement lisible (« 77 123 45 67 »), qu'il soit saisi avec ou sans indicatif.
String payNumberDisplay(String number, Country country) {
  final e164 = number.startsWith('+') ? number : localPhone(number, country);
  return e164 == null ? number : displayPhone(e164);
}

/// À la caisse : écran tourné vers le client, avec le montant, le QR du lien de paiement
/// du commerçant (ou son numéro). Renvoie true quand le vendeur confirme avoir reçu l'argent.
Future<bool> showPayQr(
  BuildContext context, {
  required String businessName,
  required Country country,
  required PayMethod method,
  required PayAccount account,
  required int amount,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: true, // au-dessus de la barre de navigation flottante
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (ctx) =>
        _PayQr(businessName: businessName, country: country, method: method, account: account, amount: amount),
  );
  return ok == true;
}

class _PayQr extends StatelessWidget {
  const _PayQr({
    required this.businessName,
    required this.country,
    required this.method,
    required this.account,
    required this.amount,
  });
  final String businessName;
  final Country country;
  final PayMethod method;
  final PayAccount account;
  final int amount;

  @override
  Widget build(BuildContext context) {
    final link = (account.link ?? '').isEmpty ? null : account.link!;
    final number = (account.number ?? '').isEmpty ? null : payNumberDisplay(account.number!, country);
    // Toujours sur fond blanc, texte sombre : lisible et scannable même en mode sombre
    const ink = Color(0xFF10231B);
    const muted = Color(0xFF4B5F56);
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.light),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: const Color(0xFFD5DDD9), borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PayLogo(method, size: 30),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Payez par ${method.label}',
                    style: const TextStyle(color: ink, fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              businessName,
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 14),
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                money(amount),
                key: const Key('pay_qr_amount'),
                style: const TextStyle(color: ink, fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: -1),
              ),
            ),
            const SizedBox(height: 14),
            if (link != null) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFE2E8E5), width: 2),
                  ),
                  child: Semantics(
                    label: 'QR de paiement ${method.label}',
                    child: QrImageView(
                      key: const Key('pay_qr_code'),
                      data: link,
                      size: 210,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: ink),
                      dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Scannez avec l’appli ${method.label}, puis payez ${money(amount)}.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted, fontSize: 14),
              ),
            ],
            if (number != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
                decoration: BoxDecoration(color: const Color(0xFFF1F5F3), borderRadius: BorderRadius.circular(18)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            link == null ? 'Envoyez le montant au' : 'Ou envoyez au',
                            style: const TextStyle(color: muted, fontSize: 13),
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              number,
                              key: const Key('pay_qr_number'),
                              style: const TextStyle(color: ink, fontSize: 28, fontWeight: FontWeight.w900),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copier le numéro',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: account.number!.replaceAll(' ', '')));
                        showInfo(context, 'Numéro copié');
                      },
                      icon: const Icon(Icons.copy_rounded, color: ink),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('pay_qr_received'),
              style: accentButtonStyle().copyWith(minimumSize: const WidgetStatePropertyAll(Size.fromHeight(54))),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.check_circle_rounded),
              label: const Text('J’ai reçu l’argent : encaisser'),
            ),
            const SizedBox(height: 6),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: ink, minimumSize: const Size.fromHeight(46)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le moyen de paiement choisi a-t-il un compte à montrer au client ?
PayAccount? payAccountFor(CurrentBusiness? b, PayMethod? m) {
  if (b == null || m == null || m == PayMethod.cash) return null;
  final a = b.payAccounts[m];
  return a == null || a.isEmpty ? null : a;
}

/// Petit rappel pour le patron : ajouter son numéro pour le montrer au client.
bool canSetupPayAccount(CurrentBusiness? b, PayMethod? m) =>
    b != null && m != null && m != PayMethod.cash && b.country.mobileMoney.contains(m);

/// Lien vers le réglage.
const payAccountsRoute = '/business/pay-accounts';
