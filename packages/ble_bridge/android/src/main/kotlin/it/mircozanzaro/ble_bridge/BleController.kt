package it.mircozanzaro.ble_bridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout

/**
 * Il Bluetooth vero: scansione, connessione, notifiche, scritture. Tutto quello
 * che tocca il GATT passa da una [GattOperationQueue] per connessione, e tutto
 * gira sul thread principale: le callback del GATT arrivano su un thread di
 * sistema e vengono riportate lì con [main].
 *
 * I permessi li controlla il chiamante: qui un permesso mancante è una
 * SecurityException, che diventa un errore [BleErrors.PERMISSION].
 */
@SuppressLint("MissingPermission")
internal class BleController(
    private val context: Context,
    private val emit: (BleEvent) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val timer = OperationTimer { delayMs, action ->
        val runnable = Runnable(action)
        main.postDelayed(runnable, delayMs)
        Cancellable { main.removeCallbacks(runnable) }
    }
    private val connections = mutableMapOf<String, Connection>()
    private var scanCallback: ScanCallback? = null

    private val adapter
        get() = context.getSystemService(BluetoothManager::class.java)?.adapter

    fun adapterState(permissionsGranted: Boolean): AdapterState {
        val adapter = adapter ?: return AdapterState.UNAVAILABLE
        if (!permissionsGranted) return AdapterState.UNAUTHORIZED
        return if (adapter.isEnabled) AdapterState.ON else AdapterState.OFF
    }

    fun startScan() = guarded {
        val scanner = adapter?.bluetoothLeScanner
            ?: throw FlutterError(BleErrors.UNAVAILABLE, "Bluetooth spento o assente")
        stopScan()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                emit(
                    ScanResultEvent(
                        deviceId = result.device.address,
                        name = result.scanRecord?.deviceName,
                        rssi = result.rssi.toLong(),
                    )
                )
            }

            override fun onScanFailed(errorCode: Int) {
                scanCallback = null
            }
        }
        // Il filtro sul servizio lo applica il chip Bluetooth, non l'app: il
        // telefono non si sveglia per ogni cuffia e ogni bilancia del palazzo.
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(CommissioningGatt.SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, callback)
        scanCallback = callback
    }

    fun stopScan() = guarded {
        val callback = scanCallback ?: return@guarded
        scanCallback = null
        adapter?.bluetoothLeScanner?.stopScan(callback)
    }

    suspend fun connect(deviceId: String) {
        val adapter = adapter ?: throw FlutterError(BleErrors.UNAVAILABLE, "Bluetooth assente")
        connections.remove(deviceId)?.close("nuova connessione")
        val device = try {
            adapter.getRemoteDevice(deviceId)
        } catch (error: IllegalArgumentException) {
            throw FlutterError(BleErrors.NOT_CONNECTED, "indirizzo non valido: $deviceId")
        }
        val connection = Connection(device)
        connections[deviceId] = connection
        try {
            withTimeout(CONNECT_TIMEOUT_MS) { connection.open() }
        } catch (error: TimeoutCancellationException) {
            connection.close("tempo scaduto durante la connessione")
            throw FlutterError(BleErrors.TIMEOUT, "la centralina non ha risposto alla connessione")
        }
    }

    fun disconnect(deviceId: String) {
        connections.remove(deviceId)?.close("chiusa dall'app")
    }

    suspend fun readInfo(deviceId: String): WireFrame {
        val connection = connection(deviceId)
        val bytes = connection.read(CommissioningGatt.INFO)
        return when (val decoded = DcWire.decode(bytes)) {
            is DcWire.Decoded.Valid -> WireFrame(decoded.type.toLong(), decoded.seq.toLong(), decoded.payload)
            is DcWire.Decoded.Invalid -> throw FlutterError(BleErrors.GATT, decoded.error.description)
        }
    }

    suspend fun sendFrame(deviceId: String, frame: WireFrame) {
        val connection = connection(deviceId)
        val bytes = DcWire.encode(frame.type.toInt(), frame.seq.toInt(), frame.payload)
        connection.write(CommissioningGatt.COMMAND, bytes)
    }

    fun closeAll() {
        stopScan()
        connections.values.toList().forEach { it.close("plugin staccato") }
        connections.clear()
    }

    private fun connection(deviceId: String): Connection =
        connections[deviceId] ?: throw FlutterError(BleErrors.NOT_CONNECTED, "nessuna connessione verso $deviceId")

    private inline fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (error: SecurityException) {
        throw FlutterError(BleErrors.PERMISSION, error.message)
    }

    private inner class Connection(private val device: BluetoothDevice) {
        private val deviceId: String = device.address
        private val queue = GattOperationQueue(timer)
        private val connected = CompletableDeferred<Unit>()
        private var gatt: BluetoothGatt? = null
        private var closed = false

        private val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                main.post {
                    if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                        connected.complete(Unit)
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        // Lo stato 133 (GATT_ERROR) è il più comune e il meno
                        // informativo: una centralina spenta o fuori portata.
                        close("disconnessa (stato GATT $status)")
                    }
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                main.post { queue.complete(DISCOVER, result(status)) }
            }

            override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                main.post { queue.complete("notify:${descriptor.characteristic.uuid}", result(status)) }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                main.post { queue.complete("write:${characteristic.uuid}", result(status)) }
            }

            // Da Android 13 il valore arriva come parametro; prima si leggeva
            // dalla caratteristica, che nel frattempo poteva essere cambiata.
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                main.post { queue.complete("read:${characteristic.uuid}", result(status, value)) }
            }

            @Deprecated("Solo prima di Android 13")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                @Suppress("DEPRECATION")
                val value = characteristic.value?.copyOf() ?: ByteArray(0)
                main.post { queue.complete("read:${characteristic.uuid}", result(status, value)) }
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                val copy = value.copyOf()
                main.post { onNotification(characteristic.uuid, copy) }
            }

            @Deprecated("Solo prima di Android 13")
            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
                @Suppress("DEPRECATION")
                val copy = characteristic.value?.copyOf() ?: return
                main.post { onNotification(characteristic.uuid, copy) }
            }
        }

        /** Collega, scopre i servizi e accende le due notifiche. */
        suspend fun open() {
            gatt = guarded { device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) }
            connected.await()
            run(DISCOVER) { gatt?.discoverServices() == true }
            if (service() == null) {
                close("servizio di messa in servizio assente")
                throw FlutterError(BleErrors.GATT, "il dispositivo non espone il servizio della centralina")
            }
            enableNotifications(CommissioningGatt.RESPONSE)
            enableNotifications(CommissioningGatt.TELEMETRY)
            emit(ConnectionEvent(deviceId = deviceId, connected = true))
        }

        suspend fun read(uuid: java.util.UUID): ByteArray {
            val characteristic = characteristic(uuid)
            return run("read:$uuid") { gatt?.readCharacteristic(characteristic) == true } ?: ByteArray(0)
        }

        suspend fun write(uuid: java.util.UUID, bytes: ByteArray) {
            val characteristic = characteristic(uuid)
            run("write:$uuid") {
                val gatt = gatt ?: return@run false
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(
                        characteristic,
                        bytes,
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                    ) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    @Suppress("DEPRECATION")
                    characteristic.value = bytes
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(characteristic)
                }
            }
        }

        fun close(reason: String) {
            if (closed) return
            closed = true
            connections.remove(deviceId, this)
            queue.cancelAll(reason)
            connected.completeExceptionally(FlutterError(BleErrors.DISCONNECTED, reason))
            gatt?.let {
                guarded { it.disconnect() }
                guarded { it.close() }
            }
            gatt = null
            emit(ConnectionEvent(deviceId = deviceId, connected = false, reason = reason))
        }

        private suspend fun enableNotifications(uuid: java.util.UUID) {
            val characteristic = characteristic(uuid)
            val descriptor = characteristic.getDescriptor(CommissioningGatt.CLIENT_CONFIG)
                ?: throw FlutterError(BleErrors.GATT, "manca il descrittore delle notifiche su $uuid")
            run("notify:$uuid") {
                val gatt = gatt ?: return@run false
                if (!gatt.setCharacteristicNotification(characteristic, true)) return@run false
                val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, enable) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = enable
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(descriptor)
                }
            }
        }

        private fun onNotification(uuid: java.util.UUID, bytes: ByteArray) {
            val source = when (uuid) {
                CommissioningGatt.RESPONSE -> Characteristic.RESPONSE
                CommissioningGatt.TELEMETRY -> Characteristic.TELEMETRY
                else -> return
            }
            when (val decoded = DcWire.decode(bytes)) {
                is DcWire.Decoded.Valid -> emit(
                    FrameEvent(
                        deviceId = deviceId,
                        source = source,
                        frame = WireFrame(decoded.type.toLong(), decoded.seq.toLong(), decoded.payload),
                    )
                )
                is DcWire.Decoded.Invalid -> emit(
                    CorruptedFrameEvent(deviceId = deviceId, reason = decoded.error.description)
                )
            }
        }

        private fun service() = gatt?.getService(CommissioningGatt.SERVICE)

        private fun characteristic(uuid: java.util.UUID): BluetoothGattCharacteristic =
            service()?.getCharacteristic(uuid)
                ?: throw FlutterError(BleErrors.GATT, "caratteristica $uuid assente")

        /** Accoda un'operazione e aspetta la sua callback. */
        private suspend fun run(key: String, start: () -> Boolean): ByteArray? =
            suspendCancellableCoroutine { continuation ->
                queue.enqueue(key, { guarded(start) }) { result ->
                    when (result) {
                        is GattResult.Success -> continuation.resume(result.value)
                        is GattResult.Failure -> continuation.resumeWithException(result.toFlutterError())
                    }
                }
            }
    }

    private fun result(status: Int, value: ByteArray? = null): GattResult =
        if (status == BluetoothGatt.GATT_SUCCESS) {
            GattResult.Success(value)
        } else {
            GattResult.Failure(GattResult.Failure.Kind.STATUS, "stato GATT $status")
        }

    private companion object {
        const val DISCOVER = "discover"
        const val CONNECT_TIMEOUT_MS = 15_000L
    }
}

/**
 * La traduzione che conta per il protocollo: solo un rifiuto certo diventa
 * [BleErrors.REJECTED]. Tempo scaduto e connessione caduta lasciano
 * l'esito sconosciuto, e il Dart li tratta come incerti.
 */
internal fun GattResult.Failure.toFlutterError(): FlutterError = when (kind) {
    GattResult.Failure.Kind.NOT_STARTED -> FlutterError(BleErrors.REJECTED, "operazione non avviata: $detail")
    GattResult.Failure.Kind.STATUS -> FlutterError(BleErrors.REJECTED, detail)
    GattResult.Failure.Kind.TIMEOUT -> FlutterError(BleErrors.TIMEOUT, "nessuna risposta per $detail")
    GattResult.Failure.Kind.DISCONNECTED -> FlutterError(BleErrors.DISCONNECTED, detail)
}
