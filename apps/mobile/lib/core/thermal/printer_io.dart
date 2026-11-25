import 'dart:io';

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'printer.dart';

ThermalPrinter createPrinter() => _BluetoothPrinter();

/// Android : imprimantes Bluetooth appairées dans les réglages du téléphone.
class _BluetoothPrinter implements ThermalPrinter {
  String? _connected;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<bool> ready() async {
    if (!supported) return false;
    if (!await PrintBluetoothThermal.isPermissionBluetoothGranted) return false;
    return PrintBluetoothThermal.bluetoothEnabled;
  }

  @override
  Future<List<PrinterDevice>> paired() async => [
    for (final d in await PrintBluetoothThermal.pairedBluetooths) PrinterDevice(d.name, d.macAdress),
  ];

  @override
  Future<bool> print(String address, List<int> bytes) async {
    if (_connected != address || !await PrintBluetoothThermal.connectionStatus) {
      if (_connected != null) await PrintBluetoothThermal.disconnect;
      if (!await PrintBluetoothThermal.connect(macPrinterAddress: address)) {
        _connected = null;
        return false;
      }
      _connected = address;
    }
    return PrintBluetoothThermal.writeBytes(bytes);
  }
}
