import 'dart:async';

import 'package:ble_bridge/ble_bridge.dart';
import 'package:ble_bridge/src/ble_api.g.dart' as api;
import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:commissioning_protocol/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceId = 'AA:BB:CC:DD:EE:01';
const _comfort215 = Params(setpoint: 215, mode: Mode.comfort);

/// Il lato Kotlin finto: riceve le trame come le riceverebbe il plugin vero e
/// risponde con gli eventi che il plugin vero manderebbe, usando la
/// centralina finta del pacchetto del protocollo.
class FakeHost extends api.BleHostApi {
  FakeHost(this.device);

  final FakeDevice device;
  final events = StreamController<api.BleEvent>.broadcast();
  final calls = <String>[];

  /// Il prossimo sendFrame fallisce con questo errore della piattaforma.
  PlatformException? failNextSend;

  PlatformException? failConnect;

  @override
  Future<void> connect(String deviceId) async {
    calls.add('connect $deviceId');
    final failure = failConnect;
    if (failure != null) throw failure;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    calls.add('disconnect $deviceId');
  }

  @override
  Future<void> startScan() async => calls.add('startScan');

  @override
  Future<void> stopScan() async => calls.add('stopScan');

  @override
  Future<void> sendFrame(String deviceId, api.WireFrame frame) async {
    final failure = failNextSend;
    if (failure != null) {
      failNextSend = null;
      throw failure;
    }
    final reply = device.handle(Frame(frame.type, frame.seq, frame.payload));
    if (reply.action != FakeDeviceAction.respond) device.persist();
    final response = reply.response;
    if (response == null) return;
    scheduleMicrotask(
      () => events.add(
        api.FrameEvent(
          deviceId: deviceId,
          source: api.Characteristic.response,
          frame: api.WireFrame(
            type: response.type,
            seq: response.seq,
            payload: response.payload,
          ),
        ),
      ),
    );
  }
}

void main() {
  late FakeDevice device;
  late FakeHost host;
  late BleBridge bridge;

  setUp(() {
    device = FakeDevice();
    host = FakeHost(device);
    bridge = BleBridge(host: host, events: host.events.stream);
  });

  Future<CommissioningClient> connected() async =>
      CommissioningClient(await bridge.connect(_deviceId));

  test('una scrittura attraversa il plugin e torna confermata', () async {
    final client = await connected();
    final outcome = await client.setParams(
      const SetParamsRequest(expectedRevision: 0, params: _comfort215),
    );
    expect(outcome, isA<WriteConfirmed>());
    expect(device.state, const DeviceState(revision: 1, params: _comfort215));
  });

  group('gli errori del Kotlin diventano gli esiti giusti', () {
    Future<WriteOutcome> writeFailing(String code) async {
      final client = await connected();
      host.failNextSend = PlatformException(code: code, message: code);
      return client.setParams(
        const SetParamsRequest(expectedRevision: 0, params: _comfort215),
      );
    }

    test('rifiuto certo: non spedita', () async {
      expect(await writeFailing(BleErrorCodes.rejected), isA<WriteNotSent>());
    });

    test('connessione caduta durante la scrittura: incerta', () async {
      expect(
        await writeFailing(BleErrorCodes.disconnected),
        isA<WriteUncertain>(),
      );
    });

    test('tempo scaduto nel nativo: incerta, non rifiutata', () async {
      expect(await writeFailing(BleErrorCodes.timeout), isA<WriteUncertain>());
    });

    test('errore GATT generico: incerta', () async {
      expect(await writeFailing(BleErrorCodes.gatt), isA<WriteUncertain>());
    });
  });

  test(
    'la disconnessione di un\'altra centralina non chiude questo canale',
    () async {
      final channel = await bridge.connect(_deviceId);
      host.events.add(api.ConnectionEvent(deviceId: 'altro', connected: false));
      await pumpEventQueue();
      expect(channel.isOpen, isTrue);

      host.events.add(
        api.ConnectionEvent(deviceId: _deviceId, connected: false),
      );
      await pumpEventQueue();
      expect(channel.isOpen, isFalse);
    },
  );

  test(
    'una connessione caduta mentre si aspetta la risposta la rende incerta',
    () async {
      final client = await connected();
      // La centralina esegue ma, prima che la risposta arrivi, cade la
      // connessione: il nativo manda l'evento e non la trama.
      host.failNextSend = null;
      final pending = client.setParams(
        const SetParamsRequest(expectedRevision: 0, params: _comfort215),
      );
      host.events.add(
        api.ConnectionEvent(deviceId: _deviceId, connected: false),
      );
      expect(await pending, isA<WriteUncertain>());
    },
  );

  test('le trame rovinate arrivano al registro del cliente', () async {
    final client = await connected();
    final reasons = <String>[];
    client.corruptedFrames.listen(reasons.add);
    host.events.add(
      api.CorruptedFrameEvent(deviceId: _deviceId, reason: 'CRC sbagliato'),
    );
    await pumpEventQueue();
    expect(reasons, ['CRC sbagliato']);
  });

  test(
    'una connessione fallita chiude il canale e rilancia l\'errore',
    () async {
      host.failConnect = PlatformException(code: BleErrorCodes.timeout);
      await expectLater(
        bridge.connect(_deviceId),
        throwsA(isA<PlatformException>()),
      );
      expect(host.calls, ['connect $_deviceId', 'disconnect $_deviceId']);
    },
  );

  test(
    'la scansione parte con il primo ascoltatore e si ferma con l\'ultimo',
    () async {
      final found = <FoundDevice>[];
      final subscription = bridge.scan().listen(found.add);
      await pumpEventQueue();
      host.events.add(api.ScanResultEvent(deviceId: _deviceId, rssi: -60));
      await pumpEventQueue();
      await subscription.cancel();
      expect(found.single.id, _deviceId);
      expect(host.calls, ['startScan', 'stopScan']);
    },
  );
}
