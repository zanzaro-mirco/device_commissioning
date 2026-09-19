# firmware

La centralina: ESP-IDF 6.1 e NimBLE su una ESP32-S3 (la scheda usata è una DevKitC-1 N16R8,
con 16 MB di flash). Espone il servizio GATT di [`protocol/PROTOCOL.md`](../protocol/PROTOCOL.md),
salva i parametri su NVS prima di confermarli e manda una temperatura simulata ogni due secondi.

La logica del protocollo non è qui: è [`native/dc_core`](../native/dc_core), lo stesso codice
dei test sul PC e del plugin Android, incluso come componente di ESP-IDF.

```
main/main.c    il task della centralina: comandi, salvataggio, telemetria
main/ble.c     advertising, servizio GATT, notifiche
main/store.c   lo stato su NVS
```

## Due firmware

| | Configurazione | Comando di guasto |
|---|---|---|
| da installare | `sdkconfig.defaults` | no |
| di debug | `sdkconfig.defaults` più `sdkconfig.debug` | `DEBUG_APPLY_THEN_REBOOT` |

Il comando di guasto applica una modifica, la salva e riavvia la scheda senza rispondere: serve
a produrre davvero l'esito incerto nell'app.

## Caricare senza installare ESP-IDF

La CI pubblica i binari dei due firmware come artefatti di ogni esecuzione: `firmware` e
`firmware-debug`. Bastano [uv](https://docs.astral.sh/uv/) ed esptool, che `uvx` esegue senza
installarlo:

```bash
gh run download <id-esecuzione> -n firmware-debug -D firmware-debug
cd firmware-debug
uvx esptool@5.4.0 --chip esp32s3 --port COM8 --baud 460800 write-flash --flash-mode dio --flash-size 16MB --flash-freq 80m 0x0 bootloader/bootloader.bin 0x8000 partition_table/partition-table.bin 0x10000 centralina.bin
```

Gli indirizzi sono quelli di `flasher_args.json`, che accompagna i binari. La scheda va collegata
alla porta USB-C marcata **COM** (il convertitore CH343): da lì esptool la riavvia da solo in
modalità di caricamento, ed escono i messaggi di avvio. `COM8` è la porta del PC su cui è stata
fatta la prova: la propria si vede in Gestione dispositivi.

## Costruire e caricare con ESP-IDF

Serve ESP-IDF 6.1 ([guida di installazione](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/index.html)).
Da un terminale di ESP-IDF, nella cartella `firmware`:

```bash
idf.py build
idf.py -p COM8 flash monitor
```

Il firmware di debug si costruisce in una cartella a parte, così i due non si mescolano:

```bash
idf.py -B build-debug -D SDKCONFIG=build-debug/sdkconfig -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.debug" -p COM8 flash monitor
```

All'avvio la scheda scrive la versione del firmware, se i comandi di debug sono attivi e il nome
con cui si annuncia (`DC-` seguito dalle ultime quattro cifre dell'indirizzo Bluetooth).

Per ripartire dai valori di fabbrica si cancella la flash con `idf.py erase-flash`, oppure con
`uvx esptool@5.4.0 --chip esp32s3 --port COM8 erase-flash`.

## La prova con l'hardware

La CI compila i due firmware ma non li può provare. La prova si fa a mano con il firmware di
debug e l'app di debug sul telefono (Galaxy S20, `flutter run` dalla cartella `app`), e
controlla i quattro punti del criterio di fatto:

1. l'app trova la centralina, si collega e legge le informazioni del dispositivo;
2. un parametro cambiato sopravvive al riavvio della scheda (tasto `RST`);
3. la telemetria arriva per notifica;
4. con il pulsante «Prova: applica e riavvia senza rispondere» l'app mostra «Modifica non
   confermata» e lascia come valore corrente quello di prima; «Verifica» si ricollega, e la
   centralina risponde `ALREADY_APPLIED` senza applicare due volte (la revisione avanza di uno
   solo).

### Esito: 19 settembre 2026, tutti e quattro i punti superati

Firmware di debug dalla CI (ESP-IDF 6.1) su ESP32-S3 DevKitC-1 N16R8, app di debug su Galaxy S20
con Android 13. Ogni punto è confermato da due lati: quello che si vede nell'app e i messaggi
della scheda sulla seriale.

| Punto | Nell'app | Sulla scheda |
|---|---|---|
| 1 | DC-924E trovata; «Collegata», firmware 0.1.0, protocollo 1, 20,0 °C comfort, revisione 0 | connessione; il telefono scopre il servizio e accende le due notifiche |
| 2 | 22,0 °C economia salvato (revisione 1); dopo `RST` e «Ricollega», di nuovo 22,0 °C economia, revisione 1 | dopo il riavvio: «stato caricato: revisione 1» |
| 3 | la temperatura sale di un decimo ogni due secondi fino a 19,0 °C (economia: tre gradi sotto il setpoint) | una notifica ogni due secondi |
| 4 | riquadro «Modifica non confermata» e «Scollegata»; dopo «Verifica», 21,0 °C comfort alla revisione 2, non 3 | «modifica salvata, riavvio senza rispondere», poi «stato caricato: revisione 2» |

Il punto 4 è stato ripetuto (20,0 °C comfort, dalla revisione 2 alla 3) registrando lo schermo
del telefono, perché la prima volta il messaggio finale non era stato annotato: il riquadro
incerto mostrava 20,0 °C mentre il valore confermato restava 21,0 °C alla revisione 2, e dopo
«Verifica» sono comparsi «La modifica era già arrivata: confermata, senza applicarla due volte» e
la revisione 3. Un `OK` avrebbe portato alla revisione 4, un conflitto avrebbe mostrato un altro
messaggio.

La prova ha trovato un solo difetto, di aspetto: nel selettore della modalità «Comfort» andava a
capo. È corretto nello stesso commit che registra la prova.
