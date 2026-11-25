import 'printer.dart';

/// Web : pas de Bluetooth classique dans le navigateur.
ThermalPrinter createPrinter() => _NoPrinter();

class _NoPrinter implements ThermalPrinter {
  @override
  bool get supported => false;
  @override
  Future<bool> ready() async => false;
  @override
  Future<List<PrinterDevice>> paired() async => const [];
  @override
  Future<bool> print(String address, List<int> bytes) async => false;
}
