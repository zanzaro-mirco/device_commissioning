import 'messages.dart';

/// Il canale verso la centralina, come lo vede il protocollo. L'implementazione
/// vera è il plugin Bluetooth; nei test è [FakeFrameChannel].
abstract interface class FrameChannel {
  /// Trame in arrivo, trame rovinate e chiusura del canale, in ordine.
  Stream<ChannelEvent> get events;

  /// Se il canale è aperto adesso. Serve oltre a [ChannelClosed] perché chi si
  /// iscrive tardi agli eventi non riceve una chiusura già avvenuta.
  bool get isOpen;

  /// Completa quando la centralina ha ricevuto i byte (la scrittura con
  /// risposta del GATT). Non dice niente sull'esito del comando: quello
  /// arriva come trama su [events].
  ///
  /// Lancia [FrameRejectedException] solo se è **certo** che i byte non sono
  /// stati accettati. Qualunque altro errore, compresa
  /// [ChannelClosedException], lascia l'esito sconosciuto.
  Future<void> send(Frame frame);
}

sealed class ChannelEvent {
  const ChannelEvent();
}

class FrameArrived extends ChannelEvent {
  const FrameArrived(this.frame);

  final Frame frame;
}

/// Il nativo ha ricevuto byte che non formano una trama valida. Non c'è una
/// sequenza affidabile a cui abbinarli: si registrano e basta.
class FrameCorrupted extends ChannelEvent {
  const FrameCorrupted(this.reason);

  final String reason;
}

class ChannelClosed extends ChannelEvent {
  const ChannelClosed();
}

/// I byte non sono stati accettati, con certezza: il sistema ha rifiutato di
/// mandarli, o la centralina ha risposto con un errore del livello ATT.
class FrameRejectedException implements Exception {
  const FrameRejectedException(this.reason);

  final String reason;

  @override
  String toString() => 'FrameRejectedException: $reason';
}

class ChannelClosedException implements Exception {
  const ChannelClosedException();

  @override
  String toString() => 'ChannelClosedException: il canale è chiuso';
}
