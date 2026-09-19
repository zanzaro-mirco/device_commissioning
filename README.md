# device_commissioning

La messa in servizio di una centralina via Bluetooth LE, dal firmware all'app. È lo stesso
gesto delle app con cui un installatore configura un'automazione, un regolatore o una pompa:
trovare il dispositivo, collegarsi, leggere e cambiare i parametri, e sapere con certezza se
una modifica è arrivata.

> **Stato.** Il progetto è la voce 3 del piano di sviluppo del portfolio. Ci sono il nucleo del
> protocollo in C, il protocollo lato app in Dart, il plugin Bluetooth per Android (Kotlin,
> Pigeon e il C via JNI), l'app Flutter e il firmware per ESP32-S3. La prova con la scheda vera e
> un Galaxy S20 è superata ([esito](firmware/README.md#esito-19-settembre-2026-tutti-e-quattro-i-punti-superati)).
> Arriva il lato Swift, per iOS e macOS.

```
protocol/                          il contratto: specifica e vettori di prova, letti da C e da Dart
native/dc_core/                    trama, CRC, messaggi e logica della centralina in C:
                                   un solo codice per il firmware, per Android (JNI) e per iOS e macOS
packages/commissioning_protocol/   il protocollo lato app: esiti delle scritture, esito incerto,
                                   centralina finta per i test
packages/ble_bridge/               il plugin Bluetooth: Pigeon, Kotlin, coda GATT, C via JNI
firmware/                          la centralina: ESP-IDF e NimBLE su ESP32-S3
app/                               l'app dell'installatore: Flutter e Cubit
```

## Il punto del progetto

Una scrittura via Bluetooth può finire in tre modi, non in due: riuscita, fallita, oppure
**incerta**, quando la connessione cade prima della risposta. Il protocollo è costruito perché
l'app sappia distinguere il terzo caso e risolverlo senza rischi. Per farlo usa una scrittura
condizionata a una revisione: un nuovo tentativo non applica due volte, e un tentativo arrivato
in ritardo non cancella una modifica più recente. I dettagli sono in
[`protocol/PROTOCOL.md`](protocol/PROTOCOL.md), le scelte in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Provare quello che c'è

```bash
cmake -S native/dc_core -B native/dc_core/out
cmake --build native/dc_core/out
ctest --test-dir native/dc_core/out --output-on-failure
```

E il protocollo lato app:

```bash
cd packages/commissioning_protocol
dart pub get
dart test
```

L'app si prova senza hardware, contro la centralina finta:

```bash
cd app
flutter test
```

Il firmware si costruisce con ESP-IDF: le istruzioni sono in
[`firmware/README.md`](firmware/README.md).

I vettori si rigenerano con `python protocol/tool/generate_vectors.py`.

## Licenza

MIT
