package com.haishinkit.vqmetrix

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import java.net.URI
import java.util.ArrayDeque

/** A Bonjour receiver advertisement. Discovery does not establish trust or authorize uploads. */
data class ReceiverEndpoint(val name: String, val baseUrl: String)

/** Browses protocol-v1 receivers on the local network. Call start/stop on the main thread. */
class ReceiverDiscovery(context: Context) {
    private val manager = context.applicationContext.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var generation = 0

    fun start(
        changed: (List<ReceiverEndpoint>) -> Unit,
        failed: (Int) -> Unit,
    ) {
        check(Looper.myLooper() == Looper.getMainLooper())
        stop()
        val session = generation
        val receivers = linkedMapOf<String, ReceiverEndpoint>()
        val present = mutableSetOf<String>()
        val pending = ArrayDeque<NsdServiceInfo>()
        var resolving = false

        fun notifyChanged() = changed(receivers.values.sortedBy { it.name })

        fun resolveNext() {
            if (resolving || pending.isEmpty() || session != generation) return
            val service = pending.removeFirst()
            resolving = true
            @Suppress("DEPRECATION")
            manager.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        info: NsdServiceInfo,
                        errorCode: Int,
                    ) {
                        handler.post {
                            if (session != generation) return@post
                            resolving = false
                            resolveNext()
                        }
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        handler.post {
                            if (session != generation) return@post
                            if (info.serviceName in present) {
                                val attributes = info.attributes.mapValues { it.value.toString(Charsets.UTF_8) }
                                endpoint(info.serviceName, info.port, attributes, info.host?.hostAddress)?.let { receivers[info.serviceName] = it }
                                notifyChanged()
                            }
                            resolving = false
                            resolveNext()
                        }
                    }
                },
            )
        }
        val discovery =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {}

                override fun onDiscoveryStopped(type: String) {}

                override fun onStartDiscoveryFailed(
                    type: String,
                    errorCode: Int,
                ) {
                    handler.post {
                        if (session == generation) {
                            stop()
                            failed(errorCode)
                        }
                    }
                }

                override fun onStopDiscoveryFailed(
                    type: String,
                    errorCode: Int,
                ) {}

                override fun onServiceFound(info: NsdServiceInfo) {
                    handler.post {
                        if (session != generation || !present.add(info.serviceName)) return@post
                        pending.addLast(info)
                        resolveNext()
                    }
                }

                override fun onServiceLost(info: NsdServiceInfo) {
                    handler.post {
                        if (session != generation) return@post
                        present.remove(info.serviceName)
                        receivers.remove(info.serviceName)
                        pending.removeAll { it.serviceName == info.serviceName }
                        notifyChanged()
                    }
                }
            }
        listener = discovery
        changed(emptyList())
        try {
            manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (_: SecurityException) {
            stop()
            failed(NsdManager.FAILURE_INTERNAL_ERROR)
        }
    }

    fun stop() {
        check(Looper.myLooper() == Looper.getMainLooper())
        generation++
        listener?.let { runCatching { manager.stopServiceDiscovery(it) } }
        listener = null
    }

    companion object {
        const val SERVICE_TYPE = "_vqmetrix._tcp."

        /** TXT requires protocol=1, scheme=http|https and a DNS hostname (normally MacName.local). */
        fun endpoint(
            name: String,
            port: Int,
            attributes: Map<String, String>,
            resolvedAddress: String? = null,
        ): ReceiverEndpoint? {
            if (attributes["protocol"] != "1" || port !in 1..65535) return null
            val scheme = attributes["scheme"] ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = attributes["host"]?.trimEnd('.') ?: return null
            if (host.length > 253 || !host.matches(Regex("[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?"))) return null
            return runCatching {
                val base = URI(scheme, null, if (scheme == "http" && resolvedAddress != null) resolvedAddress else host, port, null, null, null).toString()
                BatchUploader.endpoint(base)
                ReceiverEndpoint(name, base)
            }.getOrNull()
        }
    }
}
