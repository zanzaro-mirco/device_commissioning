import 'dart:async';

import 'package:commissioning_protocol/commissioning_protocol.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../link/device_link.dart';

enum LinkStatus { connecting, connected, disconnected }

/// Che cosa dire all'installatore dopo un'operazione. Ogni avviso ha un
/// numero, così due avvisi uguali di fila restano due avvisi.
enum NoticeKind {
  saved,
  alreadyApplied,
  conflict,
  rejected,
  notSent,
  uncertain,
  readFailed,
  connectFailed,
}

class Notice extends Equatable {
  const Notice(this.id, this.kind, [this.detail]);

  final int id;
  final NoticeKind kind;
  final String? detail;

  @override
  List<Object?> get props => [id, kind, detail];
}

class DeviceView extends Equatable {
  const DeviceView({
    required this.deviceId,
    this.name,
    this.link = LinkStatus.connecting,
    this.info,
    this.confirmed,
    this.telemetry,
    this.uncertain,
    this.busy = false,
    this.notice,
  });

  final String deviceId;
  final String? name;
  final LinkStatus link;
  final DeviceInfo? info;

  /// L'ultimo stato che la centralina ha confermato. È il solo che l'app
  /// mostra come valore corrente: una scrittura senza risposta non lo cambia.
  final DeviceState? confirmed;
  final Telemetry? telemetry;

  /// Una scrittura partita e mai confermata. Finché non si risolve, l'app non
  /// accetta scritture nuove: la prima cosa da sapere è se questa è arrivata.
  final SetParamsRequest? uncertain;
  final bool busy;
  final Notice? notice;

  bool get canWrite =>
      link == LinkStatus.connected &&
      !busy &&
      confirmed != null &&
      uncertain == null;

  DeviceView copyWith({
    LinkStatus? link,
    DeviceInfo? info,
    DeviceState? confirmed,
    Telemetry? telemetry,
    bool clearTelemetry = false,
    SetParamsRequest? uncertain,
    bool clearUncertain = false,
    bool? busy,
    Notice? notice,
  }) {
    return DeviceView(
      deviceId: deviceId,
      name: name,
      link: link ?? this.link,
      info: info ?? this.info,
      confirmed: confirmed ?? this.confirmed,
      telemetry: clearTelemetry ? null : telemetry ?? this.telemetry,
      uncertain: clearUncertain ? null : uncertain ?? this.uncertain,
      busy: busy ?? this.busy,
      notice: notice ?? this.notice,
    );
  }

  @override
  List<Object?> get props => [
    deviceId,
    name,
    link,
    info,
    confirmed,
    telemetry,
    uncertain,
    busy,
    notice,
  ];
}

/// Una centralina collegata: lettura, scrittura, telemetria, e soprattutto
/// l'esito incerto.
///
/// Quando una scrittura resta senza risposta, il cubit tiene da parte la
/// richiesta **così com'è**, con la stessa revisione attesa. Alla
/// riconnessione la ripete, e la centralina risponde `OK` se la prima volta
/// non era arrivata, `ALREADY_APPLIED` se era arrivata, `CONFLICT` se nel
/// frattempo qualcun altro ha cambiato i parametri. Costruire una richiesta
/// nuova sulla revisione riletta, invece, applicherebbe la modifica due volte.
class DeviceCubit extends Cubit<DeviceView> {
  DeviceCubit(this._link, {required String deviceId, String? name})
    : super(DeviceView(deviceId: deviceId, name: name));

  final DeviceLink _link;
  DeviceSession? _session;
  CommissioningClient? _client;
  final _subscriptions = <StreamSubscription<Object>>[];
  int _notices = 0;
  bool _connecting = false;

  /// Si collega, legge lo stato e, se c'è una scrittura incerta, la risolve.
  Future<void> connect() async {
    if (_connecting || _session != null) return;
    _connecting = true;
    emit(state.copyWith(link: LinkStatus.connecting));
    final DeviceSession session;
    try {
      session = await _link.connect(state.deviceId);
    } catch (error) {
      _connecting = false;
      if (isClosed) return;
      emit(
        state.copyWith(
          link: LinkStatus.disconnected,
          notice: _notice(NoticeKind.connectFailed, '$error'),
        ),
      );
      return;
    }
    _connecting = false;
    if (isClosed) {
      await session.close();
      return;
    }

    final client = CommissioningClient(session.channel);
    _session = session;
    _client = client;
    _subscriptions
      ..add(client.telemetry.listen((t) => emit(state.copyWith(telemetry: t))))
      ..add(
        session.channel.events.listen((event) {
          if (event is ChannelClosed) _onDisconnected();
        }),
      );
    // Il canale può essersi chiuso prima che ci iscrivessimo ai suoi eventi.
    if (!session.channel.isOpen) {
      _onDisconnected();
      return;
    }
    emit(state.copyWith(link: LinkStatus.connected, info: session.info));

    final pending = state.uncertain;
    if (pending != null) {
      await _write(() => client.setParams(pending));
    } else {
      await refresh();
    }
  }

