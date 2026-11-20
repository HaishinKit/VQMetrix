package com.haishinkit.vqmetrix

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
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
        fun endpoint(server: String): URL {
            val uri = URI(server.trim())
            require(
                uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank() &&
                    uri.userInfo == null && uri.query == null && uri.fragment == null &&
                    (uri.port == -1 || uri.port in 1..65535),
            ) { "Enter an HTTPS receiver base URL" }
            return URI("https", null, uri.host, uri.port, uri.path.orEmpty().trimEnd('/') + "/api/v1/runs", null, null).toURL()
        }
    }
}
