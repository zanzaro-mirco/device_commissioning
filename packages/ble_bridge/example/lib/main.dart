import 'dart:async';

import 'package:ble_bridge/ble_bridge.dart';
import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:flutter/material.dart';

/// L'esempio minimo del plugin: permessi, scansione, connessione e lettura
/// dello stato. L'app vera, con le scritture e l'esito incerto, sta in `app/`.
void main() => runApp(const MaterialApp(home: ExamplePage()));

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final _bridge = BleBridge();
  final _found = <String, FoundDevice>{};
  StreamSubscription<FoundDevice>? _scan;
  String _status = 'fermo';

  Future<void> _startScan() async {
    final permission = await _bridge.requestPermissions();
    if (permission != PermissionState.granted) {
      setState(() => _status = 'permessi: ${permission.name}');
      return;
    }
    await _scan?.cancel();
    setState(() {
      _found.clear();
      _status = 'scansione';
    });
    _scan = _bridge.scan().listen(
      (device) => setState(() => _found[device.id] = device),
      onError: (Object error) => setState(() => _status = '$error'),
    );
  }

  Future<void> _read(FoundDevice device) async {
    await _scan?.cancel();
    setState(() => _status = 'connessione a ${device.id}');
    try {
      final channel = await _bridge.connect(device.id);
      final client = CommissioningClient(channel);
      final info = await _bridge.readInfo(device.id);
      final outcome = await client.readState();
      setState(() {
        _status = switch (outcome) {
          ReadSucceeded(:final state) =>
            'firmware ${info?.firmwareVersion}: $state',
          ReadFailed(:final reason) => 'lettura fallita: $reason',
        };
      });
      await channel.close();
    } catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ble_bridge')),
      floatingActionButton: FloatingActionButton(
        onPressed: _startScan,
        tooltip: 'Cerca centraline',
        child: const Icon(Icons.bluetooth_searching),
      ),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(_status)),
          Expanded(
            child: ListView(
              children: [
                for (final device in _found.values)
                  ListTile(
                    title: Text(device.name ?? device.id),
                    subtitle: Text('${device.id} · ${device.rssi} dBm'),
                    onTap: () => _read(device),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