  Future<void> refresh() async {
    final client = _client;
    if (client == null || state.busy) return;
    emit(state.copyWith(busy: true));
    final outcome = await client.readState();
    if (isClosed) return;
    switch (outcome) {
      case ReadSucceeded(:final state):
        emit(this.state.copyWith(busy: false, confirmed: state));
      case ReadFailed(:final reason):
        emit(
          state.copyWith(
            busy: false,
            notice: _notice(NoticeKind.readFailed, reason),
          ),
        );
    }
  }

  /// Scrive [params] a partire dall'ultimo stato confermato.
  Future<void> apply(Params params) async {
    final request = _newRequest(params);
    final client = _client;
    if (request == null || client == null) return;
    await _write(() => client.setParams(request));
  }

  /// Solo con il firmware di debug: la centralina applica, salva e si riavvia
  /// senza rispondere. Serve a provare l'esito incerto sull'hardware vero.
  Future<void> applyThenReboot(Params params) async {
    final request = _newRequest(params);
    final client = _client;
    if (request == null || client == null) return;
    await _write(() => client.debugApplyThenReboot(request));
  }

  /// Risolve la scrittura incerta: la ripete subito se la connessione c'è,
  /// altrimenti si ricollega, e la ripete [connect].
  Future<void> resolveUncertain() async {
    final pending = state.uncertain;
    if (pending == null || state.busy) return;
    final client = _client;
    if (client == null) {
      await connect();
      return;
    }
    await _write(() => client.setParams(pending));
  }

  SetParamsRequest? _newRequest(Params params) {
    final confirmed = state.confirmed;
    if (!state.canWrite || confirmed == null) return null;
    return SetParamsRequest(
      expectedRevision: confirmed.revision,
      params: params,
    );
  }

  Future<void> _write(Future<WriteOutcome> Function() send) async {
    emit(state.copyWith(busy: true));
    final outcome = await send();
    if (isClosed) return;
    switch (outcome) {
      case WriteConfirmed(:final state, :final alreadyApplied):
        emit(
          this.state.copyWith(
            busy: false,
            confirmed: state,
            clearUncertain: true,
            notice: _notice(
              alreadyApplied ? NoticeKind.alreadyApplied : NoticeKind.saved,
            ),
          ),
        );
      case WriteConflict():
        // Niente è stato scritto, e lo stato che l'app conosce è vecchio.
        emit(
          state.copyWith(
            busy: false,
            clearUncertain: true,
            notice: _notice(NoticeKind.conflict),
          ),
        );
        await refresh();
      case WriteRejected(:final status, :final code):
        emit(
          state.copyWith(
            busy: false,
            clearUncertain: true,
            notice: _notice(
              NoticeKind.rejected,
              status?.name ?? 'codice $code',
            ),
          ),
        );
      case WriteNotSent(:final reason):
        // Se era il nuovo tentativo di una scrittura incerta, il dubbio resta:
        // questo invio non è partito, ma il primo forse sì.
        emit(
          state.copyWith(
            busy: false,
            notice: _notice(NoticeKind.notSent, reason),
          ),
        );
      case WriteUncertain(:final request, :final reason):
        emit(
          state.copyWith(
            busy: false,
            uncertain: request,
            notice: _notice(NoticeKind.uncertain, reason),
          ),
        );
    }
  }

  void _onDisconnected() {
    if (isClosed || _session == null) return;
    unawaited(_release());
    emit(state.copyWith(link: LinkStatus.disconnected, clearTelemetry: true));
  }

  Future<void> _release() async {
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    final client = _client;
    final session = _session;
    _client = null;
    _session = null;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await client?.dispose();
    await session?.close();
  }

  Notice _notice(NoticeKind kind, [String? detail]) =>
      Notice(++_notices, kind, detail);

  @override
  Future<void> close() async {
    await _release();
    return super.close();
  }
}
