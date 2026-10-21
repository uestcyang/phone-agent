package org.phoneagent.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.SystemClock


object NetworkWatcher {
    @Volatile
    private var registered = false

    private var currentNetwork: Network? = null
    private var currentTransports: Set<Int>? = null
    private var lastNotificationAtMs = 0L

    @Synchronized
    private fun notifyChanged(context: Context) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastNotificationAtMs < 1_500L) return
        lastNotificationAtMs = now
        HeartbeatBridge.notifyNetworkChanged(context)
    }

    fun register(context: Context) {
        if (registered) return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        try {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val changed = currentNetwork != null && currentNetwork != network
                    currentNetwork = network
                    if (changed) notifyChanged(context)
                }

                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    if (network != currentNetwork) return
                    val transports = setOf(
                        NetworkCapabilities.TRANSPORT_WIFI,
                        NetworkCapabilities.TRANSPORT_CELLULAR,
                        NetworkCapabilities.TRANSPORT_ETHERNET,
                        NetworkCapabilities.TRANSPORT_VPN,
                    ).filter { capabilities.hasTransport(it) }.toSet()
                    val changed = currentTransports != null && currentTransports != transports
                    currentTransports = transports
                    if (changed) notifyChanged(context)
                }
            })

            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    notifyChanged(context)
                }

                override fun onLost(network: Network) {
                    notifyChanged(context)
                }
            })
            registered = true
        } catch (_: SecurityException) {


        }
    }
}
