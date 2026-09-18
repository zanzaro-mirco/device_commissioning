import 'dart:async';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:flutter/services.dart';

import 'ble_api.g.dart' as api;
import 'ble_frame_channel.dart';

class FoundDevice {
  const FoundDevice({required this.id, required this.rssi, this.name});

  /// Su Android è l'indirizzo MAC.
  final String id;
  final String? name;
  final int rssi;
}

/// L'ingresso del plugin: stato del Bluetooth, permessi, scansione e
/// connessione. Una connessione riuscita restituisce un [BleFrameChannel], con
/// cui si costruisce un [CommissioningClient].
class BleBridge {
  BleBridge({api.BleHostApi? host, Stream<api.BleEvent>? events})
    : _host = host ?? api.BleHostApi(),
      _events = (events ?? api.events()).asBroadcastStream();

  final api.BleHostApi _host;
  final Stream<api.BleEvent> _events;

  Future<api.AdapterState> adapterState() => _host.adapterState();

  Future<api.PermissionState> requestPermissions() =>
      _host.requestPermissions();

  /// Scansiona finché qualcuno ascolta. Filtrata sul servizio della
  /// centralina dal chip Bluetooth, non qui.
  Stream<FoundDevice> scan() {
    late final StreamController<FoundDevice> controller;
    StreamSubscription<api.BleEvent>? subscription;
    controller = StreamController<FoundDevice>(
      onListen: () async {
        subscription = _events.listen((event) {
          if (event is api.ScanResultEvent) {
            controller.add(
              FoundDevice(
                id: event.deviceId,
                name: event.name,
                rssi: event.rssi,
              ),
            );
          }
        });
        try {
          await _host.startScan();
        } on PlatformException catch (error, stack) {
          controller.addError(error, stack);
        }
      },
      onCancel: () async {
        await subscription?.cancel();
        await _host.stopScan();
      },
    );
    return controller.stream;
  }

  /// Si collega, scopre i servizi e accende le notifiche. Il canale si
  /// iscrive agli eventi **prima** della connessione: una notifica arrivata
  /// subito dopo l'accensione non va persa.
  Future<BleFrameChannel> connect(String deviceId) async {
    final channel = BleFrameChannel(deviceId, _host, _events);
    try {
      await _host.connect(deviceId);
    } catch (_) {
      await channel.close();
      rethrow;
    }
    return channel;
  }

  Future<DeviceInfo?> readInfo(String deviceId) async {
    final frame = await _host.readInfo(deviceId);
    if (frame.type != MessageType.info) return null;
    return DeviceInfo.decode(frame.payload);
  }
}
