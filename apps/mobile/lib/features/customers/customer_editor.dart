import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Fiche client ou fournisseur ([supplier]) : création ([customerId] null) ou modification.
class CustomerEditorScreen extends ConsumerStatefulWidget {
  const CustomerEditorScreen({super.key, this.customerId, this.initialName, this.supplier = false});
  final String? customerId;
  final String? initialName;
  final bool supplier;

  @override
  ConsumerState<CustomerEditorScreen> createState() => _CustomerEditorScreenState();
}

class _CustomerEditorScreenState extends ConsumerState<CustomerEditorScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _notes = TextEditingController();
  final _limit = TextEditingController();
  bool _hasLimit = false;
  int? _birthDay;
  int? _birthMonth;
  int _balance = 0;
  bool _loaded = false;
  bool _busy = false;
  final _errors = <String, String>{};

  bool get _editing => widget.customerId != null;
  bool get _supplier => widget.supplier;

  @override
  void initState() {
    super.initState();
    _name.text = widget.initialName ?? '';
    if (!_editing) {
      _loaded = true;
      return;
    }
    Future(() async {
      try {
        final Contact c;
        if (_supplier) {
          final o = await ref.read(supplierProvider(widget.customerId!).future);
          c = o.supplier;
          _balance = o.due;
        } else {
          final o = await ref.read(customerOverviewProvider(widget.customerId!).future);
          c = o.customer;
          _balance = o.balance;
        }
        _name.text = c.name;
        _phone.text = c.phone == null ? '' : editablePhone(c.phone!, ref.read(countryProvider));
        _email.text = c.email ?? '';
        _address.text = c.address ?? '';
        _notes.text = c.notes ?? '';
        _hasLimit = c.creditLimit != null;
        _limit.text = c.creditLimit?.toString() ?? '';
        _birthDay = c.birthDay;
        _birthMonth = c.birthMonth;
      } catch (e) {
        if (mounted) showError(context, e);
      }
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _notes, _limit]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _clean(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  String get _base => _supplier ? '/suppliers' : '/customers';
  String get _home => _supplier ? '/purchases?tab=suppliers' : '/customers';

  void _leave(Contact? result) =>
      context.canPop() ? context.pop(result) : context.go(result == null ? _home : '$_base/${result.id}');

  Future<void> _save() async {
    _errors.clear();
    final name = _name.text.trim();
    if (name.isEmpty) _errors['name'] = _supplier ? 'Indiquez le nom du fournisseur' : 'Indiquez le nom du client';
    final phone = _phone.text.trim().isEmpty ? null : localPhone(_phone.text, ref.read(countryProvider));
    if (_phone.text.trim().isNotEmpty && phone == null) _errors['phone'] = invalidPhone(ref.read(countryProvider));
    final email = _clean(_email);
    if (email != null && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _errors['email'] = 'Adresse e-mail invalide';
    }
    final limit = int.tryParse(_limit.text);
    if (_hasLimit && limit == null) _errors['limit'] = 'Indiquez le montant maximum';
    setState(() {});
    if (_errors.isNotEmpty) return;

    final canLimit = !_supplier && ref.read(canProvider('sales:void'));
    final draft = CustomerDraft(
      name: name,
      phone: phone,
      email: email,
      address: _clean(_address),
      notes: _clean(_notes),
      creditLimit: _hasLimit && !_supplier ? limit : null,
      birthDay: _supplier || _birthMonth == null ? null : _birthDay,
      birthMonth: _supplier || _birthDay == null ? null : _birthMonth,
    );
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(repoProvider)
          .saveCustomer(draft, id: widget.customerId, withLimit: canLimit, type: _supplier ? 'supplier' : 'customer');
      _supplier ? refreshPurchasing(ref) : refreshBusinessData(ref);
      if (!mounted) return;
      showInfo(context, _editing ? 'Fiche enregistrée' : '${saved.name} ajouté(e)');
      _leave(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  Future<void> _delete() async {
    if (_balance > 0) {
      showInfo(
        context,
        _supplier
            ? 'Vous devez encore ${money(_balance)} à ce fournisseur : réglez-le avant de le supprimer'
            : 'Ce client doit encore ${money(_balance)} : soldez sa dette avant de le supprimer',
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer « ${_name.text} » ?'),
        content: Text(
          _supplier
              ? 'Il disparaît de vos fournisseurs. Ses bons de commande passés restent dans l’historique.'
              : 'Il disparaît de vos clients. Ses ventes et factures passées restent dans l’historique.',
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Supprimer', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final who = _supplier ? 'le fournisseur' : 'le client';
    if (!await confirmSensitive(context, ref, action: 'Supprimer $who')) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).deleteCustomer(widget.customerId!);
      _supplier ? refreshPurchasing(ref) : refreshBusinessData(ref);
      if (!mounted) return;
      showInfo(context, _supplier ? 'Fournisseur supprimé' : 'Client supprimé');
      context.go(_home);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canLimit = ref.watch(canProvider('sales:void'));
    final canDelete = ref.watch(canProvider('contacts:write'));
    final who = _supplier ? 'fournisseur' : 'client';
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          _editing ? 'Modifier le $who' : 'Nouveau $who',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_editing && canDelete)
            IconButton(
              tooltip: 'Supprimer le $who',
              onPressed: _busy || !_loaded ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      _Section(
                        title: 'Coordonnées',
                        children: [
                          TextField(
                            key: const Key('cName'),
                            controller: _name,
                            autofocus: !_editing && _name.text.isEmpty,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: _supplier ? 'Nom du fournisseur' : 'Nom du client',
                              errorText: _errors['name'],
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('cPhone'),
                            controller: _phone,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Téléphone',
                              prefixText: '+${ref.watch(countryProvider).dial} ',
                              helperText: _supplier
                                  ? 'Pour lui envoyer vos bons de commande'
                                  : 'Pour les rappels WhatsApp et SMS',
                              errorText: _errors['phone'],
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('cEmail'),
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(labelText: 'E-mail (facultatif)', errorText: _errors['email']),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('cAddress'),
                            controller: _address,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(labelText: 'Adresse ou quartier (facultatif)'),
                          ),
                          if (!_supplier) ...[
                            const SizedBox(height: 12),
                            _BirthdayField(
                              day: _birthDay,
                              month: _birthMonth,
                              onChanged: (d, m) => setState(() {
                                _birthDay = d;
                                _birthMonth = m;
                              }),
                            ),
                          ],
                        ],
                      ),
                      if (!_supplier) const SizedBox(height: 12),
                      if (!_supplier)
                        _Section(
                          title: 'Crédit',
                          children: [
                            SwitchListTile(
                              key: const Key('cHasLimit'),
                              contentPadding: EdgeInsets.zero,
                              value: _hasLimit,
                              onChanged: canLimit ? (v) => setState(() => _hasLimit = v) : null,
                              title: const Text('Plafond de crédit', style: TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(
                                canLimit
                                    ? 'La caisse refuse une vente à crédit qui dépasse ce montant'
                                    : 'Seul le gérant ou le propriétaire peut le modifier',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            if (_hasLimit) ...[
                              const SizedBox(height: 4),
                              TextField(
                                key: const Key('cLimit'),
                                controller: _limit,
                                enabled: canLimit,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                decoration: InputDecoration(
                                  labelText: 'Dette maximum autorisée',
                                  suffixText: 'FCFA',
                                  errorText: _errors['limit'],
                                ),
                              ),
                            ],
                          ],
                        ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Notes',
                        children: [
                          TextField(
                            key: const Key('cNotes'),
                            controller: _notes,
                            minLines: 2,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: _supplier
                                  ? 'Jours de livraison, délai de paiement, contact commercial…'
                                  : 'Préférences, jour de paie, personne à contacter…',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.all(14),
                    child: BusyButton(
                      label: _editing ? 'Enregistrer' : 'Ajouter le $who',
                      busy: _busy,
                      onPressed: _save,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
}

/// Anniversaire : jour et mois (l'année n'est pas demandée), pour les vœux et la fidélité.
class _BirthdayField extends StatelessWidget {
  const _BirthdayField({required this.day, required this.month, required this.onChanged});
  final int? day;
  final int? month;
  final void Function(int? day, int? month) onChanged;

  static const _months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];

  static int _daysIn(int? m) => switch (m) {
    2 => 29,
    4 || 6 || 9 || 11 => 30,
    _ => 31,
  };

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        flex: 2,
        child: DropdownButtonFormField<int?>(
          key: const Key('cBirthDay'),
          initialValue: day,
          decoration: const InputDecoration(labelText: 'Anniversaire', prefixIcon: Icon(Icons.cake_rounded)),
          items: [
            const DropdownMenuItem(value: null, child: Text('Jour')),
            for (var d = 1; d <= _daysIn(month); d++) DropdownMenuItem(value: d, child: Text('$d')),
          ],
          onChanged: (d) => onChanged(d, month),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 3,
        child: DropdownButtonFormField<int?>(
          key: const Key('cBirthMonth'),
          initialValue: month,
          decoration: const InputDecoration(labelText: 'Mois'),
          items: [
            const DropdownMenuItem(value: null, child: Text('—')),
            for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(_months[m - 1])),
          ],
          // Un 31 qui n'existe pas dans le nouveau mois devient le dernier jour
          onChanged: (m) => onChanged(day?.clamp(1, _daysIn(m)), m),
        ),
      ),
    ],
  );
}
