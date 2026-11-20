package com.haishinkit.vqmetrix

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [29])
class BatchUploaderTest {
    @Test
    fun sendsArchiveAndIdempotencyKeyAndSavesReceiptWithoutToken() {
        runBlocking {
            val directory = java.nio.file.Files.createTempDirectory("vq-upload").toFile()
            val file = File(directory, "batch.zip").apply { writeBytes(byteArrayOf(80, 75, 1, 2, 3, 4)) }
            val run = UUID.randomUUID().toString()
            val job = UUID.randomUUID().toString()
            val connection = FakeConnection(URL("https://receiver.invalid/api/v1/runs"), job)
            try {
                val uploader = BatchUploader { connection }
                val result = uploader.upload(BatchArchive(run, directory, file), "https://receiver.invalid", "test-token") { _, _ -> }
                assertEquals(job, result)
                assertArrayEquals(file.readBytes(), connection.sent.toByteArray())
                assertEquals("Bearer test-token", connection.getRequestProperty("Authorization"))
                assertEquals(run, connection.getRequestProperty("Idempotency-Key"))
                assertEquals("application/zip", connection.getRequestProperty("Content-Type"))
                assertTrue(connection.closed)
                val receipt = File(directory, "upload-receipt.json").readText()
                assertTrue(receipt.contains(job))
                assertFalse(receipt.contains("test-token"))
            } finally {
                directory.deleteRecursively()
            }
        }
    }

    private class FakeConnection(url: URL, private val job: String) : HttpURLConnection(url) {
        val sent = ByteArrayOutputStream()
        var closed = false

        override fun connect() {}

        override fun disconnect() {
            closed = true
        }

        override fun usingProxy() = false

        override fun getOutputStream() = sent

        override fun getInputStream() = ByteArrayInputStream("{\"jobId\":\"$job\",\"status\":\"queued\"}".toByteArray())

        override fun getResponseCode() = 202
    }
}
