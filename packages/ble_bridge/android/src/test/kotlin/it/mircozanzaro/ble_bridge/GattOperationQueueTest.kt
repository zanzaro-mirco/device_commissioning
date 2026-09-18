package it.mircozanzaro.ble_bridge

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Un orologio finto: le scadenze scattano solo quando il test fa avanzare il tempo. */
private class FakeTimer : OperationTimer {
    private class Entry(val at: Long, val action: () -> Unit, var cancelled: Boolean = false)

    private val entries = mutableListOf<Entry>()
    var now = 0L

    override fun schedule(delayMs: Long, action: () -> Unit): Cancellable {
        val entry = Entry(now + delayMs, action)
        entries += entry
        return Cancellable { entry.cancelled = true }
    }

    fun advance(ms: Long) {
        now += ms
        val due = entries.filter { !it.cancelled && it.at <= now }
        entries.removeAll(due)
        due.forEach { it.action() }
    }
}

class GattOperationQueueTest {
    private val timer = FakeTimer()
    private val queue = GattOperationQueue(timer, timeoutMs = 1_000)
    private val started = mutableListOf<String>()
    private val results = mutableMapOf<String, GattResult>()

    private fun enqueue(key: String, accept: Boolean = true) {
        queue.enqueue(
            key,
            start = {
                started += key
                accept
            },
            onResult = { results[key] = it },
        )
    }

    @Test
    fun `tre operazioni chieste insieme partono una alla volta, nell'ordine`() {
        enqueue("write:a")
        enqueue("write:b")
        enqueue("read:c")
        assertEquals(listOf("write:a"), started, "solo la prima deve partire")

        queue.complete("write:a", GattResult.Success())
        assertEquals(listOf("write:a", "write:b"), started)

        queue.complete("write:b", GattResult.Success())
        queue.complete("read:c", GattResult.Success(byteArrayOf(1)))
        assertEquals(listOf("write:a", "write:b", "read:c"), started)
        assertTrue(queue.isIdle)
        assertEquals(3, results.size)
    }

    @Test
    fun `un'operazione che scade fallisce e lascia partire la successiva`() {
        enqueue("write:a")
        enqueue("write:b")
        timer.advance(1_000)
        assertEquals(GattResult.Failure(GattResult.Failure.Kind.TIMEOUT, "write:a"), results["write:a"])
        assertEquals(listOf("write:a", "write:b"), started)
    }

    @Test
    fun `la callback tardiva di un'operazione scaduta non chiude quella dopo`() {
        enqueue("write:a")
        enqueue("write:b")
        timer.advance(1_000)
        // Arriva ora la callback della prima: la coda sta aspettando la seconda.
        queue.complete("write:a", GattResult.Success())
        assertEquals(null, results["write:b"], "la seconda non deve avere l'esito della prima")

        queue.complete("write:b", GattResult.Success())
        assertIs<GattResult.Success>(results["write:b"])
    }

    @Test
    fun `un'operazione rifiutata dal sistema fallisce subito e la coda prosegue`() {
        enqueue("write:a", accept = false)
        enqueue("write:b")
        assertEquals(GattResult.Failure.Kind.NOT_STARTED, (results["write:a"] as GattResult.Failure).kind)
        assertEquals(listOf("write:a", "write:b"), started)
    }

    @Test
    fun `un'eccezione all'avvio è un rifiuto, non un blocco della coda`() {
        queue.enqueue("write:a", start = { error("GATT chiuso") }, onResult = { results["write:a"] = it })
        enqueue("write:b")
        assertIs<GattResult.Failure>(results["write:a"])
        assertEquals(listOf("write:b"), started)
    }

    @Test
    fun `la connessione caduta fa fallire l'operazione in corso e quelle in attesa`() {
        enqueue("write:a")
        enqueue("write:b")
        enqueue("write:c")
        queue.cancelAll("connessione caduta")
        assertEquals(
            listOf("write:a", "write:b", "write:c").map {
                GattResult.Failure(GattResult.Failure.Kind.DISCONNECTED, "connessione caduta")
            },
            listOf("write:a", "write:b", "write:c").map { results[it] },
        )
        assertEquals(listOf("write:a"), started, "le operazioni in attesa non devono partire")
        assertTrue(queue.isIdle)
    }

    @Test
    fun `un'operazione accodata dentro l'esito di un'altra parte dopo di lei`() {
        queue.enqueue("write:a", start = { started += "write:a"; true }) {
            results["write:a"] = it
            enqueue("write:b")
        }
        queue.complete("write:a", GattResult.Success())
        assertEquals(listOf("write:a", "write:b"), started)
    }

    @Test
    fun `dopo il completamento la scadenza non scatta più`() {
        enqueue("write:a")
        queue.complete("write:a", GattResult.Success())
        timer.advance(5_000)
        assertIs<GattResult.Success>(results["write:a"])
    }
}
