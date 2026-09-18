# Architettura e scelte di progetto

Il documento cresce con il progetto. Per ora copre il protocollo, il nucleo in C, il pacchetto
Dart, il plugin Bluetooth per Android e il firmware. Il resto arriva con l'app.

## Un solo codice per il filo, in C

La trama (intestazione, lunghezza, CRC) sta **una volta sola**, in `native/dc_core`, e la usano
tre programmi:
- il firmware dell'ESP32, dove la cartella è un componente di ESP-IDF;
- il plugin Android, tramite JNI;
- il plugin iOS e macOS, perché Swift chiama il C direttamente.

L'alternativa era riscrivere la trama in Dart, in Kotlin e nel firmware. Tre implementazioni
dello stesso formato binario sono tre occasioni di divergere su un dettaglio come l'ordine
dei byte del CRC, e una divergenza così si scopre solo con l'hardware in mano.

Il Dart, di conseguenza, **non vede il CRC**. Il plugin gli consegna trame già verificate
(tipo, sequenza, contenuto), oppure un errore di trasporto. È la divisione di un SDK per
periferiche: il filo lo gestisce lo strato nativo, il significato dei messaggi lo gestisce
l'app.

Il prezzo è che la logica dei messaggi esiste due volte: in C sulla centralina, in Dart
nell'app. Qui la duplicazione è inevitabile, perché sono i due capi di una conversazione. La
si tiene sotto controllo con i vettori.

## I vettori sono il contratto

`protocol/vectors` contiene casi di prova in un formato di testo semplice, una riga per caso.
Li eseguono i test in C e, dal pacchetto Dart in poi, anche i test in Dart. Il documento
`PROTOCOL.md` spiega; i vettori decidono.

**I byte attesi non sono calcolati dal nostro codice.** Li produce
`protocol/tool/generate_vectors.py` con la libreria standard di Python: `binascii.crc_hqx`
per il CRC e `struct` per gli interi. Un vettore generato dallo stesso codice che deve
verificare sbaglierebbe insieme a lui, e il test resterebbe verde. È la trappola già
incontrata con i byte ESC/POS in `pos_printer_bridge`. Il primo vettore del CRC è poi il valore
di controllo pubblicato nel catalogo (`0x29B1` su `123456789`), che non dipende né da noi né da
Python.

La pipeline rigenera i vettori e fallisce se differiscono da quelli nel repository.

Gli **scenari** (`scenarios.vec`) sono invece scritti a mano: sono sequenze di richieste e
risposte attese, cioè il comportamento della centralina detto in chiaro. Il test in C li
esegue sulla logica vera, il test in Dart sulla centralina finta con cui si provano l'app e il
plugin senza hardware. Se la finta smette di comportarsi come la vera,
fallisce il suo test.

## La scrittura condizionata

Il dettaglio è in `PROTOCOL.md`. Qui conta il perché. Il rischio da evitare non è applicare
due volte lo stesso valore, che per un setpoint assoluto è innocuo. È **un nuovo tentativo
arrivato in ritardo che riporta indietro una modifica più recente**, magari fatta da un altro
telefono. Per questo ogni `SET_PARAMS` porta la revisione su cui si basa, e la centralina lo
accetta solo se è quella corrente. È la stessa idea degli ETag in HTTP e del controllo di
concorrenza ottimistico nei database. In `pos_sync` lo stesso problema era stato risolto con un
orologio di Lamport, perché lì non c'era un'autorità centrale. Qui c'è, ed è la centralina, e
basta un contatore.

**La centralina salva prima di rispondere.** `dc_device_handle` non scrive sulla flash: dice al
firmware cosa fare (`PERSIST_THEN_RESPOND`). Un `OK` arrivato all'app vuol dire che il valore
è già sulla flash. Il test degli scenari simula il riavvio ripartendo solo da ciò che è stato
salvato, e controlla anche il contrario: se lo stato cambia senza che la centralina chieda di
salvarlo, fallisce.

## Il protocollo lato app

`packages/commissioning_protocol` è Dart puro, senza Flutter e senza Bluetooth. Parla con la
centralina attraverso un `FrameChannel`, che il plugin implementa sopra il GATT e che nei test
è `FakeFrameChannel`.

**Una scrittura ha cinque esiti, non due**, e sono una gerarchia `sealed`, così il compilatore
obbliga l'app a gestirli tutti:

