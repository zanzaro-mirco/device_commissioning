# app

L'app dell'installatore, in Flutter con Cubit: trova le centraline, si collega, mostra la
temperatura e i parametri confermati, e scrive i parametri nuovi. Oggi gira su Android; il lato
Swift del plugin, per iOS e macOS, è la voce 5 del piano.

```
lib/link/     DeviceLink: quello che l'app chiede al Bluetooth, e la versione sopra il plugin
lib/scan/     ricerca delle centraline: permessi, Bluetooth spento, elenco per vicinanza
lib/device/   la centralina collegata: lettura, scrittura, telemetria, esito incerto
```

## Quello che l'app promette

- **Mostra come valore corrente solo quello che la centralina ha confermato.** Una scrittura
  senza risposta compare a parte, come «Modifica non confermata», e non sostituisce il valore
  confermato.
- **Finché una scrittura è incerta, non ne parte un'altra.** Prima si scopre se la prima è
  arrivata.
- **La verifica ripete la stessa richiesta**, con la stessa revisione attesa, anche dopo una
  riconnessione. La centralina risponde `ALREADY_APPLIED` se la prima era arrivata, `OK` se no,
  `CONFLICT` se nel frattempo un altro dispositivo ha cambiato i parametri. In nessun caso la
  modifica viene applicata due volte.

## Provarla

```bash
flutter pub get
flutter test
flutter run
```

I test girano senza hardware: `test/support/fake_device_link.dart` appoggia l'app alla
centralina finta di `commissioning_protocol`, con le risposte perse, le connessioni cadute e i
riavvii.

Nell'app di debug c'è un pulsante in più, «Prova: applica e riavvia senza rispondere». Manda il
comando di guasto, che solo il firmware di debug accetta (vedi
[`firmware/README.md`](../firmware/README.md)). Serve alla prova con l'hardware.
