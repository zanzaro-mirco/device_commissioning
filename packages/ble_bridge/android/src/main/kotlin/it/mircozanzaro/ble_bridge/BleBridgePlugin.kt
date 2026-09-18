package it.mircozanzaro.ble_bridge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred

class BleBridgePlugin :
    FlutterPlugin,
    ActivityAware,
    BleHostApi,
    PluginRegistry.RequestPermissionsResultListener {

    private var controller: BleController? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionRequest: CompletableDeferred<PermissionState>? = null
    private var sink: PigeonEventSink<BleEvent>? = null
    private lateinit var appContext: android.content.Context

    private val events = object : EventsStreamHandler() {
        override fun onListen(p0: Any?, sink: PigeonEventSink<BleEvent>) {
            this@BleBridgePlugin.sink = sink
        }

        override fun onCancel(p0: Any?) {
            sink = null
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        controller = BleController(appContext) { event -> sink?.success(event) }
        BleHostApi.setUp(binding.binaryMessenger, this)
        EventsStreamHandler.register(binding.binaryMessenger, events)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controller?.closeAll()
        controller = null
        BleHostApi.setUp(binding.binaryMessenger, null)
    }

    // ---- Permessi ------------------------------------------------------------

    private val requiredPermissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            // Fino ad Android 11 la scansione BLE richiede la posizione, perché
            // i beacon possono rivelarla.
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun permissionsGranted(): Boolean = requiredPermissions.all {
        appContext.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    override suspend fun requestPermissions(): PermissionState {
        if (permissionsGranted()) return PermissionState.GRANTED
        val activity = activityBinding?.activity
            ?: throw FlutterError(BleErrors.PERMISSION, "nessuna activity a cui chiedere i permessi")
        permissionRequest?.cancel()
        val request = CompletableDeferred<PermissionState>()
        permissionRequest = request
        activity.requestPermissions(requiredPermissions, PERMISSION_REQUEST_CODE)
        return request.await()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val request = permissionRequest ?: return true
        permissionRequest = null
        val activity = activityBinding?.activity
        request.complete(
            when {
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED } ->
                    PermissionState.GRANTED
                // Dopo un rifiuto, Android smette di mostrare la richiesta e
                // shouldShowRequestPermissionRationale restituisce false: da lì
                // si passa solo dalle impostazioni. È un'euristica, ed è quella
                // che la documentazione di Android indica.
                activity != null && permissions.none { activity.shouldShowRequestPermissionRationale(it) } ->
                    PermissionState.PERMANENTLY_DENIED
                else -> PermissionState.DENIED
            }
        )
        return true
    }

    // ---- BleHostApi ----------------------------------------------------------

    override fun adapterState(): AdapterState = controller().adapterState(permissionsGranted())

    override fun startScan() = controller().startScan()

    override fun stopScan() = controller().stopScan()

    override suspend fun connect(deviceId: String) = controller().connect(deviceId)

    override fun disconnect(deviceId: String) = controller().disconnect(deviceId)

    override suspend fun readInfo(deviceId: String): WireFrame = controller().readInfo(deviceId)

    override suspend fun sendFrame(deviceId: String, frame: WireFrame) = controller().sendFrame(deviceId, frame)

    private fun controller(): BleController =
        controller ?: throw FlutterError(BleErrors.UNAVAILABLE, "plugin non collegato")

    // ---- ActivityAware -------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    private companion object {
        const val PERMISSION_REQUEST_CODE = 0x4d5a
    }
}