| Esito | Cosa è successo sulla centralina | Cosa fa l'app |
|---|---|---|
| `WriteConfirmed` | scritto e salvato (anche `ALREADY_APPLIED`) | mostra il nuovo valore |
| `WriteConflict` | niente: qualcun altro ha cambiato i parametri | rilegge lo stato |
| `WriteRejected` | niente: valori fuori dai limiti o trama rifiutata | spiega il motivo |
| `WriteNotSent` | niente: il canale era chiuso, o il trasporto ha rifiutato i byte | propone di riprovare o di riconnettersi |
| `WriteUncertain` | **forse** | mostra «esito incerto» e ripete la stessa richiesta |

Tre regole decidono il confine fra «rifiutata» e «incerta», e ognuna ha un test:
- **Il tempo scaduto è incerto, non fallito.** La centralina può aver eseguito e la risposta
  essersi persa.
- **Una connessione caduta durante l'invio è incerta, non «non spedita».** I byte possono
  essere arrivati.
- **Una risposta illeggibile alla nostra sequenza è incerta, non un rifiuto.** Non sappiamo
  cosa abbia fatto la centralina.

Le risposte si abbinano alle richieste per **sequenza**, da 1 a 255. Una risposta arrivata dopo
il suo tempo trova la sequenza già rimossa e viene ignorata: non completa la richiesta
successiva.

`FakeDevice` riproduce in Dart la logica della centralina ed esegue gli stessi scenari del C,
tranne i due che contengono una trama intera con il CRC. Lavora sui numeri del filo e non sugli
enum dell'app: un modo 3 deve arrivare alla centralina ed essere rifiutato come fuori dai
limiti, non fermarsi prima perché l'app non sa rappresentarlo.

**Un difetto trovato dal primo giro di test.** Un canale chiuso *prima* che il cliente si
iscrivesse agli eventi non veniva mai visto come chiuso. La richiesta partiva, il canale
lanciava un'eccezione, e l'esito diventava «incerto» invece di «non spedito». È il caso di una
connessione caduta mentre l'app sta ancora costruendo la schermata. Il contratto
`FrameChannel` ora ha `isOpen`, e il cliente lo controlla prima di mandare.

## Il plugin Bluetooth

`packages/ble_bridge` porta il protocollo sul GATT di Android. Il lato Swift arriva con la voce
5.

### Perché un plugin scritto a mano

Esistono librerie Bluetooth per Flutter. `universal_ble` è BSD-3, supporta Android, iOS,
macOS, Windows, Linux e web, ed è un'alternativa legittima: in un progetto di lavoro sarebbe il
primo candidato da valutare. **`flutter_blue_plus` invece è escluso dalla licenza**: dalla
FlutterBluePlus License 1.5 qualunque azienda a scopo di lucro deve comprare una licenza
commerciale, anche solo per sviluppare e valutare.

Il plugin qui è scritto a mano per tre ragioni:
- **Il C del protocollo va chiamato dal nativo.** La trama viene codificata e verificata dallo
  stesso codice del firmware, via JNI (e, per Swift, direttamente). Con una libreria generica
  il Dart riceverebbe byte grezzi e il CRC andrebbe riscritto in Dart.
- **Gli errori devono distinguere «rifiutato» da «sconosciuto».** Il protocollo ha bisogno di
  sapere se una scrittura fallita è partita o no. Un'API generica restituisce di solito un
  errore e basta.
- **È la competenza che il progetto deve dimostrare:** un platform channel tipizzato verso
  codice nativo che parla con una periferica.

### Pigeon, e il codice generato nel repository

Il contratto fra Dart e Kotlin è `pigeons/ble_api.dart`. Pigeon genera i due lati, tipizzati:
un campo rinominato da una parte sola fa fallire la compilazione, non l'app sul telefono.
- Il codice generato è **versionato**: chi legge il repository vede cosa attraversa il canale
  senza dover eseguire niente. La pipeline lo rigenera e fallisce se differisce.
- Gli eventi (risultati della scansione, trame, trame rovinate, connessione) viaggiano su un
  solo `EventChannel` come gerarchia `sealed`, e il Dart li smista per dispositivo.
- Pigeon 29 genera i metodi `@async` come funzioni `suspend` lanciate sul thread principale.

### Una operazione GATT alla volta

