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
import 'cash_screen.dart';

/// Billets et pièces en FCFA, du plus gros au plus petit.
const cfaDenominations = [10000, 5000, 2000, 1000, 500, 250, 200, 100, 50, 25, 10, 5];

/// Total d'un comptage billet par billet.
int countTotal(Map<int, int> pieces) => pieces.entries.fold(0, (s, e) => s + e.key * e.value);

/// Clôture : comptage par moyen de paiement, écart en direct, rapport Z.
class CashCloseScreen extends ConsumerStatefulWidget {
  const CashCloseScreen({super.key, this.sessionId});

  /// Caisse d'un vendeur clôturée par le gérant ; null : ma caisse.
  final String? sessionId;

  @override
  ConsumerState<CashCloseScreen> createState() => _CashCloseScreenState();
}

class _CashCloseScreenState extends ConsumerState<CashCloseScreen> {
  final _counted = <PayMethod, TextEditingController>{};
  final _note = TextEditingController();
  final _pieces = <int, int>{};
  bool _counter = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _counted.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  TextEditingController _ctrl(CashMethodLine m) => _counted.putIfAbsent(
    m.method,
    // Espèces : à compter ; mobile money et carte : l'attendu proposé, à vérifier sur le relevé
    () => TextEditingController(text: m.method == PayMethod.cash ? '' : '${m.expected}'),
  );

  int? _value(PayMethod m) => int.tryParse(_counted[m]?.text ?? '');

  Future<void> _close(CashSession s) async {
    final cash = _value(PayMethod.cash);
    if (cash == null) return showInfo(context, 'Comptez les espèces de la caisse');
    final counted = {
      for (final m in s.report.methods)
        if (_value(m.method) != null) m.method: _value(m.method)!,
    };
    final diff = s.report.methods.fold(0, (t, m) => t + ((counted[m.method] ?? m.expected) - m.expected));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fermer la caisse ?'),
        content: Text(
          diff == 0
              ? 'Tout est juste. La caisse sera fermée et le résumé enregistré.'
              : diff < 0
              ? 'Il manque ${money(-diff)}. La caisse sera fermée avec cet écart.'
              : 'Il y a ${money(diff)} en trop. La caisse sera fermée avec cet écart.',
        ),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Fermer', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final closed = await ref
          .read(repoProvider)
          .closeCash(sessionId: widget.sessionId, counted: counted, note: _note.text);
      refreshCash(ref);
      if (!mounted) return;
      showInfo(context, 'Caisse fermée');
      context.pushReplacement('/cash/sessions/${closed.id}');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.sessionId == null
        ? ref.watch(cashCurrentProvider)
        : ref.watch(cashSessionProvider(widget.sessionId!)).whenData<CashSession?>((s) => s);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Fin de journée', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<CashSession?>(
        value: session,
        onRetry: () => refreshCash(ref),
        data: (s) {
          if (s == null || !s.open) {
            return Center(
              child: Text('Aucune caisse ouverte', style: TextStyle(color: AppColors.muted)),
            );
          }
          final lines = s.report.methods;
          final diff = lines.fold(0, (t, m) => t + ((_value(m.method) ?? m.expected) - m.expected));
          final cashCounted = _value(PayMethod.cash) != null;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Text(
                      '${s.number} · ${s.userName ?? ''} · ouverte à ${hourOf(s.openedAt)}',
                      style: TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 12),
                    for (final m in lines) ...[
                      _CountTile(
                        line: m,
                        controller: _ctrl(m),
                        onChanged: () => setState(() {}),
                        onCounter: m.method == PayMethod.cash ? () => setState(() => _counter = !_counter) : null,
                        counterOpen: _counter,
                      ),
                      if (m.method == PayMethod.cash && _counter)
                        _BanknoteCounter(
                          pieces: _pieces,
                          onChanged: () => setState(() => _ctrl(m).text = '${countTotal(_pieces)}'),
                        ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      key: const Key('closingNote'),
                      controller: _note,
                      decoration: const InputDecoration(
                        labelText: 'Note (facultatif)',
                        hintText: 'Ex. 500 F rendus en trop à un client',
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                child: Glass(
                  radius: 28,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Écart',
                              style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                            ),
                          ),
                          DifferenceText(value: cashCounted ? diff : null, big: true),
                        ],
                      ),
                      const SizedBox(height: 10),
                      BusyButton(label: 'Fermer la caisse', busy: _busy, onPressed: () => _close(s)),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Écart coloré : vert si juste, rouge s'il manque, orange s'il y a trop.
class DifferenceText extends StatelessWidget {
  const DifferenceText({super.key, required this.value, this.big = false});
  final int? value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final (text, color) = v == null
        ? ('—', AppColors.muted)
        : v == 0
        ? ('Juste', AppColors.green)
        : v < 0
        ? ('Manque ${money(-v)}', AppColors.danger)
        : ('En trop ${money(v)}', AppColors.warn);
    return Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: big ? 18 : 13),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.line,
    required this.controller,
    required this.onChanged,
    this.onCounter,
    this.counterOpen = false,
  });
  final CashMethodLine line;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback? onCounter;
  final bool counterOpen;

  @override
  Widget build(BuildContext context) {
    final counted = int.tryParse(controller.text);
    return Glass(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PayLogo(line.method, size: 26, color: AppColors.green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(line.method.label, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              Text('Attendu ${moneyShort(line.expected)}', style: TextStyle(color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 10),
          // Libellé au-dessus du champ (pas de libellé flottant qui se décale dans la carte).
          Text(
            line.method == PayMethod.cash ? 'Espèces comptées' : 'Montant vérifié',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.muted),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: Key('count_${line.method.api}'),
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(hintText: '0', suffixText: 'F'),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DifferenceText(value: counted == null ? null : counted - line.expected),
                ),
              ),
            ],
          ),
          if (onCounter != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onCounter,
                icon: Icon(counterOpen ? Icons.expand_less_rounded : Icons.calculate_outlined, size: 18),
                label: Text(counterOpen ? 'Fermer le compteur' : 'Compter billet par billet'),
              ),
            ),
        ],
      ),
    );
  }
}

class _BanknoteCounter extends StatelessWidget {
  const _BanknoteCounter({required this.pieces, required this.onChanged});
  final Map<int, int> pieces;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Glass(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        children: [
          for (final d in cfaDenominations)
            Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(moneyShort(d), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  tooltip: 'Un billet de ${moneyShort(d)} de moins',
                  onPressed: (pieces[d] ?? 0) == 0
                      ? null
                      : () {
                          pieces[d] = (pieces[d] ?? 0) - 1;
                          onChanged();
                        },
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${pieces[d] ?? 0}',
                    key: Key('pieces_$d'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: 'Un billet de ${moneyShort(d)} de plus',
                  onPressed: () {
                    pieces[d] = (pieces[d] ?? 0) + 1;
                    onChanged();
                  },
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
                const Spacer(),
                Text(moneyShort(d * (pieces[d] ?? 0)), style: TextStyle(color: AppColors.muted, fontSize: 13)),
              ],
            ),
        ],
      ),
    ),
  );
}
