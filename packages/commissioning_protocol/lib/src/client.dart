import 'dart:async';
import 'dart:typed_data';

import 'channel.dart';
import 'messages.dart';

/// L'esito di una lettura dello stato.
sealed class ReadOutcome {
  const ReadOutcome();
}

class ReadSucceeded extends ReadOutcome {
  const ReadSucceeded(this.state);

  final DeviceState state;
}

class ReadFailed extends ReadOutcome {
  const ReadFailed(this.reason);

  final String reason;
}

/// L'esito di una scrittura. I casi sono cinque perché sono cinque le cose
/// che l'app deve fare in modo diverso, e il compilatore obbliga a gestirli
/// tutti.
sealed class WriteOutcome {
  const WriteOutcome();
}

/// La centralina ha i nuovi valori, salvati. [alreadyApplied] dice che era un
/// nuovo tentativo di una modifica arrivata la volta precedente.
class WriteConfirmed extends WriteOutcome {
  const WriteConfirmed(this.state, {required this.alreadyApplied});

  final DeviceState state;
  final bool alreadyApplied;
}

/// La revisione su cui si basava la scrittura non è più quella corrente:
/// qualcun altro ha cambiato i parametri. Niente è stato scritto, e l'app
/// deve rileggere prima di riprovare.
class WriteConflict extends WriteOutcome {
  const WriteConflict(this.currentRevision);

  final int currentRevision;
}

/// La centralina ha risposto di no: valori fuori dai limiti, trama rovinata,
/// comando sconosciuto. Niente è stato scritto.
class WriteRejected extends WriteOutcome {
  const WriteRejected(this.status, this.code);

  /// Null se il codice non è fra quelli che questa versione conosce.
  final Status? status;
  final int code;
}

/// La richiesta non è partita, o è stata rifiutata prima di arrivare alla
/// logica della centralina: niente è stato scritto.
class WriteNotSent extends WriteOutcome {
  const WriteNotSent(this.reason);

  final String reason;
}

/// La richiesta è partita e la risposta non è arrivata. La modifica **può**
/// essere stata applicata. Si risolve ripetendo [request] così com'è: la
/// scrittura condizionata rende il nuovo tentativo sicuro.
class WriteUncertain extends WriteOutcome {
  const WriteUncertain(this.request, this.reason);

  final SetParamsRequest request;
  final String reason;
}

/// Parla con una centralina attraverso un [FrameChannel]. Un cliente vale una
/// connessione: quando il canale si chiude si chiude anche lui, e alla
/// riconnessione se ne crea uno nuovo.
class CommissioningClient {
  CommissioningClient(
    this._channel, {
    this.timeout = const Duration(seconds: 3),
  }) {
    _subscription = _channel.events.listen(_onEvent);
  }

  final FrameChannel _channel;

  /// Quanto aspettare una risposta. Un giro completo via Bluetooth LE richiede
  /// qualche decina di millisecondi: tre secondi coprono una centralina lenta
  /// senza lasciare l'installatore davanti a uno schermo fermo.
  final Duration timeout;

  final _pending = <int, Completer<_Reply>>{};
  final _telemetry = StreamController<Telemetry>.broadcast();
  final _corrupted = StreamController<String>.broadcast();
  late final StreamSubscription<ChannelEvent> _subscription;
  int _lastSeq = 0;
  bool _closed = false;

  bool get isClosed => _closed;

  Stream<Telemetry> get telemetry => _telemetry.stream;

  /// Trame rovinate ricevute dal nativo, per il registro diagnostico.
  Stream<String> get corruptedFrames => _corrupted.stream;

  Future<ReadOutcome> readState() async {
    final reply = await _exchange(MessageType.getState, Uint8List(0));
    switch (reply) {
      case _NotSent(:final reason):
        return ReadFailed(reason);
      case _NoResponse(:final reason):
        return ReadFailed(reason);
      case _Response(:final frame):
        if (frame.type == MessageType.state) {
          final message = StateMessage.decode(frame.payload);
          if (message != null) return ReadSucceeded(message.state);
        }
        return ReadFailed('risposta inattesa: $frame');
    }
  }

  Future<WriteOutcome> setParams(SetParamsRequest request) =>
      _write(MessageType.setParams, request);

  /// Solo per le prove con il firmware di debug: la centralina applica, salva e
  /// si riavvia senza rispondere. L'esito atteso è [WriteUncertain].
  Future<WriteOutcome> debugApplyThenReboot(SetParamsRequest request) =>
      _write(MessageType.debugApplyThenReboot, request);

