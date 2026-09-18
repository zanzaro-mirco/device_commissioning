import 'package:ble_bridge/ble_bridge.dart';
import 'package:commissioning_app/app.dart';
import 'package:commissioning_app/device/device_cubit.dart';
import 'package:commissioning_app/device/device_page.dart';
import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_device_link.dart';

const _id = 'AA:BB:CC:DD:EE:01';

void main() {
  late FakeDeviceLink link;

  setUp(() => link = FakeDeviceLink());

  Future<void> showDevice(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) =>
              DeviceCubit(link, deviceId: _id, name: 'DC-EE01')..connect(),
          child: const DevicePage(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('mostra lo stato confermato e la telemetria', (tester) async {
    await showDevice(tester);
    link.channel.emitTelemetry(
      const Telemetry(temperature: 187, uptimeSeconds: 3700),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Collegata'), findsOneWidget);
    expect(find.text('Firmware 0.1.0 · protocollo 1'), findsOneWidget);
    expect(find.text('20,0 °C, comfort'), findsOneWidget);
    expect(find.text('18,7 °C'), findsOneWidget);
    expect(find.text('Accesa da 1 h 1 min'), findsOneWidget);
  });

  testWidgets('una modifica si applica e si conferma', (tester) async {
    await showDevice(tester);
    await tester.tap(find.byTooltip('Alza di mezzo grado'));
    await tester.pump();
    await tester.tap(find.text('Applica'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('20,5 °C, comfort'), findsOneWidget);
    expect(find.text('Salvato sulla centralina.'), findsOneWidget);
    expect(link.devices[_id]!.setpoint, 205);
  });

  testWidgets(
    'esito incerto: il valore mai confermato non diventa quello corrente',
    (tester) async {
      await showDevice(tester);
      link.channel.dropNextResponse = true;
      await tester.tap(find.byTooltip('Alza di mezzo grado'));
      await tester.pump();
      await tester.tap(find.text('Applica'));
      await tester.pump(const Duration(seconds: 5));

      expect(find.text('Modifica non confermata'), findsOneWidget);
      expect(find.textContaining('impostare 20,5 °C, comfort'), findsOneWidget);
      // Il valore confermato resta quello di prima, e non si può scrivere.
      expect(find.text('20,0 °C, comfort'), findsOneWidget);
      expect(find.text('20,5 °C, comfort'), findsNothing);
      final apply = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Applica'),
      );
      expect(apply.onPressed, isNull);

      await tester.tap(find.text('Verifica'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Modifica non confermata'), findsNothing);
      expect(find.text('20,5 °C, comfort'), findsOneWidget);
      expect(
        find.text(
          'La modifica era già arrivata: confermata, senza applicarla due volte.',
        ),
        findsOneWidget,
      );
      expect(link.devices[_id]!.revision, 1);
    },
  );

  testWidgets('permesso negato per sempre: rimanda alle impostazioni', (
    tester,
  ) async {
    link.permission = PermissionState.permanentlyDenied;
    await tester.pumpWidget(CommissioningApp(link: link));
    await tester.tap(find.text('Cerca'));
    await tester.pump();

    expect(find.textContaining('impostazioni di sistema'), findsOneWidget);
  });
}
