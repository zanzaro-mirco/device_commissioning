# Protocollo di messa in servizio, versione 1

Questo documento è il contratto fra la centralina (`firmware/`) e l'app (`app/`, attraverso
`packages/ble_bridge` e `packages/commissioning_protocol`). Le due parti sono scritte in
linguaggi diversi, C e Dart. Per questo il contratto non vive solo qui: vive anche nei file di
`vectors/`, che **entrambe le implementazioni leggono ed eseguono nei propri test**. Se il
documento e i vettori non coincidono, valgono i vettori.

## Il servizio GATT

Gli UUID contengono in esadecimale la stringa `mircozanzaro`, così si riconoscono a colpo
d'occhio in uno scanner.

| Caratteristica | UUID | Proprietà | Contenuto |
|---|---|---|---|
| servizio | `4d5a0001-6d69-7263-6f7a-616e7a61726f` | — | — |
| informazioni | `4d5a0002-6d69-7263-6f7a-616e7a61726f` | lettura | una trama `INFO` |
| comandi | `4d5a0003-6d69-7263-6f7a-616e7a61726f` | scrittura con risposta | una trama di richiesta |
| risposte | `4d5a0004-6d69-7263-6f7a-616e7a61726f` | notifica | una trama di risposta |
| telemetria | `4d5a0005-6d69-7263-6f7a-616e7a61726f` | notifica | una trama `TELEMETRY` |

La scrittura **con** risposta conferma solo che i byte sono arrivati al livello ATT della
centralina, non che il comando sia stato eseguito. L'esito del comando arriva **sempre** come
notifica sulla caratteristica delle risposte, abbinato alla richiesta dal numero di sequenza.

## La trama

Tutti gli interi sono little-endian.

| Byte | Campo | Note |
|---|---|---|
| 0 | versione | oggi `1` |
| 1 | tipo | vedi sotto |
| 2 | sequenza | scelta da chi chiede, ripetuta nella risposta |
| 3 | lunghezza | byte del contenuto, da 0 a 200 |
| 4 … | contenuto | |
| ultimi 2 | CRC | CRC-16/IBM-3740 (detto anche CCITT-FALSE) su tutti i byte precedenti |

Il CRC è quello del catalogo di Greg Cook: polinomio `0x1021`, valore iniziale `0xFFFF`,
nessuna riflessione, nessuno xor finale. Il valore di controllo su `123456789` è `0x29B1`, ed è
il primo vettore di `vectors/crc.vec`.

**L'ordine dei controlli in decodifica è parte del contratto.** Prima la lunghezza, poi il CRC,
poi la versione. Un byte di versione rovinato durante il trasporto deve risultare «CRC
sbagliato» e non «versione non supportata»: la seconda risposta direbbe a chi legge di
aggiornare l'app, e sarebbe falso.

**Tutti i messaggi della versione 1 stanno in 20 byte**, cioè nella MTU minima del Bluetooth LE
(23 byte meno 3 di intestazione ATT). Il protocollo funziona senza negoziare la MTU. La
negoziazione serve solo all'aggiornamento del firmware (voce 6 del piano).

## I messaggi

| Tipo | Nome | Direzione | Contenuto |
|---|---|---|---|
| `0x01` | `GET_STATE` | app → centralina | vuoto |
| `0x02` | `SET_PARAMS` | app → centralina | `expected_revision` u32, `setpoint` i16, `mode` u8 |
| `0x7F` | `DEBUG_APPLY_THEN_REBOOT` | app → centralina | come `SET_PARAMS` (solo nel firmware di debug) |
| `0x81` | `STATE` | centralina → app | `status` u8, `revision` u32, `setpoint` i16, `mode` u8 |
| `0x82` | `SET_RESULT` | centralina → app | `status` u8, `revision` u32 |
| `0x40` | `TELEMETRY` | centralina → app | `temperature` i16, `uptime_s` u32 |
| `0x41` | `INFO` | centralina → app | `protocol_version` u8, `fw_major` u8, `fw_minor` u8, `fw_patch` u8 |
| `0xFF` | `ERROR` | centralina → app | `status` u8 |

- `setpoint` e `temperature` sono in **decimi di grado**: 215 vale 21,5 °C. Il setpoint valido
  va da 50 a 300.
- `mode`: 0 spento, 1 comfort, 2 economia.

### Codici di stato

| Codice | Nome | Significato |
|---|---|---|
| 0 | `OK` | eseguito |
| 1 | `ALREADY_APPLIED` | la stessa modifica era già stata applicata: è un nuovo tentativo |
| 2 | `CONFLICT` | la revisione attesa non è quella corrente: qualcun altro ha cambiato i parametri |
| 3 | `OUT_OF_RANGE` | valori fuori dai limiti |
| 4 | `BAD_FRAME` | trama rovinata (lunghezza o CRC) |
| 5 | `UNSUPPORTED_VERSION` | versione del protocollo sconosciuta |
| 6 | `UNKNOWN_TYPE` | tipo di messaggio sconosciuto |
| 7 | `BAD_PAYLOAD` | contenuto della lunghezza sbagliata per il tipo |

## Perché una revisione e non un identificativo di richiesta

La prima versione del piano prevedeva un identificativo per richiesta, da ricordare sulla
centralina. Non basta, per due ragioni:
1. i client sono più d'uno (il telefono e il Mac), e i loro identificativi non si possono
   ordinare fra loro;
2. il pericolo vero non è applicare due volte lo stesso valore, che per un valore assoluto è
   innocuo. È **un nuovo tentativo arrivato in ritardo che riporta indietro una modifica più
   recente**.

Per questo `SET_PARAMS` è una **scrittura condizionata** (compare-and-set), la stessa idea degli
ETag in HTTP. La centralina tiene una `revision` che cresce a ogni modifica, e accetta una
scrittura solo se `expected_revision` è quella corrente:

- `expected == revision`: se i valori sono nei limiti, applica, porta la revisione a `revision
  + 1` e **salva prima di rispondere** `OK`. Una risposta `OK` vuol dire «è sulla flash», non
  «è in memoria».
- `expected + 1 == revision`, e i valori coincidono con quelli dell'ultima modifica: è un nuovo
  tentativo della modifica già applicata. Risponde `ALREADY_APPLIED` e non tocca niente.
- altrimenti risponde `CONFLICT` con la revisione corrente, e l'app deve rileggere lo stato.

## Esito incerto

Se la connessione cade fra la scrittura e la notifica della risposta, l'app **non sa** se la
modifica è stata applicata. Non la mostra come confermata, e non la dà per persa: la mostra
come **incerta**. Alla riconnessione ripete la stessa richiesta, con la stessa
`expected_revision`, e la risposta scioglie il dubbio:
- `OK`: la prima volta non era arrivata;
- `ALREADY_APPLIED`: era arrivata;
- `CONFLICT`: nel frattempo è cambiato qualcosa, e l'app rilegge lo stato.

Il comando `DEBUG_APPLY_THEN_REBOOT` esiste per produrre davvero questo caso: applica, salva e
riavvia la centralina **senza rispondere**. È compilato solo nel firmware di debug.
