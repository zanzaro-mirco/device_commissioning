import 'dart:async';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:flutter/services.dart';

import 'ble_api.g.dart' as api;

/// I codici di `BleErrors` in Kotlin.
abstract final class BleErrorCodes {
  static const notConnected = 'not_connected';
  static const disconnected = 'disconnected';
  static const rejected = 'rejected';
  static const timeout = 'timeout';
  static const permission = 'permission';
  static const unavailable = 'unavailable';
  static const gatt = 'gatt_error';
}

/// Il [FrameChannel] del protocollo sopra il GATT di una centralina. Vale una
/// connessione: dopo la chiusura non si riapre, se ne crea un altro.
class BleFrameChannel implements FrameChannel {
  BleFrameChannel(this.deviceId, this._host, Stream<api.BleEvent> events) {
    _subscription = events.listen(_onEvent);
  }

  final String deviceId;
  final api.BleHostApi _host;
  late final StreamSubscription<api.BleEvent> _subscription;
  final _events = StreamController<ChannelEvent>.broadcast();
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Stream<ChannelEvent> get events => _events.stream;

  @override
  Future<void> send(Frame frame) async {
    if (!_open) throw const ChannelClosedException();
    try {
      await _host.sendFrame(
        deviceId,
        api.WireFrame(type: frame.type, seq: frame.seq, payload: frame.payload),
      );
    } on PlatformException catch (error) {
      throw switch (error.code) {
        // Rifiuto certo: dal sistema prima di partire, o dalla centralina a
        // livello ATT. È l'unico caso in cui il protocollo può dire «non
        // spedita».
        BleErrorCodes.rejected => FrameRejectedException(
          error.message ?? error.code,
        ),
        BleErrorCodes.disconnected ||
        BleErrorCodes.notConnected => const ChannelClosedException(),
        // Tempo scaduto e tutto il resto: l'esito resta sconosciuto, e il
        // cliente lo tratta come incerto.
        _ => error,
      };
    }
  }

  /// Chiude la connessione. L'evento di chiusura arriva comunque dal nativo;
  /// qui lo si anticipa, perché chi chiude non deve aspettare il Bluetooth
  /// per sapere che il canale non è più utilizzabile.
  Future<void> close() async {
    _markClosed();
    await _host.disconnect(deviceId);
    await _subscription.cancel();
  }

  void _onEvent(api.BleEvent event) {
    switch (event) {
      case api.FrameEvent(:final deviceId, :final frame)
          when deviceId == this.deviceId:
        if (_open) {
          _events.add(
            FrameArrived(Frame(frame.type, frame.seq, frame.payload)),
          );
        }
      case api.CorruptedFrameEvent(:final deviceId, :final reason)
          when deviceId == this.deviceId:
        if (_open) _events.add(FrameCorrupted(reason));
      case api.ConnectionEvent(:final deviceId, :final connected)
          when deviceId == this.deviceId && !connected:
        _markClosed();
      default:
        break;
    }
  }

  void _markClosed() {
    if (!_open) return;
    _open = false;
    _events.add(const ChannelClosed());
  }
}
