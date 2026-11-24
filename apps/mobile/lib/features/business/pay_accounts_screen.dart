import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Réglage du patron : ses numéros et liens de paiement mobile, montrés au client à la caisse
/// (QR à scanner ou numéro à composer).
class PayAccountsScreen extends ConsumerStatefulWidget {
  const PayAccountsScreen({super.key});
  @override
  ConsumerState<PayAccountsScreen> createState() => _PayAccountsScreenState();
}

class _PayAccountsScreenState extends ConsumerState<PayAccountsScreen> {
  final _numbers = <PayMethod, TextEditingController>{};
  final _links = <PayMethod, TextEditingController>{};
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _ready = false;

  @override
  void dispose() {
    for (final c in [..._numbers.values, ..._links.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _init(CurrentBusiness b) {
    if (_ready) return;
    _ready = true;
    for (final m in b.country.mobileMoney) {
      final a = b.payAccounts[m];
      _numbers[m] = TextEditingController(text: a?.number ?? '');
      _links[m] = TextEditingController(text: a?.link ?? '');
    }
  }

  Future<void> _save(CurrentBusiness b) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).updatePayAccounts({
        for (final m in b.country.mobileMoney)
          m: PayAccount(number: _numbers[m]!.text.trim(), link: _links[m]!.text.trim()),
      });
      ref.invalidate(currentBusinessProvider);
      if (mounted) {
        showInfo(context, 'Paiements mobiles enregistrés');
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String? _checkNumber(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    return RegExp(r'^\+?[\d ]{6,20}$').hasMatch(t) ? null : 'Numéro invalide';
  }

  static String? _checkLink(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final u = Uri.tryParse(t);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) return 'Collez un lien qui commence par https://';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final business = ref.watch(currentBusinessProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Paiement mobile', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<CurrentBusiness>(
        value: business,
        data: (b) {
          _init(b);
          return Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: AppColors.green, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'À la caisse, quand le client paie par mobile, montrez-lui votre QR ou votre numéro '
                          'avec le montant à payer.\n'
                          'Le lien de paiement se trouve dans votre appli marchande (Wave Business, Orange Money…) : '
                          'copiez-le et collez-le ici.',
                          style: TextStyle(color: AppColors.ink, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                for (final m in b.country.mobileMoney) ...[
                  Glass(
                    radius: 20,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            PayLogo(m, size: 26),
                            const SizedBox(width: 10),
                            Text(m.label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          key: Key('pay_number_${m.api}'),
                          controller: _numbers[m],
                          keyboardType: TextInputType.phone,
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d +]'))],
                          validator: _checkNumber,
                          decoration: InputDecoration(
                            labelText: 'Numéro ${m.label}',
                            hintText: b.country.example,
                            prefixIcon: const Icon(Icons.phone_rounded),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          key: Key('pay_link_${m.api}'),
                          controller: _links[m],
                          keyboardType: TextInputType.url,
                          validator: _checkLink,
                          decoration: const InputDecoration(
                            labelText: 'Lien de paiement (facultatif)',
                            hintText: 'https://…',
                            prefixIcon: Icon(Icons.link_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                BusyButton(
                  key: const Key('pay_accounts_save'),
                  label: 'Enregistrer',
                  busy: _busy,
                  onPressed: () => _save(b),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
