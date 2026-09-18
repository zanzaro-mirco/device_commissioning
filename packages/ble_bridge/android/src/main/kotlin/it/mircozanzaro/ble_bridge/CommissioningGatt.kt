package it.mircozanzaro.ble_bridge

import java.util.UUID

/** Gli UUID di `protocol/PROTOCOL.md`: contengono `mircozanzaro` in esadecimale. */
object CommissioningGatt {
    val SERVICE: UUID = UUID.fromString("4d5a0001-6d69-7263-6f7a-616e7a61726f")
    val INFO: UUID = UUID.fromString("4d5a0002-6d69-7263-6f7a-616e7a61726f")
    val COMMAND: UUID = UUID.fromString("4d5a0003-6d69-7263-6f7a-616e7a61726f")
    val RESPONSE: UUID = UUID.fromString("4d5a0004-6d69-7263-6f7a-616e7a61726f")
    val TELEMETRY: UUID = UUID.fromString("4d5a0005-6d69-7263-6f7a-616e7a61726f")

    /** Il descrittore standard con cui si accendono le notifiche. */
    val CLIENT_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
}

/** I codici degli errori che arrivano al Dart come PlatformException. */
object BleErrors {
    /** Nessuna connessione verso quel dispositivo: la richiesta non è partita. */
    const val NOT_CONNECTED = "not_connected"

    /** La connessione è caduta durante l'operazione: l'esito è sconosciuto. */
    const val DISCONNECTED = "disconnected"

    /**
     * L'operazione è stata rifiutata con certezza: dal sistema prima di partire,
     * o dalla centralina a livello ATT. Niente è stato accettato.
     */
    const val REJECTED = "rejected"

    /** L'operazione non si è chiusa in tempo: l'esito è sconosciuto. */
    const val TIMEOUT = "timeout"

    const val PERMISSION = "permission"
    const val UNAVAILABLE = "unavailable"
    const val GATT = "gatt_error"
}
