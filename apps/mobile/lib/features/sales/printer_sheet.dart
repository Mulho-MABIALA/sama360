import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/thermal/printer.dart';
import '../../core/widgets.dart';
import 'receipt_escpos.dart';

/// Résultat de l'impression d'un reçu.
enum PrintOutcome { printed, usePdf, cancelled }

/// Choix de l'imprimante Bluetooth (appairée dans les réglages du téléphone) et du rouleau.
/// Renvoie l'imprimante choisie (ou null) et vrai si l'on préfère imprimer le PDF.
Future<(SavedPrinter?, bool)> pickPrinter(BuildContext context) async {
  final r = await showModalBottomSheet<Object>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PrinterSheet(),
  );
  if (r is SavedPrinter) return (r, false);
  return (null, r == PrintOutcome.usePdf);
}

/// Imprime le reçu sur l'imprimante Bluetooth (la choisit la première fois).
/// Sur le web ou si l'on préfère : [PrintOutcome.usePdf], l'appelant imprime le PDF.
Future<PrintOutcome> printReceiptThermal(
  BuildContext context,
  WidgetRef ref,
  SaleDetail sale,
  CurrentBusiness business, {
  bool choose = false,
}) async {
  final thermal = ref.read(thermalPrinterProvider);
  if (!thermal.supported) return PrintOutcome.usePdf;
  var printer = choose ? null : await ref.read(savedPrinterProvider.future);
  if (printer == null) {
    if (!context.mounted) return PrintOutcome.cancelled;
    final (picked, pdf) = await pickPrinter(context);
    if (pdf) return PrintOutcome.usePdf;
    if (picked == null) return PrintOutcome.cancelled;
    await ref.read(savedPrinterProvider.notifier).save(picked);
    printer = picked;
  }
  final ok = await thermal.print(printer.address, receiptEscPos(sale, business, width: printer.width));
  if (ok) return PrintOutcome.printed;
  if (!context.mounted) return PrintOutcome.cancelled;
  // Imprimante éteinte, hors de portée ou déjà connectée à un autre téléphone
  final next = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('printer_unreachable'),
      title: const Text('Imprimante injoignable'),
      content: Text(
        '« ${printer!.name} » ne répond pas. Vérifiez qu’elle est allumée, chargée et à côté du téléphone.',
      ),
      actions: dialogActions([
        CancelButton(label: 'Changer', onPressed: () => Navigator.pop(ctx, 'change')),
        ConfirmButton(label: 'Réessayer', onPressed: () => Navigator.pop(ctx, 'retry')),
      ]),
    ),
  );
  if (!context.mounted) return PrintOutcome.cancelled;
  if (next == 'retry') return printReceiptThermal(context, ref, sale, business);
  if (next == 'change') return printReceiptThermal(context, ref, sale, business, choose: true);
  return PrintOutcome.cancelled;
}

class _PrinterSheet extends ConsumerStatefulWidget {
  const _PrinterSheet();
  @override
  ConsumerState<_PrinterSheet> createState() => _PrinterSheetState();
}

class _PrinterSheetState extends ConsumerState<_PrinterSheet> {
  late Future<(bool, List<PrinterDevice>)> _load = _scan();
  int _width = 32;

  Future<(bool, List<PrinterDevice>)> _scan() async {
    final t = ref.read(thermalPrinterProvider);
    if (!await t.ready()) return (false, const <PrinterDevice>[]);
    return (true, await t.paired());
  }

  @override
  void initState() {
    super.initState();
    final saved = ref.read(savedPrinterProvider).value;
    if (saved != null) _width = saved.width;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: FutureBuilder<(bool, List<PrinterDevice>)>(
          future: _load,
          builder: (context, snap) {
            final children = <Widget>[
              const Text('Imprimante Bluetooth', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                'Les petites imprimantes de reçus (58 ou 80 mm). Appairez-la d’abord dans les réglages '
                'Bluetooth du téléphone (code souvent 0000 ou 1234).',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                key: const Key('printer_width'),
                segments: const [
                  ButtonSegment(value: 32, label: Text('Rouleau 58 mm')),
                  ButtonSegment(value: 48, label: Text('Rouleau 80 mm')),
                ],
                selected: {_width},
                onSelectionChanged: (s) => setState(() => _width = s.first),
              ),
              const SizedBox(height: 8),
            ];
            if (snap.connectionState != ConnectionState.done) {
              children.add(
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            } else {
              final (ok, devices) = snap.data ?? (false, const <PrinterDevice>[]);
              if (!ok) {
                children.add(
                  _Hint(
                    key: const Key('printer_bluetooth_off'),
                    icon: Icons.bluetooth_disabled_rounded,
                    text: 'Activez le Bluetooth et autorisez Sama360 à l’utiliser, puis réessayez.',
                    onRetry: () => setState(() => _load = _scan()),
                  ),
                );
              } else if (devices.isEmpty) {
                children.add(
                  _Hint(
                    key: const Key('printer_none'),
                    icon: Icons.print_disabled_rounded,
                    text:
                        'Aucune imprimante appairée. Allumez-la, appairez-la dans les réglages Bluetooth, puis réessayez.',
                    onRetry: () => setState(() => _load = _scan()),
                  ),
                );
              } else {
                for (final d in devices) {
                  children.add(
                    Card(
                      child: ListTile(
                        key: Key('printer_${d.address}'),
                        leading: Icon(Icons.print_rounded, color: AppColors.green),
                        title: Text(
                          d.name.isEmpty ? d.address : d.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(d.address),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.pop(
                          context,
                          SavedPrinter(name: d.name.isEmpty ? d.address : d.name, address: d.address, width: _width),
                        ),
                      ),
                    ),
                  );
                }
              }
            }
            children.addAll([
              const SizedBox(height: 6),
              TextButton.icon(
                key: const Key('printer_pdf'),
                onPressed: () => Navigator.pop(context, PrintOutcome.usePdf),
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('Imprimer autrement (PDF)'),
              ),
            ]);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            );
          },
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.icon, required this.text, required this.onRetry});
  final IconData icon;
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: AppColors.warnBg, borderRadius: BorderRadius.circular(16)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: AppColors.warnText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onRetry, child: const Text('Réessayer')),
        ),
      ],
    ),
  );
}
