import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/celebrate.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_controller.dart' show authProvider;
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

final _day = DateFormat('d MMMM yyyy', 'fr');

/// Dégradé de l'en-tête Pro : ambre foncé, pour un texte blanc lisible (contraste ≥ 4,5:1).
const proGold = [Color(0xFFB45309), Color(0xFF9A3412)];
const _gold = proGold;

/// Texte du badge « PRO » sur fond blanc.
const proBadgeText = Color(0xFF9A3412);

/// Ce qui reste gratuit, pour rassurer.
const freeFeatures = 'Ventes, caisse, stock, clients et crédits, dépenses, factures, rapports simples';

/// Message de parrainage envoyé sur WhatsApp.
String referralMessage({required String business, required String code, required String link, int days = 30}) =>
    'Salut ! Je gère $business avec Sama360 : ventes, stock, crédits clients, boutique en ligne… '
    'Inscris-toi avec mon code *$code* : on gagne chacun ${days == 30 ? '1 mois' : '$days jours'} de Sama360 Pro.\n'
    '👉 $link';

/// Lien d'inscription avec le code (version web servie par l'API).
String referralLink(String apiBase, String code) =>
    '${apiBase.replaceAll(RegExp(r'/+$'), '')}/app/?ref=${Uri.encodeComponent(code)}';

String proHeadline(ProStatus s) => switch (s.state) {
  ProState.trial => 'Essai Pro offert · ${_daysText(s.daysLeft)}',
  ProState.active => 'Pro actif jusqu’au ${_day.format(s.endsAt!.toLocal())}',
  ProState.expired => 'Votre Sama360 Pro est terminé',
  ProState.free => 'Vous êtes sur l’offre gratuite',
};

/// Ouvre la page de paiement. Sur le web, dans le même onglet : Chariow ramène ensuite dans l'app.
final checkoutLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(
        uri,
        mode: kIsWeb ? LaunchMode.platformDefault : LaunchMode.externalApplication,
        webOnlyWindowName: kIsWeb ? '_self' : null,
      ),
);

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String _daysText(int d) => d <= 1 ? 'dernier jour' : '$d jours restants';

// ───────────────────────────────────────────────────────────── Offre Pro

class ProScreen extends ConsumerStatefulWidget {
  const ProScreen({super.key, this.feature, this.paidId});

  /// Fonction qui a amené ici (tuile verrouillée, erreur PRO_REQUIRED).
  final ProFeature? feature;

  /// Retour de la page de paiement en ligne : paiement à suivre.
  final String? paidId;

  @override
  ConsumerState<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends ConsumerState<ProScreen> with WidgetsBindingObserver {
  String _cycle = 'monthly';
  PayMethod? _method;
  final _ref = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  bool _busy = false;
  bool _onlineBusy = false;
  String? _error;
  String? _onlineError;

  /// Paiement en ligne suivi (ouvert ici, ou retour de la page de paiement)
  String? _waitingId;
  bool _paid = false;
  Timer? _poll;
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _email.text = ref.read(authProvider).value?.me?.email ?? '';
    if (widget.paidId != null) _watch(widget.paidId!);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _ref.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  /// Retour dans l'app après le paiement (téléphone) : on regarde tout de suite.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingId != null && !_paid) _check();
  }