  Future<WriteOutcome> _write(int type, SetParamsRequest request) async {
    final reply = await _exchange(type, request.encode());
    switch (reply) {
      case _NotSent(:final reason):
        return WriteNotSent(reason);
      case _NoResponse(:final reason):
        return WriteUncertain(request, reason);
      case _Response(:final frame):
        return _interpretWrite(request, frame);
    }
  }

  WriteOutcome _interpretWrite(SetParamsRequest request, Frame frame) {
    if (frame.type == MessageType.error && frame.payload.length == 1) {
      final code = frame.payload[0];
      return WriteRejected(Status.fromCode(code), code);
    }
    final result = frame.type == MessageType.setResult
        ? SetResult.decode(frame.payload)
        : null;
    if (result == null) {
      // Una risposta illeggibile alla nostra sequenza non è un rifiuto: non
      // sappiamo cosa abbia fatto la centralina, quindi l'esito è incerto.
      return WriteUncertain(request, 'risposta illeggibile: $frame');
    }
    final state =
        DeviceState(revision: result.revision, params: request.params);
    return switch (Status.fromCode(result.status)) {
      Status.ok => WriteConfirmed(state, alreadyApplied: false),
      Status.alreadyApplied => WriteConfirmed(state, alreadyApplied: true),
      Status.conflict => WriteConflict(result.revision),
      final status => WriteRejected(status, result.status),
    };
  }

  Future<_Reply> _exchange(int type, Uint8List payload) async {
    if (_closed || !_channel.isOpen) {
      _closed = true;
      return const _NotSent();
    }
    final seq = _nextSeq();
    final completer = Completer<_Reply>();
    _pending[seq] = completer;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer
            .complete(const _NoResponse('nessuna risposta entro il tempo'));
      }
    });
    try {
      await _channel.send(Frame(type, seq, payload));
    } on FrameRejectedException catch (error) {
      // L'unico errore d'invio che dà una certezza: niente è stato accettato.
      if (!completer.isCompleted) completer.complete(_NotSent(error.reason));
    } on ChannelClosedException {
      // La connessione è caduta durante la scrittura: i byte possono essere
      // arrivati o no. Non è un «non spedito», è un esito incerto.
      if (!completer.isCompleted) {
        completer
            .complete(const _NoResponse('connessione caduta durante l\'invio'));
      }
    } catch (error) {
      // Qualunque altro errore lascia l'esito sconosciuto: nel dubbio, incerto.
      if (!completer.isCompleted) {
        completer.complete(_NoResponse('errore durante l\'invio: $error'));
      }
    }
    final reply = await completer.future;
    timer.cancel();
    _pending.remove(seq);
    return reply;
  }

  /// Sequenze da 1 a 255. Lo 0 resta alle notifiche della centralina, e una
  /// sequenza ancora in attesa non si riusa. Una risposta arrivata dopo il suo
  /// tempo trova la sequenza già rimossa e viene ignorata.
  int _nextSeq() {
    do {
      _lastSeq = _lastSeq % 255 + 1;
    } while (_pending.containsKey(_lastSeq));
    return _lastSeq;
  }

  void _onEvent(ChannelEvent event) {
    switch (event) {
      case FrameArrived(:final frame):
        if (frame.type == MessageType.telemetry) {
          final telemetry = Telemetry.decode(frame.payload);
          if (telemetry != null) _telemetry.add(telemetry);
          return;
        }
        final completer = _pending[frame.seq];
        if (completer != null && !completer.isCompleted) {
          completer.complete(_Response(frame));
        }
      case FrameCorrupted(:final reason):
        _corrupted.add(reason);
      case ChannelClosed():
        _close();
    }
  }

  void _close() {
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.complete(const _NoResponse('connessione caduta'));
      }
    }
  }

  Future<void> dispose() async {
    _close();
    await _subscription.cancel();
    await _telemetry.close();
    await _corrupted.close();
  }
}

sealed class _Reply {
  const _Reply();
}

class _Response extends _Reply {
  const _Response(this.frame);

  final Frame frame;
}

class _NoResponse extends _Reply {
  const _NoResponse(this.reason);

  final String reason;
}

class _NotSent extends _Reply {
  const _NotSent([this.reason = 'canale chiuso']);

  final String reason;
}
