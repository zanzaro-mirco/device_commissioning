import 'dart:async';
import 'dart:typed_data';

import 'channel.dart';
import 'messages.dart';

/// Cosa chiede la centralina a chi la ospita dopo una richiesta: le stesse
/// tre azioni di `dc_action` in `native/dc_core`.
enum FakeDeviceAction { respond, persistThenRespond, persistThenReboot }

class FakeDeviceReply {
  const FakeDeviceReply(this.action, this.response);

  final FakeDeviceAction action;

  /// Null quando la centralina si riavvia senza rispondere.
  final Frame? response;
}

/// La centralina in Dart, per provare l'app e il plugin senza hardware.
///
/// Riproduce la logica di `native/dc_core/src/dc_device.c` al livello delle
/// trame già verificate: il CRC qui non esiste, come non esiste per l'app. Che
/// si comporti come quella vera lo dicono gli scenari di
/// `protocol/vectors/scenarios.vec`, eseguiti su tutte e due.
///
/// Lavora sui numeri del filo e non sugli enum dell'app: un modo 3 deve
/// arrivare alla centralina ed essere rifiutato come fuori dai limiti, non
/// fermarsi prima perché l'app non sa rappresentarlo.
class FakeDevice {
  FakeDevice({this.debugCommands = true}) {
    factoryReset();
  }

  bool debugCommands;

  int revision = 0;
  int setpoint = 200;
  int mode = 1;

  int _savedRevision = 0;
  int _savedSetpoint = 200;
  int _savedMode = 1;

  DeviceState get state => DeviceState(
        revision: revision,
        params: Params(setpoint: setpoint, mode: Mode.fromCode(mode)!),
      );

  void factoryReset() {
    revision = 0;
    setpoint = 200;
    mode = Mode.comfort.code;
    persist();
  }

  void persist() {
    _savedRevision = revision;
    _savedSetpoint = setpoint;
    _savedMode = mode;
  }

  /// Dopo un riavvio resta solo ciò che era stato salvato.
  void reboot() {
    revision = _savedRevision;
    setpoint = _savedSetpoint;
    mode = _savedMode;
  }

  FakeDeviceReply handle(Frame request) {
    switch (request.type) {
      case MessageType.getState:
        if (request.payload.isNotEmpty) {
          return _error(request.seq, Status.badPayload);
        }
        final payload = ByteData(StateMessage.size)
          ..setUint8(0, Status.ok.code)
          ..setUint32(1, revision, Endian.little)
          ..setInt16(5, setpoint, Endian.little)
          ..setUint8(7, mode);
        return FakeDeviceReply(
          FakeDeviceAction.respond,
          Frame(MessageType.state, request.seq, payload.buffer.asUint8List()),
        );
      case MessageType.setParams:
      case MessageType.debugApplyThenReboot:
        final debug = request.type == MessageType.debugApplyThenReboot;
        if (debug && !debugCommands) {
          return _error(request.seq, Status.unknownType);
        }
        if (request.payload.length != SetParamsRequest.size) {
          return _error(request.seq, Status.badPayload);
        }
        final data = ByteData.sublistView(request.payload);
        final status = _applySet(
          data.getUint32(0, Endian.little),
          data.getInt16(4, Endian.little),
          data.getUint8(6),
        );
        if (debug && status == Status.ok) {
          return const FakeDeviceReply(
              FakeDeviceAction.persistThenReboot, null);
        }
        return FakeDeviceReply(
          status == Status.ok
              ? FakeDeviceAction.persistThenRespond
              : FakeDeviceAction.respond,
          Frame(
            MessageType.setResult,
            request.seq,
            SetResult(status.code, revision).encode(),
          ),
        );
      default:
        return _error(request.seq, Status.unknownType);
    }
  }

  Status _applySet(int expected, int newSetpoint, int newMode) {
    if (expected == revision) {
      final inRange = newSetpoint >= Params.setpointMin &&
          newSetpoint <= Params.setpointMax &&
          newMode <= Mode.eco.code;
      if (!inRange) return Status.outOfRange;
      setpoint = newSetpoint;
      mode = newMode;
      revision++;
      return Status.ok;
    }
    if (revision > 0 &&
        expected == revision - 1 &&
        newSetpoint == setpoint &&
        newMode == mode) {
      return Status.alreadyApplied;
    }
    return Status.conflict;
  }

  FakeDeviceReply _error(int seq, Status status) => FakeDeviceReply(
        FakeDeviceAction.respond,
        Frame(MessageType.error, seq, [status.code]),
      );
}

/// Una connessione finta verso una [FakeDevice], con i guasti che servono a
/// provare l'app: risposte perse, connessione che cade, telemetria a comando.
/// Come il firmware vero, salva prima di rispondere e, al riavvio della
/// centralina, chiude la connessione.
class FakeFrameChannel implements FrameChannel {
  FakeFrameChannel(
    this.device, {
    this.latency = const Duration(milliseconds: 20),
  });

  final FakeDevice device;
  final Duration latency;

  final _events = StreamController<ChannelEvent>.broadcast();
  bool _open = true;

  /// La prossima risposta non arriva: la centralina ha eseguito, il telefono
  /// non lo sa.
  bool dropNextResponse = false;

  /// La connessione cade dopo che la centralina ha eseguito la prossima
  /// richiesta e prima che la risposta arrivi.
  bool closeBeforeNextResponse = false;

  /// Il prossimo invio fallisce con questo errore, prima di arrivare alla
  /// centralina. Serve a provare come il cliente interpreta ogni errore.
  Object? failNextSend;

  final sent = <Frame>[];

  @override
  bool get isOpen => _open;

  @override
  Stream<ChannelEvent> get events => _events.stream;

  @override
  Future<void> send(Frame frame) async {
    if (!_open) throw const ChannelClosedException();
    final failure = failNextSend;
    if (failure != null) {
      failNextSend = null;
      throw failure;
    }
    sent.add(frame);
    final reply = device.handle(frame);
    switch (reply.action) {
      case FakeDeviceAction.respond:
        break;
      case FakeDeviceAction.persistThenRespond:
        device.persist();
      case FakeDeviceAction.persistThenReboot:
        device.persist();
        device.reboot();
        Timer(latency, close);
        return;
    }
    final response = reply.response!;
    if (closeBeforeNextResponse) {
      closeBeforeNextResponse = false;
      Timer(latency, close);
      return;
    }
    if (dropNextResponse) {
      dropNextResponse = false;
      return;
    }
    Timer(latency, () {
      if (_open) _events.add(FrameArrived(response));
    });
  }

  void emitTelemetry(Telemetry telemetry) {
    if (_open) {
      _events.add(
          FrameArrived(Frame(MessageType.telemetry, 0, telemetry.encode())));
    }
  }

  void emitCorrupted(String reason) {
    if (_open) _events.add(FrameCorrupted(reason));
  }

  void close() {
    if (!_open) return;
    _open = false;
    _events.add(const ChannelClosed());
  }
}
