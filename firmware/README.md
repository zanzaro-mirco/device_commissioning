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

## Costruire e caricare

Serve ESP-IDF 6.1 ([guida di installazione](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/index.html)).
Da un terminale di ESP-IDF, nella cartella `firmware`:

```bash
idf.py build
idf.py -p COM5 flash monitor
```

Il firmware di debug si costruisce in una cartella a parte, così i due non si mescolano:

```bash
idf.py -B build-debug -D SDKCONFIG=build-debug/sdkconfig -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.debug" -p COM5 flash monitor
```

`COM5` è un esempio: la porta giusta si vede in Gestione dispositivi quando la scheda è
collegata. All'avvio il monitor scrive la versione del firmware, se i comandi di debug sono
attivi e il nome con cui la scheda si annuncia (`DC-` seguito da quattro cifre esadecimali).

Per ripartire dai valori di fabbrica si cancella la flash con `idf.py erase-flash`.

## La prova con l'hardware

La CI compila i due firmware ma non li può provare. La prova si fa a mano con il firmware di
debug e l'app sul telefono (Galaxy S20), e controlla i quattro punti del criterio di fatto:

1. l'app trova la centralina, si collega e legge le informazioni del dispositivo;
2. un parametro cambiato sopravvive al riavvio della scheda (tasto `RST`);
3. la telemetria arriva per notifica;
4. con il comando di guasto l'app mostra l'esito incerto, e il nuovo tentativo dopo la
   riconnessione risponde `ALREADY_APPLIED` senza applicare due volte.

L'esito della prova, con la data, si annota qui.
