package com.mythics.guardian_wheel

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "guardian_wheel/wifi_direct/methods"
    private val eventChannelName = "guardian_wheel/wifi_direct/events"

    private val serviceType = "_guardianwheel._tcp"
    private val appMarkerKey = "gw_app"
    private val appMarkerValue = "1"
    private val userIdKey = "gw_user_id"

    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null
    private var peerEventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false
    private var currentUserId: String = ""

    private var localServiceInfo: WifiP2pDnsSdServiceInfo? = null
    private var serviceRequest: WifiP2pDnsSdServiceRequest? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val discoveryTicker = object : Runnable {
        override fun run() {
            if (peerEventSink == null) return
            requestPeers()
            discoverServices()
            pruneStalePeers()
            mainHandler.postDelayed(this, 3000L)
        }
    }

    private data class AppPeer(
        val address: String,
        val name: String,
        val userId: String,
        val status: Int,
        val lastSeenAtMs: Long,
    )

    private val appPeers: MutableMap<String, AppPeer> = mutableMapOf()
    private val pendingDevices: MutableMap<String, WifiP2pDevice> = mutableMapOf()

    private val peerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION,
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION,
                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION,
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    requestPeers()
                    discoverServices()
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        wifiP2pManager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        wifiP2pChannel = wifiP2pManager?.initialize(this, mainLooper, null)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "startDiscovery" -> {
                        val userId = call.argument<String>("userId")
                        if (userId.isNullOrBlank()) {
                            result.error("INVALID_USER", "userId is required", null)
                        } else {
                            startDiscovery(userId, result)
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

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    peerEventSink = events
                    registerReceiverIfNeeded()
                    emitPeers()
                }

                override fun onCancel(arguments: Any?) {
                    peerEventSink = null
                    unregisterReceiverIfNeeded()
                    mainHandler.removeCallbacks(discoveryTicker)
                }
            })
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(discoveryTicker)
        clearServiceRegistration()
        unregisterReceiverIfNeeded()
        super.onDestroy()
    }

    @SuppressLint("MissingPermission")
    private fun startDiscovery(userId: String, result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.error("WIFI_DIRECT_UNAVAILABLE", "Wi-Fi Direct is not available", null)
            return
        }

        if (!hasWifiDirectPermission()) {
            result.error("PERMISSION_DENIED", "Nearby Wi-Fi/Location permission not granted", null)
            return
        }

        currentUserId = userId
        registerReceiverIfNeeded()
        configureDnsSdCallbacks()
        registerLocalService(userId)
        registerServiceRequest()

        manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                discoverServices()
                requestPeers()
                mainHandler.removeCallbacks(discoveryTicker)
                mainHandler.post(discoveryTicker)
                result.success(null)
            }

            override fun onFailure(reason: Int) {
                result.error("DISCOVERY_FAILED", "Wi-Fi Direct discovery failed: $reason", null)
            }
        })
    }

    private fun stopDiscovery(result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.success(null)
            return
        }

        mainHandler.removeCallbacks(discoveryTicker)

        manager.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                appPeers.clear()
                pendingDevices.clear()
                emitPeers()
                clearServiceRegistration()
                result.success(null)
            }

            override fun onFailure(reason: Int) {
                clearServiceRegistration()
                result.error("STOP_DISCOVERY_FAILED", "Stopping discovery failed: $reason", null)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun connectToPeer(address: String, result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.error("WIFI_DIRECT_UNAVAILABLE", "Wi-Fi Direct is not available", null)
            return
        }

        if (!hasWifiDirectPermission()) {
            result.error("PERMISSION_DENIED", "Nearby Wi-Fi/Location permission not granted", null)
            return
        }

        if (!appPeers.containsKey(address)) {
            result.error("NOT_APP_PEER", "Requested peer is not advertising Guardian Wheel service", null)
            return
        }

        val config = WifiP2pConfig().apply { deviceAddress = address }

        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                result.success(null)
            }

            override fun onFailure(reason: Int) {
                result.error("CONNECT_FAILED", "Wi-Fi Direct connect failed: $reason", null)
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers() {
        val manager = wifiP2pManager ?: return
        val channel = wifiP2pChannel ?: return
        if (!hasWifiDirectPermission()) return

        manager.requestPeers(channel) { peerList: WifiP2pDeviceList ->
            for (device in peerList.deviceList) {
                pendingDevices[device.deviceAddress ?: ""] = device
            }
        }
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
                if (registrationType == serviceType && instanceName.startsWith("GW-")) {
                    pendingDevices[srcDevice.deviceAddress ?: ""] = srcDevice
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
                val peer = AppPeer(
                    address = address,
                    name = knownDevice.deviceName ?: "Guardian Wheel",
                    userId = userId,
                    status = knownDevice.status,
                    lastSeenAtMs = System.currentTimeMillis(),
                )

                appPeers[address] = peer
                emitPeers()
            },
        )
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

        val instanceName = "GW-$userId"
        val info = WifiP2pDnsSdServiceInfo.newInstance(instanceName, serviceType, txt)
        localServiceInfo = info
        manager.addLocalService(channel, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {}
        })
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
                    "status" to peer.status,
                )
            }
        peerEventSink?.success(payload)
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
}
