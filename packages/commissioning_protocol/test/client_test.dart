import 'dart:async';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:commissioning_protocol/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

const _comfort215 = Params(setpoint: 215, mode: Mode.comfort);
const _eco230 = Params(setpoint: 230, mode: Mode.eco);

/// Esegue [body] in un tempo finto e restituisce il suo risultato: le attese
/// di tre secondi passano in un istante, e nessun test dipende da quanto è
/// veloce la macchina che lo esegue.
T _run<T>(Future<T> Function(FakeAsync time) body) {
  return fakeAsync((time) {
    T? result;
    var done = false;
    body(time).then((value) {
      result = value;
      done = true;
    });
    time.elapse(const Duration(seconds: 30));
    expect(done, isTrue,
        reason: 'il test non è terminato: una risposta mai completata?');
    return result as T;
  });
}

void main() {
  group('lettura e scrittura', () {
    test('legge lo stato di fabbrica', () {
      final state = _run((_) async {
        final client = CommissioningClient(FakeFrameChannel(FakeDevice()));
        return (await client.readState() as ReadSucceeded).state;
      });
      expect(state.revision, 0);
      expect(state.params, const Params(setpoint: 200, mode: Mode.comfort));
    });

    test('una scrittura riuscita porta la nuova revisione', () {
      final device = FakeDevice();
      final outcome = _run((_) async {
        final client = CommissioningClient(FakeFrameChannel(device));
        return client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
      });
      expect(outcome, isA<WriteConfirmed>());
      final confirmed = outcome as WriteConfirmed;
      expect(confirmed.alreadyApplied, isFalse);
      expect(
          confirmed.state, const DeviceState(revision: 1, params: _comfort215));
      expect(device.state, confirmed.state);
    });

    test('valori fuori dai limiti: rifiutata, niente scritto', () {
      final device = FakeDevice();
      final outcome = _run((_) async {
        final client = CommissioningClient(FakeFrameChannel(device));
        return client.setParams(
          const SetParamsRequest(
            expectedRevision: 0,
            params: Params(setpoint: 301, mode: Mode.comfort),
          ),
        );
      });
      expect((outcome as WriteRejected).status, Status.outOfRange);
      expect(device.revision, 0);
    });

    test('revisione vecchia: conflitto con la revisione corrente', () {
      final device = FakeDevice();
      final outcome = _run((_) async {
        final client = CommissioningClient(FakeFrameChannel(device));
        await client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
        return client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _eco230),
        );
      });
      expect((outcome as WriteConflict).currentRevision, 1);
      expect(device.state.params, _comfort215);
    });

    test('canale già chiuso: la richiesta non parte', () {
      final outcome = _run((_) async {
        final channel = FakeFrameChannel(FakeDevice())..close();
        final client = CommissioningClient(channel);
        await Future<void>.delayed(Duration.zero);
        return client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
      });
      expect(outcome, isA<WriteNotSent>());
    });
  });

  group('esito incerto', () {
    test(
        'risposta persa: incerto dopo il tempo, e il nuovo tentativo scopre che era arrivata',
        () {
      final device = FakeDevice();
      final (first, retry) = _run((_) async {
        final channel = FakeFrameChannel(device)..dropNextResponse = true;
        final client = CommissioningClient(channel);
        final first = await client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
        final retry = await client.setParams((first as WriteUncertain).request);
        return (first, retry);
      });
      expect(first, isA<WriteUncertain>());
      expect(device.revision, 1, reason: 'la centralina aveva eseguito');
      expect((retry as WriteConfirmed).alreadyApplied, isTrue);
      expect(retry.state, const DeviceState(revision: 1, params: _comfort215));
    });

    test(
        'connessione caduta prima della risposta: incerto subito, non dopo il tempo',
        () {
      final device = FakeDevice();
      late Duration elapsed;
      final outcome = _run((time) async {
        final channel = FakeFrameChannel(device)
          ..closeBeforeNextResponse = true;
        final client = CommissioningClient(channel);
        final started = time.elapsed;
        final outcome = await client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
        elapsed = time.elapsed - started;
        return outcome;
      });
      expect(outcome, isA<WriteUncertain>());
      expect(elapsed, lessThan(const Duration(seconds: 1)));
    });

    test(
        'il criterio 4: applica e riavvia senza rispondere, poi il nuovo tentativo conferma',
        () {
      final device = FakeDevice();
      final (first, retry, read) = _run((_) async {
        final client = CommissioningClient(FakeFrameChannel(device));
        final first = await client.debugApplyThenReboot(
          const SetParamsRequest(expectedRevision: 0, params: _eco230),
        );
        expect(client.isClosed, isTrue,
            reason: 'il riavvio chiude la connessione');

        // Riconnessione: canale nuovo, cliente nuovo, stessa centralina.
        final again = CommissioningClient(FakeFrameChannel(device));
        final retry = await again.setParams((first as WriteUncertain).request);
        final read = await again.readState();
        return (first, retry, read);
      });
      expect(first, isA<WriteUncertain>());
      expect((retry as WriteConfirmed).alreadyApplied, isTrue);
      expect((read as ReadSucceeded).state,
          const DeviceState(revision: 1, params: _eco230));
    });

    test(
        'un nuovo tentativo in ritardo non cancella la modifica di un altro telefono',
        () {
      final device = FakeDevice();
      final (retry, read) = _run((_) async {
        final phone = CommissioningClient(
          FakeFrameChannel(device)..dropNextResponse = true,
        );
        final lost = await phone.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );

        final tablet = CommissioningClient(FakeFrameChannel(device));
        await tablet.setParams(
          const SetParamsRequest(expectedRevision: 1, params: _eco230),
        );

        final retry = await phone.setParams((lost as WriteUncertain).request);
        final read = await phone.readState();
        return (retry, read);
      });
      expect((retry as WriteConflict).currentRevision, 2);
      expect((read as ReadSucceeded).state.params, _eco230);
    });
  });

  group('errori durante l\'invio', () {
    test('un rifiuto certo del trasporto: non spedita, niente scritto', () {
      final device = FakeDevice();
      final outcome = _run((_) async {
        final channel = FakeFrameChannel(device)
          ..failNextSend = const FrameRejectedException('stato ATT 3');
        return CommissioningClient(channel).setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
      });
      expect((outcome as WriteNotSent).reason, 'stato ATT 3');
      expect(device.revision, 0);
    });

    test('un errore qualsiasi del trasporto è incerto, non un rifiuto', () {
      final outcome = _run((_) async {
        final channel = FakeFrameChannel(FakeDevice())
          ..failNextSend = StateError('tempo scaduto nel nativo');
        return CommissioningClient(channel).setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
      });
      expect(outcome, isA<WriteUncertain>());
    });
  });

  group('sequenze', () {
    test(
        'una risposta arrivata dopo il suo tempo non completa la richiesta successiva',
        () {
      final device = FakeDevice();
      final (first, second) = _run((_) async {
        // La centralina risponde dopo 5 secondi, il cliente aspetta 3.
        final channel =
            FakeFrameChannel(device, latency: const Duration(seconds: 5));
        final client = CommissioningClient(channel);
        final first = await client.setParams(
          const SetParamsRequest(expectedRevision: 0, params: _comfort215),
        );
        // La seconda parte a 3 secondi; la risposta alla prima arriva a 5.
        final second = await client.readState();
        return (first, second);
      });
      expect(first, isA<WriteUncertain>());
      // La seconda riceverebbe per errore il SET_RESULT della prima: lo
      // riconoscerebbe come risposta inattesa. Invece va in tempo scaduto
      // anche lei, perché la sua risposta arriva a 8 secondi.
      expect(second, isA<ReadFailed>());
      expect((second as ReadFailed).reason, contains('tempo'));
    });

    test('dopo 255 richieste la sequenza ricomincia da 1 e non usa mai lo 0',
        () {
      final device = FakeDevice();
      final channel = FakeFrameChannel(device);
      final results = _run((_) async {
        final client = CommissioningClient(channel);
        return [for (var i = 0; i < 300; i++) await client.readState()];
      });
      expect(results.whereType<ReadSucceeded>(), hasLength(300));
      final seqs = channel.sent.map((f) => f.seq).toList();
      expect(seqs, isNot(contains(0)));
      expect(seqs.sublist(254, 257), [255, 1, 2]);
    });
  });

  group('notifiche', () {
    test('la telemetria arriva decodificata', () {
      final received = _run((_) async {
        final channel = FakeFrameChannel(FakeDevice());
        final client = CommissioningClient(channel);
        final first = client.telemetry.first;
        channel.emitTelemetry(
            const Telemetry(temperature: -35, uptimeSeconds: 86400));
        return first;
      });
      expect(received.temperature, -35);
      expect(received.uptimeSeconds, 86400);
    });

    test('le trame rovinate finiscono nel registro e non completano niente',
        () {
      final reasons = <String>[];
      final outcome = _run((_) async {
        final channel = FakeFrameChannel(FakeDevice());
        final client = CommissioningClient(channel);
        client.corruptedFrames.listen(reasons.add);
        channel.emitCorrupted('CRC sbagliato');
        return client.readState();
      });
      expect(reasons, ['CRC sbagliato']);
      expect(outcome, isA<ReadSucceeded>());
    });
  });

  test('dispose chiude tutto e completa le attese', () {
    final outcome = _run((_) async {
      final device = FakeDevice();
      final channel =
          FakeFrameChannel(device, latency: const Duration(seconds: 1));
      final client = CommissioningClient(channel);
      final pending = client.setParams(
        const SetParamsRequest(expectedRevision: 0, params: _comfort215),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      unawaited(client.dispose());
      return pending;
    });
    expect(outcome, isA<WriteUncertain>());
  });
}
