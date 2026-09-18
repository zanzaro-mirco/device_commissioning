import 'package:ble_bridge/ble_bridge.dart';
import 'package:commissioning_app/scan/scan_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_link.dart';

/// In tempo vero: fermare la scansione aspetta la cancellazione di
/// un'iscrizione, che il tempo finto non fa avanzare.
void main() {
  late FakeDeviceLink link;

  setUp(() => link = FakeDeviceLink());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('permesso negato: nessuna scansione', () async {
    link.permission = PermissionState.denied;
    final cubit = ScanCubit(link);
    await cubit.start();
    expect(cubit.state.status, ScanStatus.permissionDenied);
    expect(link.scans, 0);
  });

  test('permesso negato per sempre: si rimanda alle impostazioni', () async {
    link.permission = PermissionState.permanentlyDenied;
    final cubit = ScanCubit(link);
    await cubit.start();
    expect(cubit.state.status, ScanStatus.permissionPermanentlyDenied);
    expect(link.scans, 0);
  });

  test('Bluetooth spento: nessuna scansione', () async {
    link.adapter = AdapterState.off;
    final cubit = ScanCubit(link);
    await cubit.start();
    expect(cubit.state.status, ScanStatus.bluetoothOff);
    expect(link.scans, 0);
  });

  test('elenca le centraline dalla più vicina, una volta ciascuna', () async {
    final cubit = ScanCubit(link);
    await cubit.start();
    expect(cubit.state.status, ScanStatus.scanning);

    link
      ..announce(const FoundDevice(id: 'A', name: 'DC-000A', rssi: -80))
      ..announce(const FoundDevice(id: 'B', name: 'DC-000B', rssi: -50))
      ..announce(const FoundDevice(id: 'A', name: 'DC-000A', rssi: -60));
    await settle();

    expect(cubit.state.devices.map((d) => d.id), ['B', 'A']);
    expect(cubit.state.devices.last.rssi, -60);
    await cubit.close();
  });

  test('la scansione si ferma da sola', () async {
    final cubit = ScanCubit(link, duration: const Duration(milliseconds: 50));
    await cubit.start();
    expect(link.scanning, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(link.scanning, isFalse);
    expect(cubit.state.status, ScanStatus.idle);
  });

  test('chiudere il cubit ferma la scansione', () async {
    final cubit = ScanCubit(link);
    await cubit.start();
    await cubit.close();
    expect(link.scanning, isFalse);
  });
}
