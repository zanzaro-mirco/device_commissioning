import 'package:commissioning_app/device/device_cubit.dart';
import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:commissioning_protocol/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_link.dart';

const _id = 'AA:BB:CC:DD:EE:01';
const _factory = Params(setpoint: 200, mode: Mode.comfort);
const _comfort215 = Params(setpoint: 215, mode: Mode.comfort);
const _eco180 = Params(setpoint: 180, mode: Mode.eco);

/// Una prova in tempo finto: le attese di tre secondi del cliente passano in
/// un istante, e nessun test dipende dalla velocità della macchina.
void _run(void Function(FakeAsync time) body) => fakeAsync(body);

extension on FakeAsync {
  /// Lascia finire quello che è partito: risposte, scadenze, riconnessioni.
  void settle() => elapse(const Duration(seconds: 10));
}

void main() {
  late FakeDeviceLink link;
  late FakeDevice device;

  setUp(() {
    link = FakeDeviceLink();
    device = link.devices[_id]!;
  });

  DeviceCubit connected(FakeAsync time) {
    final cubit = DeviceCubit(link, deviceId: _id)..connect();
    time.settle();
    return cubit;
  }

  group('collegamento', () {
    test('si collega, legge le informazioni e lo stato', () {
      _run((time) {
        final cubit = connected(time);
        expect(cubit.state.link, LinkStatus.connected);
        expect(cubit.state.info, fakeInfo);
        expect(
          cubit.state.confirmed,
          const DeviceState(revision: 0, params: _factory),
        );
        expect(cubit.state.canWrite, isTrue);
      });
    });

    test('un collegamento fallito si segnala e si può ritentare', () {
      _run((time) {
        link.failNextConnect = Exception('centralina fuori portata');
        final cubit = connected(time);
        expect(cubit.state.link, LinkStatus.disconnected);
        expect(cubit.state.notice?.kind, NoticeKind.connectFailed);

        cubit.connect();
        time.settle();
        expect(cubit.state.link, LinkStatus.connected);
      });
    });

    test('la telemetria arriva per notifica', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.emitTelemetry(
          const Telemetry(temperature: 187, uptimeSeconds: 42),
        );
        time.flushMicrotasks();
        expect(cubit.state.telemetry?.temperature, 187);
      });
    });

    test(
      'la connessione caduta toglie la telemetria e blocca le scritture',
      () {
        _run((time) {
          final cubit = connected(time);
          link.channel.emitTelemetry(
            const Telemetry(temperature: 187, uptimeSeconds: 42),
          );
          link.channel.close();
          time.settle();
          expect(cubit.state.link, LinkStatus.disconnected);
          expect(cubit.state.telemetry, isNull);
          expect(cubit.state.canWrite, isFalse);
        });
      },
    );

    // In tempo vero: la chiusura aspetta la cancellazione delle iscrizioni, e
    // quel futuro appartiene alla zona radice di Dart, che il tempo finto non
    // fa avanzare.
    test('chiudere il cubit chiude la connessione', () async {
      final cubit = DeviceCubit(link, deviceId: _id);
      await cubit.connect();
      expect(link.channel.isOpen, isTrue);
      await cubit.close();
      expect(link.channel.isOpen, isFalse);
    });
  });

  group('scritture con esito certo', () {
    test('confermata: lo stato mostrato è quello della centralina', () {
      _run((time) {
        final cubit = connected(time);
        cubit.apply(_comfort215);
        time.settle();
        expect(
          cubit.state.confirmed,
          const DeviceState(revision: 1, params: _comfort215),
        );
        expect(device.state, cubit.state.confirmed);
        expect(cubit.state.notice?.kind, NoticeKind.saved);
      });
    });

    test('conflitto: niente scritto, e lo stato si rilegge', () {
      _run((time) {
        final cubit = connected(time);
        // Un altro telefono cambia i parametri dopo la nostra lettura.
        device
          ..setpoint = 230
          ..mode = Mode.eco.code
          ..revision = 1
          ..persist();

        cubit.apply(_comfort215);
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.conflict);
        expect(cubit.state.confirmed, device.state);
        expect(device.revision, 1);
      });
    });

    test('rifiutata: valori fuori dai limiti, niente scritto', () {
      _run((time) {
        final cubit = connected(time);
        cubit.apply(const Params(setpoint: 400, mode: Mode.comfort));
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.rejected);
        expect(cubit.state.notice?.detail, Status.outOfRange.name);
        expect(cubit.state.uncertain, isNull);
        expect(device.revision, 0);
      });
    });

    test('non partita: niente scritto e nessun dubbio', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.failNextSend = const FrameRejectedException('ATT');
        cubit.apply(_comfort215);
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.notSent);
        expect(cubit.state.uncertain, isNull);
        expect(device.revision, 0);
      });
    });
  });

  group('esito incerto', () {
    test('risposta persa: il valore non confermato non si mostra', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.dropNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();

        // La centralina ha applicato, ma l'app non lo sa.
        expect(device.revision, 1);
        expect(cubit.state.notice?.kind, NoticeKind.uncertain);
        expect(cubit.state.uncertain?.params, _comfort215);
        expect(
          cubit.state.confirmed,
          const DeviceState(revision: 0, params: _factory),
        );
        expect(cubit.state.canWrite, isFalse);
      });
    });

    test('il nuovo tentativo conferma senza applicare due volte', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.dropNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();

        cubit.resolveUncertain();
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.alreadyApplied);
        expect(cubit.state.uncertain, isNull);
        expect(
          cubit.state.confirmed,
          const DeviceState(revision: 1, params: _comfort215),
        );
        expect(device.revision, 1, reason: 'applicata una volta sola');
      });
    });

    test(
      'se la prima volta non era arrivata, il nuovo tentativo la applica',
      () {
        _run((time) {
          final cubit = connected(time);
          // Un errore d'invio che non dà certezze: i byte forse sono partiti.
          link.channel.failNextSend = Exception('errore del sistema Bluetooth');
          cubit.apply(_comfort215);
          time.settle();
          expect(cubit.state.uncertain, isNotNull);
          expect(device.revision, 0);

          cubit.resolveUncertain();
          time.settle();
          expect(cubit.state.notice?.kind, NoticeKind.saved);
          expect(
            device.state,
            const DeviceState(revision: 1, params: _comfort215),
          );
        });
      },
    );

    test(
      'guasto con riavvio (criterio 4): si ricollega e conferma una volta',
      () {
        _run((time) {
          final cubit = connected(time);
          cubit.applyThenReboot(_comfort215);
          time.settle();

          expect(cubit.state.link, LinkStatus.disconnected);
          expect(cubit.state.uncertain?.params, _comfort215);
          expect(cubit.state.confirmed?.params, _factory);
          // La modifica è sulla flash della centralina, riavviata.
          expect(
            device.state,
            const DeviceState(revision: 1, params: _comfort215),
          );

          cubit.resolveUncertain();
          time.settle();
          expect(link.channels, hasLength(2));
          expect(cubit.state.link, LinkStatus.connected);
          expect(cubit.state.notice?.kind, NoticeKind.alreadyApplied);
          expect(
            cubit.state.confirmed,
            const DeviceState(revision: 1, params: _comfort215),
          );
          expect(device.revision, 1, reason: 'applicata una volta sola');

          // Il nuovo tentativo è la stessa richiesta, non una costruita sulla
          // revisione riletta.
          final retry = link.channel.sent.single;
          expect(retry.type, MessageType.setParams);
          expect(
            SetParamsRequest.decode(retry.payload),
            const SetParamsRequest(expectedRevision: 0, params: _comfort215),
          );
        });
      },
    );

    test('la riconnessione risolve da sola il dubbio in sospeso', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.closeBeforeNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();
        expect(cubit.state.link, LinkStatus.disconnected);
        expect(cubit.state.uncertain, isNotNull);

        cubit.connect();
        time.settle();
        expect(cubit.state.uncertain, isNull);
        expect(cubit.state.notice?.kind, NoticeKind.alreadyApplied);
        expect(device.revision, 1);
      });
    });

    test('se nel frattempo un altro ha cambiato i parametri: conflitto', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.dropNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();
        // Un altro telefono scrive sopra la nostra modifica.
        device
          ..setpoint = _eco180.setpoint
          ..mode = _eco180.mode.code
          ..revision = 2
          ..persist();

        cubit.resolveUncertain();
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.conflict);
        expect(cubit.state.uncertain, isNull);
        expect(
          cubit.state.confirmed,
          const DeviceState(revision: 2, params: _eco180),
        );
        expect(device.revision, 2, reason: 'il tentativo non ha scritto');
      });
    });

    test('un nuovo tentativo non partito lascia il dubbio', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.dropNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();

        link.channel.failNextSend = const FrameRejectedException('ATT');
        cubit.resolveUncertain();
        time.settle();
        expect(cubit.state.notice?.kind, NoticeKind.notSent);
        expect(cubit.state.uncertain?.params, _comfort215);
      });
    });

    test('finché il dubbio resta, le scritture nuove non partono', () {
      _run((time) {
        final cubit = connected(time);
        link.channel.dropNextResponse = true;
        cubit.apply(_comfort215);
        time.settle();
        final sent = link.channel.sent.length;

        cubit.apply(_eco180);
        time.settle();
        expect(link.channel.sent, hasLength(sent));
      });
    });
  });
}
