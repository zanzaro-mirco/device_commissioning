package it.mircozanzaro.ble_bridge

/**
 * Il GATT di Android esegue un'operazione alla volta: una seconda scrittura
 * chiesta prima che arrivi la callback della prima viene rifiutata, oppure
 * accettata e persa, a seconda della versione e del produttore del telefono.
 * Questa coda le mette in fila e ne avvia una sola per volta.
 *
 * È Kotlin puro, senza Android, perché la parte difficile da provare è l'ordine
 * degli eventi, non il Bluetooth. La usa un solo thread (il principale): le
 * callback del GATT arrivano su un thread di sistema e il chiamante le riporta
 * lì prima di chiamare [complete].
 */
class GattOperationQueue(
    private val timer: OperationTimer,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    private class Operation(
        val key: String,
        val start: () -> Boolean,
        val onResult: (GattResult) -> Unit,
    )

    private val waiting = ArrayDeque<Operation>()
    private var current: Operation? = null
    private var currentTimeout: Cancellable? = null

    val isIdle: Boolean
        get() = current == null && waiting.isEmpty()

    /**
     * Mette in coda un'operazione. [key] identifica la callback che la chiude
     * (per esempio "write:<uuid>"); [start] la avvia e restituisce false se il
     * sistema l'ha rifiutata subito.
     */
    fun enqueue(key: String, start: () -> Boolean, onResult: (GattResult) -> Unit) {
        waiting.addLast(Operation(key, start, onResult))
        if (current == null) startNext()
    }

    /**
     * Chiude l'operazione in corso. Una callback con una chiave diversa da
     * quella dell'operazione in corso si ignora: è la risposta tardiva di
     * un'operazione già scaduta, e chiudere con lei quella successiva vorrebbe
     * dire dare a una scrittura l'esito di un'altra.
     */
    fun complete(key: String, result: GattResult) {
        val operation = current ?: return
        if (operation.key != key) return
        finish(operation, result)
    }

    /** La connessione è caduta: fallisce l'operazione in corso e quelle in attesa. */
    fun cancelAll(detail: String) {
        val failure = GattResult.Failure(GattResult.Failure.Kind.DISCONNECTED, detail)
        val operation = current
        val pending = waiting.toList()
        waiting.clear()
        if (operation != null) {
            current = null
            currentTimeout?.cancel()
            currentTimeout = null
            operation.onResult(failure)
        }
        pending.forEach { it.onResult(failure) }
    }

    private fun startNext() {
        val operation = waiting.removeFirstOrNull() ?: return
        current = operation
        currentTimeout = timer.schedule(timeoutMs) {
            if (current === operation) {
                finish(operation, GattResult.Failure(GattResult.Failure.Kind.TIMEOUT, operation.key))
            }
        }
        val started = try {
            operation.start()
        } catch (error: Exception) {
            false
        }
        if (!started && current === operation) {
            finish(operation, GattResult.Failure(GattResult.Failure.Kind.NOT_STARTED, operation.key))
        }
    }

    private fun finish(operation: Operation, result: GattResult) {
        current = null
        currentTimeout?.cancel()
        currentTimeout = null
        operation.onResult(result)
        if (current == null) startNext()
    }

    companion object {
        /** Più lungo di un giro normale, più corto della pazienza di chi guarda. */
        const val DEFAULT_TIMEOUT_MS = 5_000L
    }
}

sealed class GattResult {
    class Success(val value: ByteArray? = null) : GattResult()

    data class Failure(val kind: Kind, val detail: String) : GattResult() {
        enum class Kind {
            /** Nessuna callback in tempo: i byte possono essere partiti o no. */
            TIMEOUT,

            /** Il sistema ha rifiutato di avviare l'operazione: niente è partito. */
            NOT_STARTED,

            /** La connessione è caduta: i byte possono essere partiti o no. */
            DISCONNECTED,

            /** La callback è arrivata con uno stato GATT di errore. */
            STATUS,
        }
    }
}

fun interface Cancellable {
    fun cancel()
}

fun interface OperationTimer {
    fun schedule(delayMs: Long, action: () -> Unit): Cancellable
}
