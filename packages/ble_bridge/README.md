# ble_bridge

Il plugin Bluetooth LE della messa in servizio: scansione filtrata sul servizio della
centralina, connessione, notifiche, e un `FrameChannel` su cui gira il `CommissioningClient`
di `commissioning_protocol`.

- Il contratto fra Dart e Kotlin è in [`pigeons/ble_api.dart`](pigeons/ble_api.dart) e si
  rigenera con `dart run pigeon --input pigeons/ble_api.dart`.
- La trama e il CRC sono il C di [`native/dc_core`](../../native/dc_core), lo stesso del
  firmware, chiamato via JNI.
- Oggi solo Android. Il lato Swift (iOS e macOS) è la voce 5 del piano.

Le scelte sono spiegate in [`ARCHITECTURE.md`](../../ARCHITECTURE.md) nella radice del
repository.
