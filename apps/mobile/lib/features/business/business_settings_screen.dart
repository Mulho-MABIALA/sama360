import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../profile/profile_screen.dart' show SettingsRow, SettingsSection;
import '../shop/shop_screen.dart' show shopUrl;
import 'business_logo.dart';

/// Page « Ma boutique » : tous les réglages de la boutique, rangés par thème.
/// (Ce qui concerne la personne — nom, code secret, déconnexion — est dans « Mon compte ».)
class BusinessSettingsScreen extends ConsumerStatefulWidget {
  const BusinessSettingsScreen({super.key});
  @override
  ConsumerState<BusinessSettingsScreen> createState() => _BusinessSettingsScreenState();
}

class _BusinessSettingsScreenState extends ConsumerState<BusinessSettingsScreen> {
  /// Pays de l'entreprise : indicatif des numéros, paiements mobiles, identifiant fiscal.
  Future<void> _changeCountry(CurrentBusiness b) async {
    var picked = b.country;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Pays de l’entreprise'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CountryPills(value: picked, onChanged: (c) => setState(() => picked = c)),
              const SizedBox(height: 12),
              Text(
                'Les numéros tapés sans indicatif seront lus comme des numéros '
                '${picked == Country.ci
                    ? 'ivoiriens'
                    : picked == Country.cg
                    ? 'congolais'
                    : 'sénégalais'}. '
                'Les numéros déjà enregistrés ne changent pas.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.pop(ctx, false)),
            ConfirmButton(label: 'Enregistrer', onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      ),
    );
    if (ok != true || picked == b.country) return;
    try {
      await ref.read(repoProvider).updateCountry(picked.code);
      ref.invalidate(currentBusinessProvider);
      if (mounted) showInfo(context, 'Pays : ${picked.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _setRequireOpenCash(bool v) async {
    try {
      await ref.read(repoProvider).updateRequireOpenCash(v);
      ref.invalidate(currentBusinessProvider);
      if (mounted) {
        showInfo(context, v ? 'Les ventes demandent maintenant une caisse ouverte' : 'Vente possible caisse fermée');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final link = auth?.business;
    final me = auth?.me;
    final canEdit = ref.can('business:update');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Ma boutique', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<CurrentBusiness>(
        value: ref.watch(currentBusinessProvider),
        onRetry: () => ref.invalidate(currentBusinessProvider),
        data: (b) {
          List<Widget> gap(List<Widget> w) => [
            for (var i = 0; i < w.length; i++) ...[if (i > 0) const SizedBox(height: 16), w[i]],
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: gap([
              // En-tête : logo (touchable pour le changer), nom, rôle
              Glass(
                radius: 24,
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    InkWell(
                      key: const Key('business_logo_header'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: canEdit ? () => changeBusinessLogo(context, ref, b) : null,
                      child: BusinessLogo(business: b, size: 60, radius: 16),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
                          Text(
                            [?link?.roleName, ?b.city].join(' · '),
                            style: TextStyle(color: AppColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if ((me?.businesses.length ?? 0) > 1)
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: () => context.push('/business'),
                        child: const Text('Changer'),
                      ),
                  ],
                ),
              ),
              if (canEdit)
                SettingsSection(
                  title: 'Identité',
                  children: [
                    SettingsRow(
                      key: const Key('logo_row'),
                      icon: Icons.image_rounded,
                      color: const Color(0xFF7A5AF8),
                      label: 'Logo',
                      value: b.logoFileId == null ? 'Ajouter un logo' : 'Changer le logo',
                      hint: 'Sur vos reçus, factures et devis',
                      onTap: () => changeBusinessLogo(context, ref, b),
                    ),
                    SettingsRow(
                      icon: Icons.palette_rounded,
                      color: const Color(0xFFDB2777),
                      label: 'Couleur',
                      value: 'Couleur de la boutique',
                      hint: 'Boutons, reçus, boutique en ligne',
                      onTap: () => context.push('/settings/display'),
                    ),
                    SettingsRow(
                      key: const Key('country_row'),
                      icon: Icons.public_rounded,
                      color: const Color(0xFF1D7AF0),
                      label: 'Pays',
                      value: b.country.name,
                      hint:
                          '+${b.country.dial} · FCFA (${b.country.currency}) · '
                          '${b.country.mobileMoney.map((m) => m.label).join(', ')}',
                      trailing: CountryFlag(b.country, width: 28),
                      onTap: () => _changeCountry(b),
                    ),
                  ],
                ),
              if (canEdit)
                SettingsSection(
                  title: 'Encaisser',
                  children: [
                    SettingsRow(
                      key: const Key('pay_accounts_row'),
                      icon: Icons.qr_code_2_rounded,
                      color: const Color(0xFF0E9384),
                      label: 'Paiement mobile',
                      value: b.payAccounts.isEmpty ? 'À configurer' : b.payAccounts.keys.map((m) => m.label).join(', '),
                      hint: 'Votre QR et votre numéro, montrés au client à la caisse',
                      onTap: () => context.push('/business/pay-accounts'),
                    ),
                    SettingsRow(
                      key: const Key('require_cash_row'),
                      icon: Icons.point_of_sale_rounded,
                      color: const Color(0xFFD9822B),
                      label: 'Caisse obligatoire',
                      value: b.requireOpenCash ? 'Activée' : 'Désactivée',
                      hint: 'Obliger à ouvrir la caisse avant de vendre',
                      trailing: Switch(value: b.requireOpenCash, onChanged: _setRequireOpenCash),
                      onTap: () => _setRequireOpenCash(!b.requireOpenCash),
                    ),
                  ],
                ),
              SettingsSection(
                title: 'Vendre en ligne',
                children: [
                  SettingsRow(
                    icon: Icons.language_rounded,
                    color: const Color(0xFF1D7AF0),
                    label: 'Boutique en ligne',
                    value: shopUrl(
                      ref.watch(apiBaseUrlProvider),
                      '/s/${b.slug}',
                    ).replaceFirst(RegExp(r'^https?://'), ''),
                    hint: 'Commandes, produits publiés, partage',
                    onTap: () => context.push('/shop'),
                  ),
                  if (canEdit)
                    SettingsRow(
                      icon: Icons.event_available_rounded,
                      color: const Color(0xFF7A5AF8),
                      label: 'Réservation en ligne',
                      value: 'Rendez-vous',
                      hint: 'Vos clients réservent un service depuis leur téléphone',
                      onTap: () => context.push('/booking/settings'),
                    ),
                ],
              ),
              if (ref.can('members:read') || canEdit)
                SettingsSection(
                  title: 'Équipe',
                  children: [
                    if (ref.can('members:read'))
                      SettingsRow(
                        icon: Icons.groups_rounded,
                        color: const Color(0xFFDB2777),
                        label: 'Équipe',
                        value: 'Mon équipe',
                        hint: ref.can('members:invite') ? 'Inviter un vendeur ou un gérant' : null,
                        onTap: () => context.push('/team'),
                      ),
                    if (canEdit)
                      SettingsRow(
                        key: const Key('locations_row'),
                        icon: Icons.place_rounded,
                        color: const Color(0xFF2E90FA),
                        label: 'Points de vente',
                        value: switch (ref.watch(locationsProvider).value?.list.length) {
                          null => '',
                          1 => '1 boutique',
                          final n => '$n boutiques',
                        },
                        hint: 'Plusieurs boutiques : un stock et une caisse chacune',
                        onTap: () => context.push('/locations'),
                      ),
                  ],
                ),
              SettingsSection(
                title: 'Abonnement',
                children: [
                  SettingsRow(
                    key: const Key('pro_row'),
                    icon: Icons.workspace_premium_rounded,
                    color: const Color(0xFFFF7A00),
                    label: 'Sama360 Pro',
                    value: !b.isPro
                        ? 'Offre gratuite'
                        : b.trial
                        ? 'Essai · ${b.proDaysLeft} j'
                        : 'Actif · ${b.proDaysLeft} j',
                    hint: b.isPro
                        ? 'Boutique en ligne, vendeurs, livraisons, assistant…'
                        : 'Passez à Pro pour la boutique en ligne, les vendeurs, les livraisons…',
                    onTap: () => context.push('/pro'),
                  ),
                  SettingsRow(
                    key: const Key('referral_row'),
                    icon: Icons.card_giftcard_rounded,
                    color: const Color(0xFFDB2777),
                    label: 'Parrainage',
                    value: '1 mois offert',
                    hint: 'Invitez un commerçant : 1 mois Pro pour chacun',
                    onTap: () => context.push('/referral'),
                  ),
                ],
              ),
              if (link?.role == 'owner')
                SettingsSection(
                  title: 'Supprimer',
                  children: [
                    SettingsRow(
                      key: const Key('delete_business_row'),
                      icon: Icons.store_mall_directory_outlined,
                      color: AppColors.danger,
                      label: 'Boutique',
                      value: 'Supprimer ${b.name}',
                      hint: '30 jours pour changer d’avis',
                      trailing: Icon(Icons.chevron_right_rounded, color: AppColors.danger),
                      onTap: () => context.push('/business/delete'),
                    ),
                  ],
                ),
            ]),
          );
        },
      ),
    );
  }
}
