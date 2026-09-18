import 'dart:typed_data';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:commissioning_protocol/testing.dart';
import 'package:test/test.dart';

import 'vectors.dart';

/// Gli scenari di `protocol/vectors/scenarios.vec` eseguiti sulla centralina
/// finta. Gli stessi scenari girano in C sulla logica del firmware: se la
/// finta si comporta diversamente dalla vera, fallisce qui.
void main() {
  final scenarios = <String, List<VecLine>>{};
  String? current;
  for (final line in readVectors('scenarios.vec')) {
    if (line.kind == 'scenario') {
      current = line.require('name');
      scenarios[current] = [];
    } else if (line.kind == 'end') {
      current = null;
    } else {
      scenarios[current]!.add(line);
    }
  }

  test('gli scenari ci sono tutti', () {
    expect(scenarios.length, greaterThanOrEqualTo(10));
  });

  for (final MapEntry(key: name, value: steps) in scenarios.entries) {
    test('scenario $name', () {
      final device = FakeDevice();
      var seq = 0;
      for (final step in steps) {
        final arrow = step.arrow;
        Frame? request;
        switch (step.kind) {
          case 'factory':
            device
              ..factoryReset()
              ..debugCommands = true;
          case 'config':
            device.debugCommands = step.require('debug') == 'on';
          case 'reboot':
            device.reboot();
          case 'request':
            final type = switch (step.tokens[1]) {
              'GET_STATE' => MessageType.getState,
              'SET_PARAMS' => MessageType.setParams,
              'DEBUG_APPLY_THEN_REBOOT' => MessageType.debugApplyThenReboot,
              final other => throw StateError('richiesta sconosciuta $other'),
            };
            // I byte si scrivono a mano e non con SetParamsRequest: uno
            // scenario può chiedere un modo che l'app non sa rappresentare.
            final payload = type == MessageType.getState
                ? Uint8List(0)
                : (ByteData(7)
                      ..setUint32(
                          0,
                          step.integer('expected_revision', 2, arrow),
                          Endian.little)
                      ..setInt16(
                          4, step.integer('setpoint', 2, arrow), Endian.little)
                      ..setUint8(6, step.integer('mode', 2, arrow)))
                    .buffer
                    .asUint8List();
            request = Frame(type, ++seq, payload);
          case 'send':
            request = Frame(
              int.parse(step.require('type', 1, arrow), radix: 16),
              ++seq,
              hex(step.require('payload', 1, arrow)),
            );
          case 'raw':
            // Trame intere con il CRC: in Dart il CRC non esiste, le prova il C.
            break;
          default:
            fail('passo sconosciuto: $step');
        }
        if (request != null) _exchange(device, request, step);
      }
    });
  }

  test('i passi saltati sono solo le due trame intere', () {
    final raw =
        scenarios.values.expand((steps) => steps).where((s) => s.kind == 'raw');
    expect(raw.length, 2);
  });
}

void _exchange(FakeDevice device, Frame request, VecLine step) {
  final before = device.state;
  final reply = device.handle(request);
  if (reply.action == FakeDeviceAction.respond) {
    expect(device.state, before,
        reason: '$step: lo stato è cambiato senza chiedere di salvarlo');
  } else {
    device.persist();
  }

  final expected = step.tokens[step.arrow + 1];
  if (expected == 'REBOOT') {
    expect(reply.action, FakeDeviceAction.persistThenReboot, reason: '$step');
    expect(reply.response, isNull, reason: '$step');
    return;
  }
  expect(reply.action, isNot(FakeDeviceAction.persistThenReboot),
      reason: '$step');

  final response = reply.response!;
  final from = step.arrow + 2;
  expect(response.seq, request.seq, reason: '$step: sequenza');
  expect(
    response.type,
    switch (expected) {
      'STATE' => MessageType.state,
      'SET_RESULT' => MessageType.setResult,
      'ERROR' => MessageType.error,
      _ => -1,
    },
    reason: '$step: tipo della risposta',
  );
  final status = step.get('status', from);
  if (status != null) {
    expect(
      Status.fromCode(response.payload[0])?.name,
      _camel(status),
      reason: '$step: stato',
    );
  }
  if (response.type == MessageType.state) {
    final state = StateMessage.decode(response.payload)!.state;
    expect(state.revision, step.integer('revision', from), reason: '$step');
    expect(state.params.setpoint, step.integer('setpoint', from),
        reason: '$step');
    expect(state.params.mode.code, step.integer('mode', from), reason: '$step');
  } else if (response.type == MessageType.setResult) {
    expect(SetResult.decode(response.payload)!.revision,
        step.integer('revision', from),
        reason: '$step');
  }
}

/// ALREADY_APPLIED -> alreadyApplied, come i nomi dell'enum.
String _camel(String name) {
  final parts = name.toLowerCase().split('_');
  return parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
}
