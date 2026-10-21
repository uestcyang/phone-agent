package org.phoneagent.app

import java.net.URI
import java.util.Base64


object DeviceBridgePolicy {
    val REMOTE = BuildConfig.PA_BRIDGE_REMOTE
    val EGRESS_REMOTE = BuildConfig.PA_BRIDGE_EGRESS
    val SHA256 = BuildConfig.PA_BRIDGE_SHA256

    fun validate(server: String, fingerprint: String, auth: String, ownerOrigin: String) {


        require(SHA256.matches(Regex("[0-9a-f]{64}")) && REMOTE.isNotEmpty() && EGRESS_REMOTE.isNotEmpty()) { "Device bridge is not configured in this build" }
        val owner = URI(ownerOrigin)
        require(owner.scheme == "https" && !owner.host.isNullOrEmpty() && owner.port == -1 &&
            (owner.path.isNullOrEmpty() || owner.path == "/") && owner.userInfo == null &&
            owner.query == null && owner.fragment == null)
        val uri = URI(server)
        require(uri.scheme == "https" && uri.host == owner.host && uri.port == -1 &&
            uri.path == "/tunnel/" && uri.userInfo == null && uri.query == null && uri.fragment == null)
        require(Base64.getDecoder().decode(fingerprint).size == 32)
        require(auth.matches(Regex("device-bridge:[A-Za-z0-9_-]{32,64}")))
    }

}