  void _watch(String id) {
    _poll?.cancel();
    _tries = 0;
    setState(() => _waitingId = id);
    _check();
    // Chariow prévient le serveur en quelques secondes ; on regarde pendant 3 minutes
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (++_tries > 45) {
        _poll?.cancel();
      } else {
        _check();
      }
    });
  }

  Future<void> _check() async {
    final id = _waitingId;
    if (id == null || _paid) return;
    try {
      final p = await ref.read(repoProvider).onlinePayment(id);
      if (!mounted || !p.paid) return;
      _poll?.cancel();
      setState(() => _paid = true);
      ref.invalidate(subscriptionProvider);
      ref.invalidate(currentBusinessProvider);
    } catch (_) {
      // Réseau : on réessaie au prochain tour
    }
  }

  Future<void> _payOnline() async {
    final email = _email.text.trim();
    if (!_emailRe.hasMatch(email)) {
      setState(() => _onlineError = 'Entrez une adresse e-mail valide : Chariow y envoie votre reçu');
      return;
    }
    setState(() {
      _onlineBusy = true;
      _onlineError = null;
    });
    try {
      final p = await ref.read(repoProvider).startProCheckout(cycle: _cycle, email: email);
      if (!mounted) return;
      _watch(p.id);
      final opened = await ref.read(checkoutLauncherProvider)(Uri.parse(p.checkoutUrl!));
      if (!opened && mounted) setState(() => _onlineError = 'La page de paiement ne s’est pas ouverte. Réessayez.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _onlineBusy = false);
    }
  }

  Future<void> _submit(ProStatus s) async {
    final method = _method ?? (s.methods.isEmpty ? PayMethod.wave : s.methods.first);
    final reference = _ref.text.trim();
    if (reference.length < 4) {
      setState(() => _error = 'Recopiez la référence de la transaction (dans le SMS de confirmation)');
      return;
    }
    String? phone;
    if (_phone.text.trim().isNotEmpty) {
      phone = localPhone(_phone.text, ref.read(countryProvider));
      if (phone == null) {
        setState(() => _error = invalidPhone(ref.read(countryProvider)));
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(repoProvider)
          .requestProPayment(cycle: _cycle, method: method, reference: reference, payerPhone: phone);
      ref.invalidate(subscriptionProvider);
      _ref.clear();
      if (mounted) showInfo(context, 'Merci ! Nous vérifions votre paiement.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = ref.watch(subscriptionProvider);
    final canPay = ref.can('business:update');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Sama360 Pro', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<ProStatus>(
        value: sub,
        onRetry: () => ref.invalidate(subscriptionProvider),
        data: (s) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(subscriptionProvider);
            ref.invalidate(currentBusinessProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              _Hero(status: s, feature: widget.feature),
              const SizedBox(height: 14),
              Glass(
                radius: 22,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Avec Pro', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 6),
                    for (final f in ProFeature.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 20,
                              color: f == widget.feature ? const Color(0xFFFF7A00) : AppColors.green,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                f.label,
                                style: TextStyle(fontWeight: f == widget.feature ? FontWeight.w800 : FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 18),
                    Text('Toujours gratuit : $freeFeatures.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _PriceCard(
                      key: const Key('cycle_monthly'),
                      title: 'Mensuel',
                      price: moneyShort(s.monthly),
                      sub: 'par mois',
                      selected: _cycle == 'monthly',
                      onTap: () => setState(() => _cycle = 'monthly'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PriceCard(
                      key: const Key('cycle_yearly'),
                      title: 'Annuel',
                      price: moneyShort(s.yearly),
                      sub: '2 mois offerts',
                      selected: _cycle == 'yearly',
                      onTap: () => setState(() => _cycle = 'yearly'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_paid) const _OnlineDone() else if (_waitingId != null) _OnlineWaiting(onCheck: _check),
              if (_paid || _waitingId != null) const SizedBox(height: 14),
              if (s.pending != null)
                _Pending(request: s.pending!)
              else if (!canPay)
                Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Seul le propriétaire peut payer l’abonnement. Demandez-lui de passer à Pro.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              else if (s.online) ...[
                if (!_paid) _onlineForm(s),
                const SizedBox(height: 10),
                Glass(
                  radius: 22,
                  padding: EdgeInsets.zero,
                  child: Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const Key('pay_manual'),
                      shape: const RoundedRectangleBorder(),
                      collapsedShape: const RoundedRectangleBorder(),
                      title: const Text('Déjà payé par transfert ?', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: const Text('Envoyez la référence de la transaction', style: TextStyle(fontSize: 12.5)),
                      childrenPadding: EdgeInsets.zero,
                      children: [_payForm(s, framed: false)],
                    ),
                  ),
                ),
              ] else
                _payForm(s),
              const SizedBox(height: 14),
              Glass(
                key: const Key('open_referral'),
                radius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                onTap: () => context.push('/referral'),
                child: Row(
                  children: [
                    const Icon(Icons.card_giftcard_rounded, color: Color(0xFFDB2777)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Des mois gratuits', style: TextStyle(fontWeight: FontWeight.w800)),
                          Text('Invitez un commerçant : 1 mois Pro offert à chacun', style: TextStyle(fontSize: 12.5)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _onlineForm(ProStatus s) {
    final amount = moneyShort(_cycle == 'yearly' ? s.yearly : s.monthly);
    return Glass(
      key: const Key('pay_online_card'),
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Payer en ligne', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            'Wave, Orange Money, MoMo ou carte bancaire. Pro s’active tout seul dès que le paiement passe.',
            style: TextStyle(color: AppColors.muted, fontSize: 13.5),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pay_email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'E-mail pour le reçu', hintText: 'ex. awa@gmail.com'),
          ),
          if (_onlineError != null) ...[
            const SizedBox(height: 8),
            Text(_onlineError!, style: TextStyle(color: AppColors.danger, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: BusyButton(
              key: const Key('pay_online'),
              label: 'Payer $amount',
              busy: _onlineBusy,
              onPressed: _payOnline,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_rounded, size: 14, color: AppColors.muted),
              const SizedBox(width: 4),
              Text('Paiement sécurisé par Chariow', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _payForm(ProStatus s, {bool framed = true}) {
    final method = _method ?? (s.methods.isEmpty ? PayMethod.wave : s.methods.first);
    final amount = moneyShort(_cycle == 'yearly' ? s.yearly : s.monthly);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Payer', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        if (s.lastRejected != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.warnBg, borderRadius: BorderRadius.circular(12)),
            child: Text(
              'Paiement « ${s.lastRejected!.reference} » non retrouvé'
              '${s.lastRejected!.note == null ? '' : ' : ${s.lastRejected!.note}'}',
              style: TextStyle(color: AppColors.warnText, fontSize: 13),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _Step(
          n: 1,
          text: s.payTo == null
              ? 'Envoyez $amount par ${s.methods.map((m) => m.label).join(', ')}. '
                    'Le numéro vous est donné par l’équipe Sama360.'
              : 'Envoyez $amount à : ${s.payTo}',
        ),
        const _Step(n: 2, text: 'Gardez la référence de la transaction, reçue par SMS.'),
        const _Step(n: 3, text: 'Remplissez ci-dessous : nous activons Pro dès que le paiement est vérifié.'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in s.methods)
              Pill(label: m.label, selected: method == m, onTap: () => setState(() => _method = m)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('pay_ref'),
          controller: _ref,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Référence de la transaction', hintText: 'ex. TX12AB34CD'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('pay_phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Numéro qui a payé (facultatif)',
            prefixText: '+${ref.watch(countryProvider).dial} ',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: AppColors.danger, fontSize: 13)),
        ],
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: BusyButton(
            key: const Key('pay_submit'),
            label: 'J’ai payé $amount',
            busy: _busy,
            onPressed: () => _submit(s),
          ),
        ),
      ],
    );
    return framed
        ? Glass(radius: 22, padding: const EdgeInsets.all(16), child: body)
        : Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: body);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.status, this.feature});
  final ProStatus status;
  final ProFeature? feature;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: _gold, begin: Alignment.topLeft, end: Alignment.bottomRight),
      borderRadius: BorderRadius.circular(24),
      boxShadow: [
        BoxShadow(color: proGold.last.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10)),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
              child: const Text(
                'PRO',
                style: TextStyle(color: proBadgeText, fontWeight: FontWeight.w900, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Sama360',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          proHeadline(status),
          key: const Key('pro_headline'),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20, height: 1.2),
        ),
        const SizedBox(height: 6),
        Text(
          feature != null && !status.pro
              ? '« ${feature!.label} » fait partie de Sama360 Pro.'
              : 'Tout pour vendre plus : en boutique, en ligne et sur WhatsApp.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 13.5),
        ),
      ],
    ),
  );
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({
    super.key,
    required this.title,
    required this.price,
    required this.sub,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String price;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.surface(0.8),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? AppColors.ink : AppColors.glassLine, width: 1.4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: selected ? AppColors.ground : AppColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(
              price,
              style: TextStyle(
                color: selected ? AppColors.ground : AppColors.ink,
                fontWeight: FontWeight.w900,
                fontSize: 20,
              ),
            ),
            Text(
              sub,
              style: TextStyle(
                color: selected ? const Color(0xFFFFB020) : AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: AppColors.green,
          child: Text(
            '$n',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
      ],
    ),
  );
}

class _OnlineWaiting extends StatelessWidget {
  const _OnlineWaiting({required this.onCheck});
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) => Glass(
    key: const Key('pay_online_waiting'),
    radius: 22,
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paiement en cours', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                'Terminez le paiement sur la page Chariow. Pro s’active ici dès qu’il est confirmé.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        TextButton(onPressed: onCheck, child: const Text('Vérifier')),
      ],
    ),
  );
}

class _OnlineDone extends StatelessWidget {
  const _OnlineDone();

  @override
  Widget build(BuildContext context) => Glass(
    key: const Key('pay_online_done'),
    radius: 22,
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        const SuccessCheck(size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paiement reçu, merci !', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 3),
              Text('Sama360 Pro est activé.', style: TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Pending extends StatelessWidget {
  const _Pending({required this.request});
  final PaymentRequest request;

  @override
  Widget build(BuildContext context) => Glass(
    key: const Key('pay_pending'),
    radius: 22,
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        const Icon(Icons.hourglass_top_rounded, color: Color(0xFFFF7A00), size: 30),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Paiement en cours de vérification', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                '${moneyShort(request.amount)} · ${request.method.label} · réf. ${request.reference}\n'
                'Pro sera activé dès que nous aurons retrouvé le paiement.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ───────────────────────────────────────────────────────────── Parrainage

class ReferralScreen extends ConsumerWidget {
  const ReferralScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(referralsProvider);
    final business = ref.watch(currentBusinessProvider).value;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Parrainage', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<ReferralInfo>(
        value: info,
        onRetry: () => ref.invalidate(referralsProvider),
        data: (r) {
          final link = referralLink(ref.watch(apiBaseUrlProvider), r.code);
          final message = referralMessage(business: business?.name ?? 'ma boutique', code: r.code, link: link);
          final subscribed = r.referrals.where((x) => x.rewarded).length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFFDB2777), Color(0xFF7A5AF8)]),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Invitez un commerçant,\ngagnez chacun 1 mois Pro',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20, height: 1.2),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Il s’inscrit avec votre code. Dès qu’il paie son premier abonnement, '
                      'vous recevez tous les deux ${r.bonusDays} jours de Pro.',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 13.5),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                            alignment: Alignment.center,
                            child: Text(
                              r.code,
                              key: const Key('referral_code'),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 4,
                                color: Color(0xFF7A1F5C),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const Key('copy_code'),
                          tooltip: 'Copier le code',
                          style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.25)),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: r.code));
                            if (context.mounted) showInfo(context, 'Code copié');
                          },
                          icon: const Icon(Icons.copy_rounded, color: Colors.white),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  key: const Key('share_referral'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.whatsapp,
                    foregroundColor: AppColors.onWhatsapp,
                  ),
                  onPressed: () => ref.read(receiptActionsProvider).openWhatsApp(whatsAppUri(message)),
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text('Inviter sur WhatsApp'),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _Stat(value: '${r.referrals.length}', label: 'inscrits'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Stat(value: '$subscribed', label: 'abonnés'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Stat(value: '${(r.daysEarned / 30).floor()}', label: 'mois gagnés'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (r.referrals.isEmpty)
                Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    'Personne encore. Pensez à vos voisins de marché, vos fournisseurs, vos amis commerçants.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              else
                Glass(
                  radius: 20,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: [
                      for (final x in r.referrals)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: (x.rewarded ? AppColors.green : AppColors.muted).withValues(alpha: 0.14),
                            child: Icon(
                              x.rewarded ? Icons.verified_rounded : Icons.storefront_rounded,
                              color: x.rewarded ? AppColors.green : AppColors.muted,
                            ),
                          ),
                          title: Text(x.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [
                              if (x.city != null) x.city!,
                              'inscrit le ${_day.format(x.joinedAt.toLocal())}',
                            ].join(' · '),
                          ),
                          trailing: Text(
                            x.rewarded ? '+1 mois' : 'En essai',
                            style: TextStyle(
                              color: x.rewarded ? AppColors.green : AppColors.muted,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        Text(label, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
      ],
    ),
  );
}

// ───────────────────────────────────────────────────────────── Équipe Sama360
