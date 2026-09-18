import 'dart:typed_data';

/// Una trama già verificata dal plugin nativo: il CRC e la versione sono
/// rimasti nel C, qui arrivano solo tipo, sequenza e contenuto.
class Frame {
  Frame(this.type, this.seq, List<int> payload)
      : payload = Uint8List.fromList(payload);

  final int type;
  final int seq;
  final Uint8List payload;

  @override
  String toString() => 'Frame(type: 0x${type.toRadixString(16)}, seq: $seq, '
      'payload: ${payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join()})';
}

abstract final class MessageType {
  static const getState = 0x01;
  static const setParams = 0x02;
  static const debugApplyThenReboot = 0x7F;
  static const telemetry = 0x40;
  static const info = 0x41;
  static const state = 0x81;
  static const setResult = 0x82;
  static const error = 0xFF;
}

enum Status {
  ok(0),
  alreadyApplied(1),
  conflict(2),
  outOfRange(3),
  badFrame(4),
  unsupportedVersion(5),
  unknownType(6),
  badPayload(7);

  const Status(this.code);

  final int code;

  /// Un codice che questa versione dell'app non conosce non si trasforma in
  /// un codice vicino: resta null, e chi legge decide cosa farne.
  static Status? fromCode(int code) {
    for (final status in values) {
      if (status.code == code) return status;
    }
    return null;
  }
}

enum Mode {
  off(0),
  comfort(1),
  eco(2);

  const Mode(this.code);

  final int code;

  static Mode? fromCode(int code) {
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return null;
  }
}

/// I parametri della centralina. Le temperature sono in decimi di grado,
/// come sul filo: 215 vale 21,5 °C. La conversione in gradi la fa
/// l'interfaccia, così nessun arrotondamento entra nel protocollo.
class Params {
  const Params({required this.setpoint, required this.mode});

  static const setpointMin = 50;
  static const setpointMax = 300;

  final int setpoint;
  final Mode mode;

  bool get inRange => setpoint >= setpointMin && setpoint <= setpointMax;

  @override
  bool operator ==(Object other) =>
      other is Params && other.setpoint == setpoint && other.mode == mode;

  @override
  int get hashCode => Object.hash(setpoint, mode);

  @override
  String toString() => 'Params($setpoint, ${mode.name})';
}

class SetParamsRequest {
  const SetParamsRequest({
    required this.expectedRevision,
    required this.params,
  });

  final int expectedRevision;
  final Params params;

  static const size = 7;

  Uint8List encode() {
    final data = ByteData(size)
      ..setUint32(0, expectedRevision, Endian.little)
      ..setInt16(4, params.setpoint, Endian.little)
      ..setUint8(6, params.mode.code);
    return data.buffer.asUint8List();
  }

  static SetParamsRequest? decode(Uint8List payload) {
    if (payload.length != size) return null;
    final data = ByteData.sublistView(payload);
    final mode = Mode.fromCode(data.getUint8(6));
    // Un modo sconosciuto non è decodificabile come richiesta dell'app. La
    // centralina, che lavora sui byte, lo rifiuta come fuori dai limiti.
    if (mode == null) return null;
    return SetParamsRequest(
      expectedRevision: data.getUint32(0, Endian.little),
      params: Params(setpoint: data.getInt16(4, Endian.little), mode: mode),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SetParamsRequest &&
      other.expectedRevision == expectedRevision &&
      other.params == params;

  @override
  int get hashCode => Object.hash(expectedRevision, params);
}

/// La risposta a GET_STATE. Lo stato letto porta sempre la sua revisione,
/// che è la base della prossima scrittura.
class DeviceState {
  const DeviceState({required this.revision, required this.params});

  final int revision;
  final Params params;

  @override
  bool operator ==(Object other) =>
      other is DeviceState &&
      other.revision == revision &&
      other.params == params;

  @override
  int get hashCode => Object.hash(revision, params);

  @override
  String toString() => 'DeviceState(r$revision, $params)';
}

class StateMessage {
  const StateMessage(this.status, this.state);

  final int status;
  final DeviceState state;

  static const size = 8;

  Uint8List encode() {
    final data = ByteData(size)
      ..setUint8(0, status)
      ..setUint32(1, state.revision, Endian.little)
      ..setInt16(5, state.params.setpoint, Endian.little)
      ..setUint8(7, state.params.mode.code);
    return data.buffer.asUint8List();
  }

  static StateMessage? decode(Uint8List payload) {
    if (payload.length != size) return null;
    final data = ByteData.sublistView(payload);
    final mode = Mode.fromCode(data.getUint8(7));
    if (mode == null) return null;
    return StateMessage(
      data.getUint8(0),
      DeviceState(
        revision: data.getUint32(1, Endian.little),
        params: Params(setpoint: data.getInt16(5, Endian.little), mode: mode),
      ),
    );
  }
}

class SetResult {
  const SetResult(this.status, this.revision);

  final int status;
  final int revision;

  static const size = 5;

  Uint8List encode() {
    final data = ByteData(size)
      ..setUint8(0, status)
      ..setUint32(1, revision, Endian.little);
    return data.buffer.asUint8List();
  }

  static SetResult? decode(Uint8List payload) {
    if (payload.length != size) return null;
    final data = ByteData.sublistView(payload);
    return SetResult(data.getUint8(0), data.getUint32(1, Endian.little));
  }
}

class Telemetry {
  const Telemetry({required this.temperature, required this.uptimeSeconds});

  /// Decimi di grado.
  final int temperature;
  final int uptimeSeconds;

  static const size = 6;

  Uint8List encode() {
    final data = ByteData(size)
      ..setInt16(0, temperature, Endian.little)
      ..setUint32(2, uptimeSeconds, Endian.little);
    return data.buffer.asUint8List();
  }

  static Telemetry? decode(Uint8List payload) {
    if (payload.length != size) return null;
    final data = ByteData.sublistView(payload);
    return Telemetry(
      temperature: data.getInt16(0, Endian.little),
      uptimeSeconds: data.getUint32(2, Endian.little),
    );
  }
}

class DeviceInfo {
  const DeviceInfo({
    required this.protocolVersion,
    required this.firmwareMajor,
    required this.firmwareMinor,
    required this.firmwarePatch,
  });

  final int protocolVersion;
  final int firmwareMajor;
  final int firmwareMinor;
  final int firmwarePatch;

  String get firmwareVersion => '$firmwareMajor.$firmwareMinor.$firmwarePatch';

  static const size = 4;

  Uint8List encode() => Uint8List.fromList(
        [protocolVersion, firmwareMajor, firmwareMinor, firmwarePatch],
      );

  static DeviceInfo? decode(Uint8List payload) {
    if (payload.length != size) return null;
    return DeviceInfo(
      protocolVersion: payload[0],
      firmwareMajor: payload[1],
      firmwareMinor: payload[2],
      firmwarePatch: payload[3],
    );
  }
}
