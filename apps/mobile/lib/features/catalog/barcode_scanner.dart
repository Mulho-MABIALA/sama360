import 'dart:async';

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

/// Réponse affichée après chaque code lu en mode continu.
class ScanFeedback {
  const ScanFeedback(this.message, {this.ok = true});
  final String message;
  final bool ok;
}

typedef ScanHandler = Future<ScanFeedback> Function(String code);

/// Scanner en continu (caisse) : la caméra reste ouverte, chaque code lu est traité par [ScanHandler].
/// Renvoie le nombre de codes reconnus. Remplaçable dans les tests.
final continuousScannerProvider = Provider<Future<int> Function(BuildContext, ScanHandler)>(
  (ref) =>
      (context, onCode) async =>
          await Navigator.of(context, rootNavigator: true).push<int>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => ScannerScreen(title: 'Scanner les articles', onCode: onCode),
            ),
          ) ??
          0,
);

/// Écran plein cadre : caméra, cadre de visée, lampe, saisie manuelle en secours.
/// Avec [onCode], l'écran reste ouvert et enchaîne les articles (mode continu).
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.title = 'Scanner un code-barres', this.onCode});
  final String title;
  final ScanHandler? onCode;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  late final _controller = MobileScannerController(
    // En continu, le même article peut être scanné plusieurs fois de suite (deux bouteilles d'huile).
    detectionSpeed: widget.onCode == null ? DetectionSpeed.noDuplicates : DetectionSpeed.normal,
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
    _feedbackTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  // Mode continu
  int _count = 0;
  bool _busy = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  ScanFeedback? _feedback;
  Timer? _feedbackTimer;

  void _found(String code) {
    code = code.trim();
    if (_done || code.isEmpty) return;
    if (widget.onCode != null) {
      _handle(code);
      return;
    }
    _done = true;
    HapticFeedback.mediumImpact();
    Navigator.pop(context, code);
  }

  /// Mode continu : un code à la fois, et 1,5 s avant de relire le même code.
  Future<void> _handle(String code) async {
    final now = DateTime.now();
    if (_busy || (code == _lastCode && now.difference(_lastAt) < const Duration(milliseconds: 1500))) return;
    _busy = true;
    _lastCode = code;
    _lastAt = now;
    try {
      final f = await widget.onCode!(code);
      if (!mounted) return;
      f.ok ? HapticFeedback.mediumImpact() : HapticFeedback.heavyImpact();
      _feedbackTimer?.cancel();
      setState(() {
        _feedback = f;
        if (f.ok) _count++;
      });
      _feedbackTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _feedback = null);
      });
    } finally {
      _lastAt = DateTime.now();
      _busy = false;
    }
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
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(label: 'Valider', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ]),
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
                if (_feedback != null) ...[ScanFeedbackBanner(feedback: _feedback!), const SizedBox(height: 14)],
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
                if (widget.onCode != null) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.green,
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(context, _count),
                      icon: const Icon(Icons.shopping_cart_checkout_rounded),
                      label: Text(
                        _count == 0 ? 'Terminer' : 'Terminer · $_count article${_count > 1 ? 's' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bandeau vert (article ajouté) ou rouge (code inconnu) au-dessus du cadre.
class ScanFeedbackBanner extends StatelessWidget {
  const ScanFeedbackBanner({super.key, required this.feedback});
  final ScanFeedback feedback;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: feedback.ok ? AppColors.green : const Color(0xFFC62828),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(feedback.ok ? Icons.check_circle_rounded : Icons.help_rounded, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            feedback.message,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
      ],
    ),
  );
}