Il GATT di Android esegue un'operazione per volta. Una seconda scrittura chiesta prima della
callback della prima viene rifiutata, oppure accettata e persa, a seconda della versione e del
produttore del telefono. `GattOperationQueue` le mette in fila. È Kotlin puro, provato sulla
JVM con un orologio finto, perché la parte difficile è l'ordine degli eventi, non il Bluetooth.
- **Ogni operazione ha una chiave** (`write:<uuid>`, `read:<uuid>`, `notify:<uuid>`). La
  callback tardiva di un'operazione già scaduta ha una chiave diversa da quella in corso, e si
  ignora. Senza chiave chiuderebbe l'operazione successiva con l'esito di un'altra.
- **Tutto gira sul thread principale.** Le callback del GATT arrivano su un thread di sistema e
  vengono riportate lì prima di toccare la coda. Nessun lock, quindi nessuno da dimenticare.
- **Le callback cambiano firma da Android 13**: il valore arriva come parametro invece di
  leggerlo dalla caratteristica, che nel frattempo poteva essere cambiata. Il plugin le
  implementa tutte e due e ignora quella vecchia sulle versioni nuove.

### Dal Kotlin agli esiti del protocollo

La traduzione degli errori è il punto in cui il Bluetooth incontra la scrittura condizionata:

| Cosa succede nel Kotlin | Codice | Nel Dart | Esito della scrittura |
|---|---|---|---|
| il sistema rifiuta di avviare l'operazione | `rejected` | `FrameRejectedException` | `WriteNotSent` |
| la centralina risponde con un errore ATT | `rejected` | `FrameRejectedException` | `WriteNotSent` |
| nessuna callback in tempo | `timeout` | `PlatformException` | `WriteUncertain` |
| la connessione cade durante l'operazione | `disconnected` | `ChannelClosedException` | `WriteUncertain` |
| qualunque altro errore | vari | `PlatformException` | `WriteUncertain` |

Solo un rifiuto **certo** diventa «non spedita»: nel dubbio, l'esito è incerto, e il nuovo
tentativo lo risolve senza rischi. Per questo il contratto `FrameChannel` ha ora anche
`FrameRejectedException`, e il cliente tratta come incerto ogni errore che non riconosce.

### Permessi

Da Android 12 servono `BLUETOOTH_SCAN` (dichiarato `neverForLocation`) e `BLUETOOTH_CONNECT`.
Fino ad Android 11 serve la posizione, perché una scansione può rivelarla. Il rifiuto
permanente si riconosce con `shouldShowRequestPermissionRationale` dopo la risposta: è
un'euristica, ed è quella che indica la documentazione di Android.

### Come si prova

- **Dart:** un `BleHostApi` finto appoggiato alla `FakeDevice` fa girare il cliente vero
  attraverso il canale vero, con gli errori della piattaforma iniettati uno per uno.
- **Kotlin:** i test JVM della coda.
- **C via JNI:** un test strumentato legge `frames.vec` dagli asset (presi da
  `protocol/vectors`, non copiati) e lo esegue sulla libreria compilata per Android. Gira su
  emulatore in CI. Questo test non è stato falsificato: in locale non c'è un emulatore, e
  una mutazione andrebbe provata su un ramo, che le regole del portfolio non lasciano aperto.
  Le difese che controlla sono comunque falsificate nei test in C sul PC.
- **Bluetooth vero:** con l'ESP32, sul Galaxy S20, quando arriva la scheda.

## Il firmware

`firmware/` è il minimo per avere un interlocutore vero: ESP-IDF 6.1 e NimBLE su una
ESP32-S3. Non contiene logica del protocollo. Riceve i byte, li passa a `dc_device_handle` di
`native/dc_core` e fa quello che la funzione gli dice: rispondere, salvare e poi rispondere,
oppure salvare e riavviare.

### La risposta ATT non è l'esito

La scrittura sui comandi è con risposta, e NimBLE manda la risposta ATT quando la funzione di
accesso torna. Per questo la funzione di accesso **non esegue il comando**: lo mette in una coda
e torna subito. Il comando lo esegue il task della centralina, e l'esito parte dopo come
notifica. Così la risposta ATT vuol dire solo «i byte sono arrivati», come scritto in
`protocol/PROTOCOL.md`, e il salvataggio su NVS, che può durare decine di millisecondi, non
blocca lo stack Bluetooth.

Se la coda è piena, la scrittura fallisce a livello ATT. Il plugin la riporta come rifiutata, e
l'app sa che il comando non è partito.

### Un solo task tocca lo stato

