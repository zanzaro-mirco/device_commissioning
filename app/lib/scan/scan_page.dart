import 'package:ble_bridge/ble_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../device/device_cubit.dart';
import '../device/device_page.dart';
import '../link/device_link.dart';
import 'scan_cubit.dart';

class ScanPage extends StatelessWidget {
  const ScanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Centraline')),
      body: BlocBuilder<ScanCubit, ScanState>(
        builder: (context, state) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusLine(state: state),
              Expanded(
                child: state.devices.isEmpty
                    ? const _EmptyList()
                    : ListView(
                        children: [
                          for (final device in state.devices)
                            _DeviceTile(device: device),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: BlocBuilder<ScanCubit, ScanState>(
        builder: (context, state) {
          final scanning = state.status == ScanStatus.scanning;
          final cubit = context.read<ScanCubit>();
          return FloatingActionButton.extended(
            onPressed: scanning ? cubit.stop : cubit.start,
            icon: Icon(scanning ? Icons.stop : Icons.bluetooth_searching),
            label: Text(scanning ? 'Ferma' : 'Cerca'),
          );
        },
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final ScanState state;

  @override
  Widget build(BuildContext context) {
    final text = switch (state.status) {
      ScanStatus.idle =>
        state.devices.isEmpty
            ? 'Tocca «Cerca» per trovare le centraline qui intorno.'
            : 'Ricerca terminata.',
      ScanStatus.scanning => 'Ricerca in corso…',
      ScanStatus.permissionDenied =>
        'Senza il permesso «Dispositivi nelle vicinanze» l\'app non può '
            'trovare le centraline. Tocca «Cerca» per chiederlo di nuovo.',
      ScanStatus.permissionPermanentlyDenied =>
        'Il permesso «Dispositivi nelle vicinanze» è stato negato. Si concede '
            'dalle impostazioni di sistema, alla voce Autorizzazioni dell\'app.',
      ScanStatus.bluetoothOff => 'Il Bluetooth è spento. Accendilo e riprova.',
      ScanStatus.bluetoothUnavailable =>
        'Questo dispositivo non ha il Bluetooth LE, o non è utilizzabile.',
      ScanStatus.failed => 'La ricerca si è interrotta: ${state.error}',
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (state.status == ScanStatus.scanning) ...[
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.device_thermostat,
        size: 64,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final FoundDevice device;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.device_thermostat),
      title: Text(device.name ?? 'Centralina senza nome'),
      subtitle: Text('${device.id} · ${device.rssi} dBm'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final link = context.read<DeviceLink>();
        await context.read<ScanCubit>().stop();
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BlocProvider(
              create: (_) =>
                  DeviceCubit(link, deviceId: device.id, name: device.name)
                    ..connect(),
              child: const DevicePage(),
            ),
          ),
        );
      },
    );
  }
}
