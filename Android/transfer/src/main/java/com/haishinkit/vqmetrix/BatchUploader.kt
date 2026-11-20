package com.haishinkit.vqmetrix

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.net.URL
import java.time.Instant
import java.util.UUID

class BatchUploader(private val openConnection: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection }) {
    @Volatile
    private var active: HttpURLConnection? = null

    suspend fun upload(
        batch: BatchArchive,
        server: String,
        token: String,
        progress: (Long, Long) -> Unit,
    ): String =
        withContext(Dispatchers.IO) {
            val endpoint = endpoint(server)
            if (endpoint.protocol == "http") {
                val addresses = InetAddress.getAllByName(endpoint.host.removePrefix("[").removeSuffix("]"))
                require(addresses.isNotEmpty() && addresses.all(::isLocalAddress)) { "HTTP is limited to local network receivers" }
            }
            require(token.isNotBlank() && !token.contains('\r') && !token.contains('\n')) { "A receiver token is required" }
            require(batch.archive.isFile && batch.archive.length() > 0)
            val connection =
                openConnection(endpoint).apply {
                    requestMethod = "POST"
                    doOutput = true
                    instanceFollowRedirects = false
                    connectTimeout = 15_000
                    readTimeout = 60_000
                    setFixedLengthStreamingMode(batch.archive.length())
                    setRequestProperty("Content-Type", "application/zip")
                    setRequestProperty("Authorization", "Bearer $token")
                    setRequestProperty("Idempotency-Key", batch.runId)
                    setRequestProperty("X-VQMetrix-Protocol", "1")
                }
            active = connection
            try {
                connection.outputStream.use { output ->
                    batch.archive.inputStream().buffered().use { input ->
                        val bytes = ByteArray(64 * 1024)
                        var sent = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(bytes)
                            if (count < 0) break
                            output.write(bytes, 0, count)
                            sent += count
                            progress(sent, batch.archive.length())
                        }
                    }
                }
                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val response = ByteArrayOutputStream()
                stream?.use { input ->
                    val bytes = ByteArray(4096)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(bytes)
                        if (count < 0) break
                        check(response.size() + count <= 65536) { "Receiver response is too large" }
                        response.write(bytes, 0, count)
                    }
                }
                check(code in listOf(200, 201, 202)) { "Receiver returned HTTP $code" }
                val body = JSONObject(response.toString("UTF-8"))
                val jobId = UUID.fromString(body.getString("jobId")).toString()
                val receipt =
                    JSONObject().apply {
                        put("jobId", jobId)
                        put("server", server)
                        put("acceptedAt", Instant.now().toString())
                    }
                java.io.File(batch.directory, "upload-receipt.json").writeText(receipt.toString(2))
                jobId
            } finally {
                active = null
                connection.disconnect()
            }
        }

    fun cancel() {
        active?.disconnect()
    }

    companion object {
        private fun isLocalAddress(address: InetAddress): Boolean =
            address.isLoopbackAddress || address.isSiteLocalAddress || address.isLinkLocalAddress ||
                (address.address.size == 16 && (address.address[0].toInt() and 0xfe) == 0xfc)

        fun endpoint(server: String): URL {
            val uri = URI(server.trim())
            require(
                (uri.scheme.equals("https", ignoreCase = true) || uri.scheme.equals("http", ignoreCase = true)) && !uri.host.isNullOrBlank() &&
                    uri.userInfo == null && uri.query == null && uri.fragment == null &&
                    (uri.port == -1 || uri.port in 1..65535),
            ) { "Enter an HTTP or HTTPS receiver base URL" }
            if (uri.scheme.equals("http", ignoreCase = true)) {
                val host = uri.host.removePrefix("[").removeSuffix("]").lowercase()
                val literal = host.contains(':') || host.matches(Regex("[0-9.]+"))
                require(host.endsWith(".local") || host == "localhost" || (literal && isLocalAddress(InetAddress.getByName(host)))) {
                    "HTTP is limited to .local names or local network addresses"
                }
            }
            return URI(uri.scheme.lowercase(), null, uri.host, uri.port, uri.path.orEmpty().trimEnd('/') + "/api/v1/runs", null, null).toURL()
        }
    }
}
