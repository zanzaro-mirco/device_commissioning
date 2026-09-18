import 'dart:typed_data';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:test/test.dart';

import 'vectors.dart';

void main() {
  final lines = readVectors('messages.vec');

  test('il file dei vettori dei messaggi non è vuoto', () {
    expect(lines.length, greaterThanOrEqualTo(9));
  });

  for (final line in lines) {
    final name = line.require('name');
    final type = int.parse(line.require('type'), radix: 16);
    final payload = hex(line.require('payload'));

    test('messaggio $name: codifica e decodifica coincidono con il vettore',
        () {
      final (Uint8List encoded, Object? decoded, Object expected) =
          switch (type) {
        MessageType.getState => (Uint8List(0), null, 'vuoto'),
        MessageType.setParams || MessageType.debugApplyThenReboot => () {
            final message = SetParamsRequest(
              expectedRevision: line.integer('expected_revision'),
              params: Params(
                setpoint: line.integer('setpoint'),
                mode: Mode.fromCode(line.integer('mode'))!,
              ),
            );
            return (
              message.encode(),
              SetParamsRequest.decode(payload),
              message
            );
          }(),
        MessageType.state => () {
            final message = StateMessage(
              line.integer('status'),
              DeviceState(
                revision: line.integer('revision'),
                params: Params(
                  setpoint: line.integer('setpoint'),
                  mode: Mode.fromCode(line.integer('mode'))!,
                ),
              ),
            );
            return (
              message.encode(),
              StateMessage.decode(payload)?.state,
              message.state,
            );
          }(),
        MessageType.setResult => () {
            final message =
                SetResult(line.integer('status'), line.integer('revision'));
            final back = SetResult.decode(payload);
            return (
              message.encode(),
              back == null ? null : (back.status, back.revision),
              (message.status, message.revision),
            );
          }(),
        MessageType.telemetry => () {
            final message = Telemetry(
              temperature: line.integer('temperature'),
              uptimeSeconds: line.integer('uptime_s'),
            );
            final back = Telemetry.decode(payload);
            return (
              message.encode(),
              back == null ? null : (back.temperature, back.uptimeSeconds),
              (message.temperature, message.uptimeSeconds),
            );
          }(),
        MessageType.info => () {
            final message = DeviceInfo(
              protocolVersion: line.integer('protocol_version'),
              firmwareMajor: line.integer('fw_major'),
              firmwareMinor: line.integer('fw_minor'),
              firmwarePatch: line.integer('fw_patch'),
            );
            return (
              message.encode(),
              DeviceInfo.decode(payload)?.firmwareVersion,
              message.firmwareVersion,
            );
          }(),
        MessageType.error => (
            Uint8List.fromList([line.integer('status')]),
            payload.length == 1 ? Status.fromCode(payload[0]) : null,
            Status.fromCode(line.integer('status'))!,
          ),
        _ => throw StateError('tipo 0x${type.toRadixString(16)} senza test'),
      };
      expect(encoded, payload, reason: 'codifica');
      if (type != MessageType.getState) {
        expect(decoded, expected, reason: 'decodifica');
      }
    });
  }

  test('un contenuto della lunghezza sbagliata non si decodifica', () {
    expect(SetParamsRequest.decode(Uint8List(8)), isNull);
    expect(SetParamsRequest.decode(Uint8List(6)), isNull);
    expect(StateMessage.decode(Uint8List(7)), isNull);
    expect(SetResult.decode(Uint8List(4)), isNull);
  });

  test('un modo sconosciuto non diventa un modo vicino', () {
    final payload = const SetParamsRequest(
      expectedRevision: 0,
      params: Params(setpoint: 200, mode: Mode.eco),
    ).encode()
      ..[6] = 3;
    expect(SetParamsRequest.decode(payload), isNull);
    expect(Mode.fromCode(3), isNull);
  });
}
