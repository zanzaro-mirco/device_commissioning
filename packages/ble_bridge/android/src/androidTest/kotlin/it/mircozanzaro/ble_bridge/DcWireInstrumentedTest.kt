package it.mircozanzaro.ble_bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Il C di native/dc_core compilato per Android e chiamato via JNI, messo alla
 * prova con gli stessi vettori dei test sul PC. Gira su un dispositivo o un
 * emulatore: sulla JVM la libreria nativa non si carica.
 *
 * I vettori arrivano come asset del test, presi da protocol/vectors e non
 * copiati (vedi build.gradle.kts).
 */
@RunWith(AndroidJUnit4::class)
class DcWireInstrumentedTest {
    private fun vectors(name: String): List<Map<String, String>> {
        val context = InstrumentationRegistry.getInstrumentation().context
        return context.assets.open(name).bufferedReader().readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { line ->
                line.split(Regex("\\s+")).drop(1).mapNotNull { token ->
                    val equals = token.indexOf('=')
                    if (equals < 0) null else token.substring(0, equals) to token.substring(equals + 1)
                }.toMap()
            }
    }

    private fun hex(text: String): ByteArray =
        if (text == "-") ByteArray(0)
        else ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun ogniTramaDeiVettoriSiDecodificaComeAtteso() {
        val frames = vectors("frames.vec")
        assertTrue("letti solo ${frames.size} vettori", frames.size >= 7)
        for (vector in frames) {
            val name = vector.getValue("name")
            val decoded = DcWire.decode(hex(vector.getValue("bytes")))
            when (val expected = vector.getValue("result")) {
                "ok" -> {
                    decoded as DcWire.Decoded.Valid
                    assertEquals(name, vector.getValue("type").toInt(16), decoded.type)
                    assertEquals(name, vector.getValue("seq").toInt(16), decoded.seq)
                    assertArrayEquals(name, hex(vector.getValue("payload")), decoded.payload)
                }
                else -> {
                    val error = (decoded as DcWire.Decoded.Invalid).error
                    assertEquals(name, expected.uppercase(), error.name)
                }
            }
        }
    }

    @Test
    fun codificareUnaTramaValidaRidaGliStessiByte() {
        for (vector in vectors("frames.vec").filter { it["result"] == "ok" }) {
            val bytes = hex(vector.getValue("bytes"))
            val decoded = DcWire.decode(bytes) as DcWire.Decoded.Valid
            assertArrayEquals(
                vector.getValue("name"),
                bytes,
                DcWire.encode(decoded.type, decoded.seq, decoded.payload),
            )
        }
    }
}
