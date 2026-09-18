# Architettura e scelte di progetto

Il documento cresce con il progetto. Per ora copre il protocollo e il nucleo in C: il resto
arriva con il pacchetto Dart, il plugin, il firmware e l'app.

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
esegue sulla logica vera. Il test in Dart li eseguirà sulla centralina finta con cui si
provano l'app e il plugin senza hardware. Se la finta smette di comportarsi come la vera,
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

## Falsificazioni

Ogni difesa è stata tolta a mano per vedere fallire i suoi test (456 controlli in tutto):

| Difesa tolta | Controlli rossi |
|---|---|
| Verifica del CRC | 5, fra cui lo scenario della trama rovinata: la centralina rispondeva `CONFLICT` a una richiesta mai fatta |
| Controllo della versione dopo il CRC (spostato prima) | 1: un bit rovinato nella versione diventava «versione non supportata» |
| Risposta `ALREADY_APPLIED` | 2, fra cui il riavvio a metà scrittura |
| Condizione sulla revisione (scrittura sempre accettata) | 14, fra cui il tentativo in ritardo che cancella la modifica più recente |
| Salvataggio prima della risposta | 11 |

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
