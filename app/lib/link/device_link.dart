import 'package:ble_bridge/ble_bridge.dart';
import 'package:commissioning_protocol/commissioning_protocol.dart';

/// Quello che l'app chiede al Bluetooth, e niente di più.
///
/// I cubit parlano con questa interfaccia e non con il plugin: nei test c'è
/// una versione appoggiata alla centralina finta di `commissioning_protocol`,
/// e l'app gira intera senza hardware e senza canali di piattaforma.
abstract interface class DeviceLink {
  Future<AdapterState> adapterState();

  Future<PermissionState> requestPermissions();

  /// Le centraline nei dintorni, finché qualcuno ascolta.
  Stream<FoundDevice> scan();

  /// Si collega e legge le informazioni del dispositivo. Se una delle due cose
  /// fallisce, la connessione è già chiusa quando arriva l'errore.
  Future<DeviceSession> connect(String deviceId);
}

/// Una connessione aperta. Vale finché il suo canale non si chiude: poi se ne
/// apre un'altra.
abstract interface class DeviceSession {
  FrameChannel get channel;

  /// Null se la centralina ha risposto con qualcosa che non è una trama INFO.
  DeviceInfo? get info;

  Future<void> close();
}

/// La versione vera, sopra il plugin.
class BleDeviceLink implements DeviceLink {
  BleDeviceLink([BleBridge? bridge]) : _bridge = bridge ?? BleBridge();

  final BleBridge _bridge;

  @override
  Future<AdapterState> adapterState() => _bridge.adapterState();

  @override
  Future<PermissionState> requestPermissions() => _bridge.requestPermissions();

  @override
  Stream<FoundDevice> scan() => _bridge.scan();

  @override
  Future<DeviceSession> connect(String deviceId) async {
    final channel = await _bridge.connect(deviceId);
    try {
      final info = await _bridge.readInfo(deviceId);
      return _BleSession(channel, info);
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }
}

class _BleSession implements DeviceSession {
  _BleSession(this._channel, this.info);

  final BleFrameChannel _channel;

  @override
  final DeviceInfo? info;

  @override
  FrameChannel get channel => _channel;

  @override
  Future<void> close() => _channel.close();
}
