// Il contratto fra il Dart del plugin e il Kotlin (poi lo Swift). Il codice
// dei due lati si genera da qui:
//
//   dart run pigeon --input pigeons/ble_api.dart
//
// Tipizzato invece di un MethodChannel con mappe di stringhe: un campo
// rinominato da una parte sola fa fallire la compilazione, non l'app sul
// telefono dell'installatore.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/ble_api.g.dart',
    dartPackageName: 'ble_bridge',
    kotlinOut: 'android/src/main/kotlin/it/mircozanzaro/ble_bridge/BleApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'it.mircozanzaro.ble_bridge'),
  ),
)
enum AdapterState { on, off, unavailable, unauthorized }

enum PermissionState { granted, denied, permanentlyDenied }

/// La caratteristica da cui è arrivata una trama.
enum Characteristic { response, telemetry }

/// Una trama già verificata dal C: tipo, sequenza e contenuto. CRC e versione
/// non attraversano il canale.
class WireFrame {
  WireFrame({required this.type, required this.seq, required this.payload});

  int type;
  int seq;
  Uint8List payload;
}

sealed class BleEvent {}

class ScanResultEvent extends BleEvent {
  ScanResultEvent({required this.deviceId, required this.rssi, this.name});

  String deviceId;
  String? name;
  int rssi;
}

class ConnectionEvent extends BleEvent {
  ConnectionEvent({
    required this.deviceId,
    required this.connected,
    this.reason,
  });

  String deviceId;
  bool connected;
  String? reason;
}

class FrameEvent extends BleEvent {
  FrameEvent({
    required this.deviceId,
    required this.source,
    required this.frame,
  });

  String deviceId;
  Characteristic source;
  WireFrame frame;
}

class CorruptedFrameEvent extends BleEvent {
  CorruptedFrameEvent({required this.deviceId, required this.reason});

  String deviceId;
  String reason;
}

@HostApi()
abstract class BleHostApi {
  AdapterState adapterState();

  /// Su Android 12 e successivi chiede BLUETOOTH_SCAN e BLUETOOTH_CONNECT.
  @async
  PermissionState requestPermissions();

  /// I risultati arrivano come [ScanResultEvent], filtrati sul servizio
  /// della centralina.
  void startScan();

  void stopScan();

  /// Completa quando i servizi sono stati scoperti e le notifiche abilitate:
  /// da lì in poi il canale è pronto.
  @async
  void connect(String deviceId);

  void disconnect(String deviceId);

  /// Legge la caratteristica delle informazioni.
  @async
  WireFrame readInfo(String deviceId);

  /// Codifica la trama nel C e la scrive con risposta sulla caratteristica dei
  /// comandi. Completa quando la centralina ha ricevuto i byte.
  @async
  void sendFrame(String deviceId, WireFrame frame);
}

@EventChannelApi()
abstract class BleEventsApi {
  BleEvent events();
}
