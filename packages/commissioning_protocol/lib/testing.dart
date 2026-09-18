/// La centralina finta e la sua connessione, per i test del plugin e
/// dell'app. Sta in una libreria separata perché il codice di produzione non
/// deve poterla importare per sbaglio insieme al protocollo.
library;

export 'src/fake_device.dart';
