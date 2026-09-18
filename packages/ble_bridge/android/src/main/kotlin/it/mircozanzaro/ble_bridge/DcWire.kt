package it.mircozanzaro.ble_bridge

/** La trama, codificata e verificata dal C di `native/dc_core` via JNI. */
object DcWire {
    init {
        System.loadLibrary("dc_wire_jni")
    }

    /** Gli stessi valori di `dc_frame_result`. */
    enum class Error(val code: Int, val description: String) {
        TOO_SHORT(1, "trama troppo corta"),
        BAD_LENGTH(2, "lunghezza incoerente"),
        BAD_CRC(3, "CRC sbagliato"),
        UNSUPPORTED_VERSION(4, "versione del protocollo non supportata"),
        UNKNOWN(-1, "errore sconosciuto");

        companion object {
            fun of(code: Int) = entries.firstOrNull { it.code == code } ?: UNKNOWN
        }
    }

    sealed class Decoded {
        class Valid(val type: Int, val seq: Int, val payload: ByteArray) : Decoded()

        data class Invalid(val error: Error) : Decoded()
    }

    fun encode(type: Int, seq: Int, payload: ByteArray): ByteArray =
        nativeEncode(type, seq, payload)
            ?: throw IllegalArgumentException("contenuto di ${payload.size} byte: troppo lungo")

    fun decode(bytes: ByteArray): Decoded {
        val raw = nativeDecode(bytes)
        val result = raw[0].toInt() and 0xFF
        if (result != 0) return Decoded.Invalid(Error.of(result))
        return Decoded.Valid(
            type = raw[1].toInt() and 0xFF,
            seq = raw[2].toInt() and 0xFF,
            payload = raw.copyOfRange(3, raw.size),
        )
    }

    @JvmStatic
    private external fun nativeEncode(type: Int, seq: Int, payload: ByteArray): ByteArray?

    @JvmStatic
    private external fun nativeDecode(bytes: ByteArray): ByteArray
}