Il task della centralina esegue i comandi in ordine e, quando non ne arrivano, manda la
telemetria. Lo stato è suo e di nessun altro: non servono lock. Il task di NimBLE scrive solo
la connessione corrente e l'iscrizione alla telemetria, due valori piccoli che si leggono in
modo atomico.

### Salvare prima di rispondere

- `OK` parte solo dopo `nvs_set_blob` e `nvs_commit`. Senza il commit il valore può restare in
  memoria.
- Se il salvataggio fallisce, lo stato in memoria torna quello di prima e **non si risponde**.
  L'app vede un esito incerto e ripete la stessa richiesta. Rispondere `OK` sarebbe una bugia,
  e non esiste un codice di stato per «flash rotta» che l'app saprebbe usare meglio di un nuovo
  tentativo.
- Lo stato si salva in un formato fisso di otto byte, con una versione in testa, e non come
  struct: la disposizione di una struct in memoria dipende dal compilatore.
- Se i valori letti dalla flash sono fuori dai limiti, la centralina riparte da quelli di
  fabbrica invece di applicarli.

### Il comando di guasto

`DEBUG_APPLY_THEN_REBOOT` applica, salva e riavvia senza rispondere. Esiste solo nel firmware
costruito con `sdkconfig.debug`, attraverso l'opzione `CONFIG_DC_DEBUG_COMMANDS`. La CI
costruisce entrambi i firmware e controlla che in quello da installare l'opzione sia spenta.

### Come si prova

Il firmware non ha test propri: le sue decisioni sono in `dc_core`, provate e falsificate sul
PC. Resta da provare quello che solo l'hardware dice, cioè i punti 1-4 del criterio di fatto,
con la scheda e il Galaxy S20 (vedi `firmware/README.md`). In CI il firmware si compila.

## Falsificazioni

Ogni difesa è stata tolta a mano per vedere fallire i suoi test.

**Nucleo in C** (456 controlli):

| Difesa tolta | Controlli rossi |
|---|---|
| Verifica del CRC | 5, fra cui lo scenario della trama rovinata: la centralina rispondeva `CONFLICT` a una richiesta mai fatta |
| Controllo della versione dopo il CRC (spostato prima) | 1: un bit rovinato nella versione diventava «versione non supportata» |
| Risposta `ALREADY_APPLIED` | 2, fra cui il riavvio a metà scrittura |
| Condizione sulla revisione (scrittura sempre accettata) | 14, fra cui il tentativo in ritardo che cancella la modifica più recente |
| Salvataggio prima della risposta | 11 |

**Protocollo lato app** (40 test al momento della prova):

| Difesa tolta | Test rossi |
|---|---|
| `ALREADY_APPLIED` nella centralina finta | 4: due scenari e due test del cliente, fra cui il criterio 4 |
| Tempo scaduto trattato come riuscita | 4 |
| Abbinamento delle risposte per sequenza | 1: la risposta in ritardo completava la richiesta successiva |
| Chiusura del canale che sveglia le attese | 1: l'esito arrivava dopo tre secondi invece che subito |
| Controllo di `isOpen` prima dell'invio | 1 |

**Coda GATT** (8 test JVM):

| Difesa tolta | Test rossi |
|---|---|
| Aspettare la fine dell'operazione in corso | 4 |
| Controllo della chiave della callback | 1: la callback tardiva chiudeva l'operazione successiva |
| Scadenza delle operazioni | 1 |

## Dove ho consapevolmente semplificato

- **CRC bit per bit, senza tabella.** Le trame sono di una ventina di byte, e la tabella
  costerebbe 512 byte di flash per un risparmio che nessuno misurerebbe.
- **Una scrittura con gli stessi valori fa comunque avanzare la revisione.** Un secondo client
  che nel frattempo aveva letto la revisione precedente riceverà un `CONFLICT` anche se il
  valore è quello che voleva lui. È un conflitto inutile ma sicuro: l'app rilegge e vede che è
  tutto a posto.
- **Una trama rovinata riceve un errore con la sua sequenza, anche se la sequenza può essere
  rovinata.** Se la sequenza è sbagliata, all'app scade l'attesa, ed è lo stesso esito che
  avrebbe senza risposta.
- **Un solo parametro composto** (setpoint e modo): basta per mostrare letture, scritture
  condizionate e conflitti, e non serve un modello di parametri generico.
- **Il firmware è il minimo.** La temperatura è simulata, c'è una connessione alla volta, non
  c'è associazione né cifratura (arrivano con la voce 8 del piano) e non c'è aggiornamento del
  firmware via Bluetooth (voce 6).
