import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/widgets.dart';

import '../../core/theme.dart';

/// Ouvre le scanner et renvoie le code lu (null si annulé). Remplaçable dans les tests.
final barcodeScannerProvider = Provider<Future<String?> Function(BuildContext)>(
  (ref) =>
      (context) => Navigator.of(
        context,
        rootNavigator: true,
      ).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ScannerScreen())),
);

/// Écran plein cadre : caméra, cadre de visée, lampe, saisie manuelle en secours.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.title = 'Scanner un code-barres'});
  final String title;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.qrCode,
    ],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _found(String code) {
    if (_done || code.trim().isEmpty) return;
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.pop(context, code.trim());
  }

  Future<void> _typeCode() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Saisir le code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Chiffres sous le code-barres'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(label: 'Valider', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    if (code != null) _found(code);
  }

  @override
  Widget build(BuildContext context) {
    const box = 260.0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Lampe',
            color: Colors.white,
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
              if (value != null) _found(value);
            },
            errorBuilder: (context, error) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Autorisez l’appareil photo pour scanner, ou saisissez le code à la main.'
                    : 'Caméra indisponible. Saisissez le code à la main.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
          IgnorePointer(
            child: Container(
              width: box,
              height: box * 0.62,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.glow, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            bottom: 40 + MediaQuery.paddingOf(context).bottom,
            left: 24,
            right: 24,
            child: Column(
              children: [
                const Text(
                  'Placez le code-barres dans le cadre',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    side: const BorderSide(color: Colors.white54),
                  ),
                  onPressed: _typeCode,
                  icon: const Icon(Icons.keyboard_rounded),
                  label: const Text('Saisir le code'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
