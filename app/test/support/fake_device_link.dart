import 'dart:async';

import 'package:ble_bridge/ble_bridge.dart';
import 'package:commissioning_app/link/device_link.dart';
import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:commissioning_protocol/testing.dart';

const fakeInfo = DeviceInfo(
  protocolVersion: 1,
  firmwareMajor: 0,
  firmwareMinor: 1,
  firmwarePatch: 0,
);

/// Il Bluetooth finto dell'app: le centraline sono [FakeDevice] di
/// `commissioning_protocol`, e ogni connessione è un [FakeFrameChannel] nuovo
/// verso la stessa centralina, come succede con quella vera dopo un riavvio.
class FakeDeviceLink implements DeviceLink {
  FakeDeviceLink({Map<String, FakeDevice>? devices})
    : devices = devices ?? {'AA:BB:CC:DD:EE:01': FakeDevice()};

  final Map<String, FakeDevice> devices;
  PermissionState permission = PermissionState.granted;
  AdapterState adapter = AdapterState.on;

  /// Il prossimo tentativo di connessione fallisce con questo errore.
  Object? failNextConnect;

  /// Le connessioni aperte, in ordine: l'ultima è quella in uso.
  final channels = <FakeFrameChannel>[];

  FakeFrameChannel get channel => channels.last;

  final _scan = StreamController<FoundDevice>.broadcast();
  int scans = 0;
  bool get scanning => _scan.hasListener;

  void announce(FoundDevice device) => _scan.add(device);

  @override
  Future<AdapterState> adapterState() async => adapter;

  @override
  Future<PermissionState> requestPermissions() async => permission;

  @override
  Stream<FoundDevice> scan() {
    scans++;
    return _scan.stream;
  }

  @override
  Future<DeviceSession> connect(String deviceId) async {
    final failure = failNextConnect;
    if (failure != null) {
      failNextConnect = null;
      throw failure;
    }
    final device = devices[deviceId];
    if (device == null) throw StateError('centralina $deviceId sconosciuta');
    final channel = FakeFrameChannel(device);
    channels.add(channel);
    return _FakeSession(channel);
  }
}

class _FakeSession implements DeviceSession {
  _FakeSession(this._channel);

  final FakeFrameChannel _channel;

  @override
  FrameChannel get channel => _channel;

  @override
  DeviceInfo? get info => fakeInfo;

  @override
  Future<void> close() async => _channel.close();
}
