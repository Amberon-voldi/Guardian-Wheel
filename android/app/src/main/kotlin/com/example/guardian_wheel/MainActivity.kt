package com.mythics.guardian_wheel

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val methodChannelName = "guardian_wheel/wifi_direct/methods"
    private val peersEventChannelName = "guardian_wheel/wifi_direct/events"
    private val stateEventChannelName = "guardian_wheel/wifi_direct/state"

    private val serviceType = "_guardianwheel._tcp"
    private val appMarkerKey = "gw_app"
    private val appMarkerValue = "1"
    private val userIdKey = "gw_user_id"
    private val appNamePrefix = "GW_"

    private val helloMessage = "HELLO_GUARDIAN"
    private val ackMessage = "ACK_GUARDIAN"
    private val handshakePort = 39831

    private val connectTimeoutMs = 15000L
    private val retryDelayMs = 2500L

    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null

    private var peersEventSink: EventChannel.EventSink? = null
    private var stateEventSink: EventChannel.EventSink? = null

    private var receiverRegistered = false
    private var currentUserId: String = ""
    private var bootstrapRequested = false
    private var requestedWifiPanel = false

    private var localServiceInfo: WifiP2pDnsSdServiceInfo? = null
    private var serviceRequest: WifiP2pDnsSdServiceRequest? = null

    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingPermissionContinuation: (() -> Unit)? = null

    private lateinit var permissionLauncher: ActivityResultLauncher<Array<String>>
    private lateinit var wifiPanelLauncher: ActivityResultLauncher<Intent>

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newCachedThreadPool()

    private var connectTimeoutRunnable: Runnable? = null
    private var retryRunnable: Runnable? = null
    private var pendingConnectAddress: String? = null
    private var connectAttemptStartedAtMs: Long = 0L

    private var serverSocket: ServerSocket? = null
    private var serverRunning = false
    private var clientHandshakeRunning = false

    private enum class WifiDirectState {
        IDLE,
        DISCOVERING,
        CONNECTING,
        CONNECTED,
        GO,
        FAILED,
    }

    private var state: WifiDirectState = WifiDirectState.IDLE

    private data class AppPeer(
        val address: String,
        val name: String,
        val userId: String,
        val appMarker: String,
        val status: Int,
        val lastSeenAtMs: Long,
    )

    private val appPeers: MutableMap<String, AppPeer> = mutableMapOf()
    private val pendingDevices: MutableMap<String, WifiP2pDevice> = mutableMapOf()

    private val discoveryTicker = object : Runnable {
        override fun run() {
            if (!bootstrapRequested || state != WifiDirectState.DISCOVERING) {
                return
            }
            discoverPeersInternal()
            pruneStalePeers()
            mainHandler.postDelayed(this, 3000L)
        }
    }

    private val peerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val wifiState = intent.getIntExtra(
                        WifiP2pManager.EXTRA_WIFI_STATE,
                        WifiP2pManager.WIFI_P2P_STATE_DISABLED,
                    )
                    if (wifiState != WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                        if (!bootstrapRequested) {
                            return
                        }
                        transitionState(WifiDirectState.FAILED, "Wi‑Fi Direct disabled")
                        scheduleRetry()
                    } else {
                        maybeContinueBootstrap()
                    }
                }

                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION,
                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION,
                -> {
                    requestPeers()
                    discoverServices()
                }

                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    handleConnectionChanged()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        permissionLauncher = registerForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { result ->
            val granted = areAllRequiredPermissionsGranted(result)
            if (granted) {
                pendingPermissionContinuation?.invoke()
            } else {
                failStart("Required permissions were not granted")
            }
            pendingPermissionContinuation = null
        }

        wifiPanelLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) {
            requestedWifiPanel = false
            if (isWifiEnabled()) {
                maybeContinueBootstrap()
            } else {
                transitionState(WifiDirectState.FAILED, "Wi‑Fi is disabled")
                failStart("Wi‑Fi is disabled")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiP2pManager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        wifiP2pChannel = wifiP2pManager?.initialize(
            this,
            mainLooper,
        ) {
            transitionState(WifiDirectState.FAILED, "Wi‑Fi Direct channel disconnected")
            handleDisconnected("Channel disconnected")
            scheduleRetry()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "startDiscovery" -> {
                        val userId = call.argument<String>("userId")
                        if (userId.isNullOrBlank()) {
                            result.error("INVALID_USER", "userId is required", null)
                        } else {
                            startBootstrap(userId, result)
                        }
                    }

                    "stopDiscovery" -> {
                        stopDiscovery(result)
                    }

                    "connect" -> {
                        val address = call.argument<String>("address")
                        if (address.isNullOrBlank()) {
                            result.error("INVALID_ADDRESS", "Peer address is required", null)
                        } else {
                            connectToPeer(address, result)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, peersEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    peersEventSink = events
                    registerReceiverIfNeeded()
                    emitPeers()
                }

                override fun onCancel(arguments: Any?) {
                    peersEventSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, stateEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    stateEventSink = events
                    emitStateSnapshot()
                }

                override fun onCancel(arguments: Any?) {
                    stateEventSink = null
                }
            })
    }

    override fun onDestroy() {
        clearLoops()
        clearServiceRegistration()
        closeServerSocket()
        unregisterReceiverIfNeeded()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun startBootstrap(userId: String, result: MethodChannel.Result) {
        currentUserId = userId
        bootstrapRequested = true
        pendingStartResult = result
        registerReceiverIfNeeded()

        ensurePermissionsThen {
            ensureWifiEnabledThen {
                ensureWifiDirectInitialized() ?: run {
                    failStart("Wi‑Fi Direct unavailable")
                    return@ensureWifiEnabledThen
                }
                configureDnsSdCallbacks()
                evaluateRoleAndStart()
            }
        }
    }

    private fun maybeContinueBootstrap() {
        if (!bootstrapRequested || currentUserId.isBlank()) {
            return
        }
        ensurePermissionsThen {
            ensureWifiEnabledThen {
                ensureWifiDirectInitialized() ?: run {
                    failStart("Wi‑Fi Direct unavailable")
                    return@ensureWifiEnabledThen
                }
                configureDnsSdCallbacks()
                evaluateRoleAndStart()
            }
        }
    }

    private fun ensureWifiDirectInitialized(): WifiP2pManager.Channel? {
        if (wifiP2pManager == null) {
            wifiP2pManager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        }
        if (wifiP2pChannel == null) {
            wifiP2pChannel = wifiP2pManager?.initialize(
                this,
                mainLooper,
            ) {
                transitionState(WifiDirectState.FAILED, "Wi‑Fi Direct channel disconnected")
                handleDisconnected("Channel disconnected")
                scheduleRetry()
            }
        }
        return wifiP2pChannel
    }

    private fun evaluateRoleAndStart() {
        clearLoops()
        appPeers.clear()
        pendingDevices.clear()
        emitPeers()

        if (shouldBecomeGroupOwner()) {
            becomeGroupOwner()
        } else {
            startClientDiscovery()
        }
    }

    private fun shouldBecomeGroupOwner(): Boolean {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return false
        val activeNetwork = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    @SuppressLint("MissingPermission")
    private fun becomeGroupOwner() {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            transitionState(WifiDirectState.FAILED, "Wi‑Fi Direct unavailable")
            failStart("Wi‑Fi Direct unavailable")
            return
        }
        if (!hasWifiDirectPermission()) {
            transitionState(WifiDirectState.FAILED, "Permissions missing")
            failStart("Permissions missing")
            return
        }

        registerLocalService(currentUserId)
        registerServiceRequest()

        manager.createGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                transitionState(WifiDirectState.GO, "Became Group Owner")
                emitCallback("onBecameGO")
                startServerHandshakeLoop()
                completeStartIfPending()
            }

            override fun onFailure(reason: Int) {
                if (reason == WifiP2pManager.BUSY || reason == WifiP2pManager.ERROR) {
                    transitionState(WifiDirectState.GO, "Using existing owner session")
                    emitCallback("onBecameGO")
                    startServerHandshakeLoop()
                    completeStartIfPending()
                    return
                }
                transitionState(WifiDirectState.FAILED, "createGroup failed: $reason")
                failStart("Unable to become Group Owner ($reason)")
                scheduleRetry()
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun startClientDiscovery() {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            transitionState(WifiDirectState.FAILED, "Wi‑Fi Direct unavailable")
            failStart("Wi‑Fi Direct unavailable")
            return
        }
        if (!hasWifiDirectPermission()) {
            transitionState(WifiDirectState.FAILED, "Permissions missing")
            failStart("Permissions missing")
            return
        }

        registerLocalService(currentUserId)
        registerServiceRequest()
        transitionState(WifiDirectState.DISCOVERING, "Discovering peers")

        manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                discoverServices()
                requestPeers()
                mainHandler.post(discoveryTicker)
                completeStartIfPending()
            }

            override fun onFailure(reason: Int) {
                if (reason == WifiP2pManager.BUSY) {
                    transitionState(
                        WifiDirectState.DISCOVERING,
                        "Discovery busy; continuing with existing discovery session",
                    )
                    requestPeers()
                    discoverServices()
                    mainHandler.post(discoveryTicker)
                    completeStartIfPending()
                    return
                }
                transitionState(WifiDirectState.FAILED, "Discovery failed: $reason")
                failStart("Discovery failed ($reason)")
                scheduleRetry()
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun stopDiscovery(result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.success(null)
            return
        }

        bootstrapRequested = false
        clearLoops()
        closeServerSocket()
        clientHandshakeRunning = false
        pendingConnectAddress = null

        manager.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {}
                    override fun onFailure(reason: Int) {}
                })
                appPeers.clear()
                pendingDevices.clear()
                emitPeers()
                clearServiceRegistration()
                transitionState(WifiDirectState.IDLE, "Stopped")
                result.success(null)
            }

            override fun onFailure(reason: Int) {
                clearServiceRegistration()
                transitionState(WifiDirectState.FAILED, "Stop discovery failed: $reason")
                result.error("STOP_DISCOVERY_FAILED", "Stopping discovery failed: $reason", null)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun connectToPeer(address: String, result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.error("WIFI_DIRECT_UNAVAILABLE", "Wi‑Fi Direct is not available", null)
            return
        }

        if (!hasWifiDirectPermission()) {
            result.error("PERMISSION_DENIED", "Nearby Wi‑Fi/Location permission not granted", null)
            return
        }

        if (pendingConnectAddress == address && state == WifiDirectState.CONNECTING) {
            result.success(null)
            return
        }

        val peer = pendingDevices[address]
        val knownAppPeer = appPeers[address]
        if (knownAppPeer == null && (peer == null || !isAllowedPeerName(peer.deviceName))) {
            result.error("NOT_APP_PEER", "Requested peer is not an allowed Guardian peer", null)
            return
        }

        val config = WifiP2pConfig().apply {
            deviceAddress = address
        }

        emitCallback(
            "connectAttempt",
            mapOf(
                "targetAddress" to address,
                "targetName" to (peer?.deviceName ?: knownAppPeer?.name ?: ""),
                "knownAppPeer" to (knownAppPeer != null),
            ),
        )

        transitionState(WifiDirectState.CONNECTING, "Connecting to $address")
        pendingConnectAddress = address
        connectAttemptStartedAtMs = System.currentTimeMillis()
        startConnectTimeout(address)

        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(null)
            }

            override fun onFailure(reason: Int) {
                clearConnectTimeout()
                transitionState(WifiDirectState.FAILED, "connect failed: $reason")
                emitCallback(
                    "connectFailed",
                    mapOf(
                        "targetAddress" to address,
                        "reasonCode" to reason,
                    ),
                )
                result.error("CONNECT_FAILED", "Wi‑Fi Direct connect failed: $reason", null)
                scheduleRetry()
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        if (!hasWifiDirectPermission()) return

        manager.requestPeers(channel) { peerList: WifiP2pDeviceList ->
            val peers = peerList.deviceList.toList()
            for (device in peers) {
                val address = device.deviceAddress ?: continue
                pendingDevices[address] = device
            }
            maybeConnectToBestGroupOwner(peers)
        }
    }

    @SuppressLint("MissingPermission")
    private fun discoverPeersInternal() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        if (!hasWifiDirectPermission()) return

        manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                requestPeers()
                discoverServices()
            }

            override fun onFailure(reason: Int) {
                if (reason == WifiP2pManager.BUSY) {
                    requestPeers()
                    discoverServices()
                    return
                }
                transitionState(WifiDirectState.FAILED, "discoverPeers failed: $reason")
                scheduleRetry()
            }
        })
    }

    private fun maybeConnectToBestGroupOwner(peers: List<WifiP2pDevice>) {
        if (state != WifiDirectState.DISCOVERING) {
            return
        }

        val candidates = peers.filter { device ->
            val address = device.deviceAddress ?: return@filter false
            val allowedByName = isAllowedPeerName(device.deviceName)
            val allowedByMarker = appPeers.containsKey(address)
            allowedByName || allowedByMarker
        }

        if (candidates.isEmpty()) {
            return
        }

        val selected = candidates.firstOrNull { it.isGroupOwner } ?: candidates.first()
        val selectedAddress = selected.deviceAddress ?: return
        if (pendingConnectAddress == selectedAddress) {
            return
        }
        connectToPeerInternal(selectedAddress)
    }

    @SuppressLint("MissingPermission")
    private fun discoverServices() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        if (!hasWifiDirectPermission()) return

        manager.discoverServices(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
    }

    private fun configureDnsSdCallbacks() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return

        manager.setDnsSdResponseListeners(
            channel,
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, registrationType, srcDevice ->
                if (registrationType == serviceType && instanceName.startsWith(appNamePrefix)) {
                    val address = srcDevice.deviceAddress ?: return@DnsSdServiceResponseListener
                    pendingDevices[address] = srcDevice
                }
            },
            WifiP2pManager.DnsSdTxtRecordListener { _, txtRecordMap, srcDevice ->
                val appMarker = txtRecordMap[appMarkerKey]
                val userId = txtRecordMap[userIdKey] ?: ""
                if (appMarker != appMarkerValue || userId.isBlank() || userId == currentUserId) {
                    return@DnsSdTxtRecordListener
                }

                val address = srcDevice.deviceAddress ?: return@DnsSdTxtRecordListener
                val knownDevice = pendingDevices[address] ?: srcDevice
                val name = knownDevice.deviceName ?: ""

                appPeers[address] = AppPeer(
                    address = address,
                    name = name,
                    userId = userId,
                    appMarker = appMarker,
                    status = knownDevice.status,
                    lastSeenAtMs = System.currentTimeMillis(),
                )
                emitPeers()
                if (state == WifiDirectState.DISCOVERING && pendingConnectAddress == null) {
                    val isOwnerCandidate = srcDevice.isGroupOwner ||
                        (pendingDevices[address]?.isGroupOwner == true)
                    if (isOwnerCandidate) {
                        connectToPeerInternal(address)
                    } else {
                        requestPeers()
                    }
                }
            },
        )
    }

    private fun connectToPeerInternal(address: String) {
        val fireAndForget = object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        }
        connectToPeer(address, fireAndForget)
    }

    private fun registerServiceRequest() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return

        clearServiceRequestOnly()

        serviceRequest = WifiP2pDnsSdServiceRequest.newInstance().also { request ->
            manager.addServiceRequest(channel, request, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}
                override fun onFailure(reason: Int) {}
            })
        }
    }

    private fun registerLocalService(userId: String) {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return

        clearLocalServiceOnly()

        val txt = hashMapOf(
            appMarkerKey to appMarkerValue,
            userIdKey to userId,
            "gw_ver" to "1",
        )

        val instanceName = "$appNamePrefix$userId"
        val info = WifiP2pDnsSdServiceInfo.newInstance(instanceName, serviceType, txt)
        localServiceInfo = info
        manager.addLocalService(channel, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
    }

    private fun handleConnectionChanged() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return

        manager.requestConnectionInfo(channel) { info: WifiP2pInfo? ->
            emitCallback(
                "ownerDiagnostics",
                mapOf(
                    "groupFormed" to (info?.groupFormed == true),
                    "isGroupOwner" to (info?.isGroupOwner == true),
                    "ownerIp" to (info?.groupOwnerAddress?.hostAddress ?: ""),
                    "targetAddress" to (pendingConnectAddress ?: ""),
                    "appPeerCount" to appPeers.size,
                    "pendingPeerCount" to pendingDevices.size,
                ),
            )

            if (info == null || !info.groupFormed) {
                if (state == WifiDirectState.CONNECTING && connectAttemptStartedAtMs > 0L) {
                    val elapsedMs = System.currentTimeMillis() - connectAttemptStartedAtMs
                    if (elapsedMs < connectTimeoutMs + 3000L) {
                        transitionState(WifiDirectState.CONNECTING, "Waiting for group formation")
                        return@requestConnectionInfo
                    }
                }

                if (state == WifiDirectState.DISCOVERING || state == WifiDirectState.IDLE) {
                    return@requestConnectionInfo
                }

                clearConnectTimeout()
                handleDisconnected("Group not formed")
                scheduleRetry()
                return@requestConnectionInfo
            }

            if (info.isGroupOwner) {
                clearConnectTimeout()
                transitionState(WifiDirectState.GO, "Group formed as owner")
                emitCallback("onBecameGO")
                startServerHandshakeLoop()
                return@requestConnectionInfo
            }

            val ownerIp = info.groupOwnerAddress?.hostAddress
            if (ownerIp.isNullOrBlank()) {
                handleDisconnected("Owner IP unavailable")
                scheduleRetry()
                return@requestConnectionInfo
            }

            startClientHandshake(ownerIp)
        }
    }

    private fun startServerHandshakeLoop() {
        if (serverRunning) {
            return
        }
        serverRunning = true
        closeServerSocket()

        ioExecutor.execute {
            try {
                val socket = ServerSocket(handshakePort).apply {
                    reuseAddress = true
                    soTimeout = 5000
                }
                serverSocket = socket

                while (serverRunning) {
                    val client = try {
                        socket.accept()
                    } catch (_: java.net.SocketTimeoutException) {
                        continue
                    }

                    client.soTimeout = 6000
                    client.use { acceptedClient ->
                        val reader = BufferedReader(InputStreamReader(acceptedClient.getInputStream()))
                        val writer = BufferedWriter(OutputStreamWriter(acceptedClient.getOutputStream()))
                        val request = reader.readLine()
                        if (request == helloMessage) {
                            writer.write(ackMessage)
                            writer.newLine()
                            writer.flush()
                            val ip = acceptedClient.inetAddress?.hostAddress ?: ""
                            emitCallback("onPeerConnected", mapOf("ip" to ip))
                        }
                    }
                }
            } catch (_: Exception) {
            } finally {
                closeServerSocket()
                serverRunning = false
            }
        }
    }

    private fun startClientHandshake(ownerIp: String) {
        if (clientHandshakeRunning) {
            return
        }
        clientHandshakeRunning = true

        ioExecutor.execute {
            var success = false
            try {
                val socket = Socket()
                socket.connect(InetSocketAddress(ownerIp, handshakePort), 6000)
                socket.soTimeout = 6000

                socket.use { client ->
                    val writer = BufferedWriter(OutputStreamWriter(client.getOutputStream()))
                    val reader = BufferedReader(InputStreamReader(client.getInputStream()))
                    writer.write(helloMessage)
                    writer.newLine()
                    writer.flush()
                    val response = reader.readLine()
                    success = response == ackMessage
                }
            } catch (_: Exception) {
                success = false
            }

            mainHandler.post {
                clientHandshakeRunning = false
                if (success) {
                    clearConnectTimeout()
                    transitionState(WifiDirectState.CONNECTED, "Handshake successful")
                    emitCallback("onPeerConnected", mapOf("ip" to ownerIp))
                } else {
                    transitionState(WifiDirectState.FAILED, "Handshake failed")
                    disconnectFromGroup()
                    scheduleRetry()
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun disconnectFromGroup() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        if (!hasWifiDirectPermission()) return

        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
    }

    private fun startConnectTimeout(address: String) {
        clearConnectTimeout()
        val task = Runnable {
            if (pendingConnectAddress == address && state == WifiDirectState.CONNECTING) {
                transitionState(WifiDirectState.FAILED, "Connection timeout")
                disconnectFromGroup()
                scheduleRetry()
            }
        }
        connectTimeoutRunnable = task
        mainHandler.postDelayed(task, connectTimeoutMs)
    }

    private fun clearConnectTimeout() {
        connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectTimeoutRunnable = null
        pendingConnectAddress = null
        connectAttemptStartedAtMs = 0L
    }

    private fun scheduleRetry() {
        if (!bootstrapRequested || currentUserId.isBlank()) {
            return
        }
        retryRunnable?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            if (!bootstrapRequested) {
                return@Runnable
            }
            evaluateRoleAndStart()
        }
        retryRunnable = task
        mainHandler.postDelayed(task, retryDelayMs)
    }

    private fun handleDisconnected(reason: String) {
        clearConnectTimeout()
        closeServerSocket()
        clientHandshakeRunning = false
        transitionState(WifiDirectState.IDLE, reason)
        emitCallback("onDisconnected")
    }

    private fun closeServerSocket() {
        serverRunning = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
    }

    private fun clearLoops() {
        mainHandler.removeCallbacks(discoveryTicker)
        retryRunnable?.let { mainHandler.removeCallbacks(it) }
        retryRunnable = null
        clearConnectTimeout()
    }

    private fun pruneStalePeers() {
        val now = System.currentTimeMillis()
        val staleThresholdMs = 8000L
        val stale = appPeers.values.filter { now - it.lastSeenAtMs > staleThresholdMs }
        if (stale.isEmpty()) return

        for (peer in stale) {
            appPeers.remove(peer.address)
        }
        emitPeers()
    }

    private fun emitPeers() {
        val payload = appPeers.values
            .sortedBy { it.name }
            .map { peer ->
                mapOf(
                    "address" to peer.address,
                    "name" to peer.name,
                    "userId" to peer.userId,
                    "appMarker" to peer.appMarker,
                    "isGuardianApp" to (peer.appMarker == appMarkerValue),
                    "status" to peer.status,
                )
            }
        peersEventSink?.success(payload)
    }

    private fun transitionState(newState: WifiDirectState, message: String? = null) {
        state = newState
        val payload = mutableMapOf<String, Any>("state" to newState.name)
        if (!message.isNullOrBlank()) {
            payload["message"] = message
        }
        stateEventSink?.success(payload)
    }

    private fun emitStateSnapshot() {
        transitionState(state)
    }

    private fun emitCallback(event: String, extras: Map<String, Any?> = emptyMap()) {
        val payload = mutableMapOf<String, Any?>("event" to event)
        payload.putAll(extras)
        stateEventSink?.success(payload)
    }

    private fun completeStartIfPending() {
        pendingStartResult?.success(null)
        pendingStartResult = null
    }

    private fun failStart(message: String) {
        pendingStartResult?.error("START_FAILED", message, null)
        pendingStartResult = null
    }

    private fun clearServiceRegistration() {
        clearServiceRequestOnly()
        clearLocalServiceOnly()
    }

    private fun clearServiceRequestOnly() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        val req = serviceRequest ?: return
        manager.removeServiceRequest(channel, req, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
        serviceRequest = null
    }

    private fun clearLocalServiceOnly() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        val info = localServiceInfo ?: return
        manager.removeLocalService(channel, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
        localServiceInfo = null
    }

    private fun registerReceiverIfNeeded() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(peerReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(peerReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun unregisterReceiverIfNeeded() {
        if (!receiverRegistered) return
        unregisterReceiver(peerReceiver)
        receiverRegistered = false
    }

    private fun ensurePermissionsThen(onGranted: () -> Unit) {
        if (hasWifiDirectPermission() && hasStaticManifestPermissions()) {
            onGranted()
            return
        }

        pendingPermissionContinuation = onGranted
        val permissions = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }
        permissionLauncher.launch(permissions.toTypedArray())
    }

    private fun ensureWifiEnabledThen(onReady: () -> Unit) {
        if (isWifiEnabled()) {
            onReady()
            return
        }
        if (requestedWifiPanel) {
            return
        }
        requestedWifiPanel = true
        transitionState(WifiDirectState.FAILED, "Wi‑Fi disabled; prompt opened")
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Intent(Settings.Panel.ACTION_WIFI)
        } else {
            Intent(Settings.ACTION_WIFI_SETTINGS)
        }
        wifiPanelLauncher.launch(intent)
    }

    private fun isWifiEnabled(): Boolean {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return wifiManager?.isWifiEnabled == true
    }

    private fun hasStaticManifestPermissions(): Boolean {
        val hasWifiState = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_WIFI_STATE,
        ) == PackageManager.PERMISSION_GRANTED
        val hasChangeWifiState = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CHANGE_WIFI_STATE,
        ) == PackageManager.PERMISSION_GRANTED
        val hasInternet = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.INTERNET,
        ) == PackageManager.PERMISSION_GRANTED
        return hasWifiState && hasChangeWifiState && hasInternet
    }

    private fun areAllRequiredPermissionsGranted(result: Map<String, Boolean>): Boolean {
        val locationGranted =
            result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED

        val nearbyGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            result[Manifest.permission.NEARBY_WIFI_DEVICES] == true ||
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.NEARBY_WIFI_DEVICES,
                ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        return locationGranted && nearbyGranted
    }

    private fun hasWifiDirectPermission(): Boolean {
        val hasLocation = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

        val hasNearbyWifi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.NEARBY_WIFI_DEVICES,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        return hasLocation && hasNearbyWifi
    }

    private fun isAllowedPeerName(name: String?): Boolean {
        if (name.isNullOrBlank()) {
            return false
        }
        return name.startsWith(appNamePrefix)
    }
}
