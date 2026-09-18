import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../format.dart';
import 'device_cubit.dart';

class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<DeviceCubit, DeviceView>(
      listenWhen: (previous, current) => previous.notice != current.notice,
      listener: (context, view) {
        final notice = view.notice;
        if (notice == null) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(noticeText(notice))));
      },
      builder: (context, view) {
        final cubit = context.read<DeviceCubit>();
        final confirmed = view.confirmed;
        final uncertain = view.uncertain;
        return Scaffold(
          appBar: AppBar(title: Text(view.name ?? view.deviceId)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _LinkCard(view: view, onReconnect: cubit.connect),
              if (uncertain != null)
                _UncertainCard(
                  request: uncertain,
                  busy: view.busy,
                  onResolve: cubit.resolveUncertain,
                ),
              _TelemetryCard(telemetry: view.telemetry),
              if (confirmed != null) ...[
                _ConfirmedCard(
                  state: confirmed,
                  stale: view.link != LinkStatus.connected,
                ),
                _ParamsEditor(
                  // Una nuova conferma riparte dai valori confermati.
                  key: ValueKey(confirmed),
                  initial: confirmed.params,
                  enabled: view.canWrite,
                  onApply: cubit.apply,
                  // Il comando di guasto esiste solo nel firmware di debug, e
                  // il pulsante solo nell'app di debug.
                  onApplyThenReboot: kDebugMode ? cubit.applyThenReboot : null,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

String noticeText(Notice notice) => switch (notice.kind) {
  NoticeKind.saved => 'Salvato sulla centralina.',
  NoticeKind.alreadyApplied =>
    'La modifica era già arrivata: confermata, senza applicarla due volte.',
  NoticeKind.conflict =>
    'Nel frattempo i parametri sono cambiati da un altro dispositivo. '
        'Niente è stato scritto: ecco i valori attuali.',
  NoticeKind.rejected =>
    'La centralina ha rifiutato la modifica: ${_rejection(notice.detail)}.',
  NoticeKind.notSent => 'La modifica non è partita: niente è stato scritto.',
  NoticeKind.uncertain =>
    'Nessuna conferma dalla centralina: la modifica potrebbe essere arrivata.',
  NoticeKind.readFailed => 'Lettura non riuscita: ${notice.detail}',
  NoticeKind.connectFailed => 'Collegamento non riuscito: ${notice.detail}',
};

/// Il motivo di un rifiuto, dal nome dello stato del protocollo.
String _rejection(String? status) => switch (status) {
  'outOfRange' => 'valori fuori dai limiti',
  'unknownType' => 'comando non supportato da questo firmware',
  'badFrame' => 'trama rovinata durante il trasporto',
  'badPayload' => 'contenuto non valido',
  'unsupportedVersion' => 'versione del protocollo non supportata',
  _ => status ?? 'motivo sconosciuto',
};

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.view, required this.onReconnect});

  final DeviceView view;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final info = view.info;
    final (icon, text) = switch (view.link) {
      LinkStatus.connecting => (Icons.bluetooth_searching, 'Collegamento…'),
      LinkStatus.connected => (Icons.bluetooth_connected, 'Collegata'),
      LinkStatus.disconnected => (Icons.bluetooth_disabled, 'Scollegata'),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(text),
        subtitle: info == null
            ? null
            : Text(
                'Firmware ${info.firmwareVersion} · '
                'protocollo ${info.protocolVersion}',
              ),
        trailing: view.link == LinkStatus.disconnected
            ? TextButton(onPressed: onReconnect, child: const Text('Ricollega'))
            : null,
      ),
    );
  }
}

class _UncertainCard extends StatelessWidget {
  const _UncertainCard({
    required this.request,
    required this.busy,
    required this.onResolve,
  });

  final SetParamsRequest request;
  final bool busy;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Modifica non confermata',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: colors.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Text(
              'La richiesta di impostare ${describeParams(request.params)} è '
              'partita, ma la risposta non è arrivata. Può essere stata '
              'applicata oppure no. Verificando si ripete la stessa richiesta, '
              'che non viene applicata due volte.',
              style: TextStyle(color: colors.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: busy ? null : onResolve,
                child: const Text('Verifica'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TelemetryCard extends StatelessWidget {
  const _TelemetryCard({required this.telemetry});

  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final telemetry = this.telemetry;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.thermostat),
        title: Text(
          telemetry == null
              ? 'Temperatura non ancora ricevuta'
              : formatTemperature(telemetry.temperature),
        ),
        subtitle: telemetry == null
            ? null
            : Text('Accesa da ${formatUptime(telemetry.uptimeSeconds)}'),
      ),
    );
  }
}

class _ConfirmedCard extends StatelessWidget {
  const _ConfirmedCard({required this.state, required this.stale});

  final DeviceState state;

  /// Da scollegata il valore è l'ultimo letto, non per forza quello di adesso.
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.verified_outlined),
        title: Text(describeParams(state.params)),
        subtitle: Text(
          '${stale ? 'Ultimo valore letto' : 'Confermato dalla centralina'}'
          ' · revisione ${state.revision}',
        ),
      ),
    );
  }
}

class _ParamsEditor extends StatefulWidget {
  const _ParamsEditor({
    super.key,
    required this.initial,
    required this.enabled,
    required this.onApply,
    this.onApplyThenReboot,
  });

  final Params initial;
  final bool enabled;
  final ValueChanged<Params> onApply;
  final ValueChanged<Params>? onApplyThenReboot;

  @override
  State<_ParamsEditor> createState() => _ParamsEditorState();
}

class _ParamsEditorState extends State<_ParamsEditor> {
  static const _step = 5;

  late int _setpoint = widget.initial.setpoint;
  late Mode _mode = widget.initial.mode;

  Params get _draft => Params(setpoint: _setpoint, mode: _mode);

  void _change(int delta) {
    setState(() {
      final next = _setpoint + delta;
      _setpoint = next < Params.setpointMin
          ? Params.setpointMin
          : next > Params.setpointMax
          ? Params.setpointMax
          : next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final changed = _draft != widget.initial;
    final applyThenReboot = widget.onApplyThenReboot;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nuovi valori',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.outlined(
                  onPressed: enabled && _setpoint > Params.setpointMin
                      ? () => _change(-_step)
                      : null,
                  tooltip: 'Abbassa di mezzo grado',
                  icon: const Icon(Icons.remove),
                ),
                Expanded(
                  child: Text(
                    formatTemperature(_setpoint),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton.outlined(
                  onPressed: enabled && _setpoint < Params.setpointMax
                      ? () => _change(_step)
                      : null,
                  tooltip: 'Alza di mezzo grado',
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<Mode>(
              segments: [
                for (final mode in Mode.values)
                  ButtonSegment(value: mode, label: Text(modeLabel(mode))),
              ],
              selected: {_mode},
              onSelectionChanged: enabled
                  ? (selection) => setState(() => _mode = selection.single)
                  : null,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: enabled && changed
                  ? () => widget.onApply(_draft)
                  : null,
              child: const Text('Applica'),
            ),
            if (applyThenReboot != null)
              OutlinedButton(
                onPressed: enabled && changed
                    ? () => applyThenReboot(_draft)
                    : null,
                child: const Text('Prova: applica e riavvia senza rispondere'),
              ),
          ],
        ),
      ),
    );
  }
}
