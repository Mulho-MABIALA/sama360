import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'printer_stub.dart' if (dart.library.io) 'printer_io.dart' as impl;

/// Imprimante Bluetooth appairée au téléphone.
class PrinterDevice {
  const PrinterDevice(this.name, this.address);
  final String name;
  final String address;
}

/// Imprimante thermique Bluetooth (Android). Sur le web : non disponible, on imprime en PDF.
abstract class ThermalPrinter {
  bool get supported;

  /// Bluetooth activé et autorisé (demande l'autorisation si besoin).
  Future<bool> ready();
  Future<List<PrinterDevice>> paired();

  /// Se connecte (si besoin) puis envoie le ticket. Renvoie false si l'imprimante ne répond pas.
  Future<bool> print(String address, List<int> bytes);
}

final thermalPrinterProvider = Provider<ThermalPrinter>((ref) => impl.createPrinter());

/// Imprimante choisie, gardée sur le téléphone.
class SavedPrinter {
  const SavedPrinter({required this.name, required this.address, this.width = 32});
  final String name;
  final String address;

  /// 32 caractères (58 mm) ou 48 (80 mm).
  final int width;
  bool get wide => width >= 48;
}

class SavedPrinterController extends AsyncNotifier<SavedPrinter?> {
  static const _k = 'printer.bt';

  @override
  Future<SavedPrinter?> build() async {
    final raw = (await SharedPreferences.getInstance()).getStringList(_k);
    if (raw == null || raw.length < 3) return null;
    return SavedPrinter(name: raw[0], address: raw[1], width: int.tryParse(raw[2]) ?? 32);
  }

  Future<void> save(SavedPrinter p) async {
    await (await SharedPreferences.getInstance()).setStringList(_k, [p.name, p.address, '${p.width}']);
    state = AsyncData(p);
  }

  Future<void> forget() async {
    await (await SharedPreferences.getInstance()).remove(_k);
    state = const AsyncData(null);
  }
}

final savedPrinterProvider = AsyncNotifierProvider<SavedPrinterController, SavedPrinter?>(SavedPrinterController.new);
