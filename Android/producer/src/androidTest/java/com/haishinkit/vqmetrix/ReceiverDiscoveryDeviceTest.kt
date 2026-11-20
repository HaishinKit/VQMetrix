package com.haishinkit.vqmetrix

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt-in integration probe against VQMETRIX_BONJOUR_PROBE=1 swift test --filter bonjourDeviceProbe. */
class ReceiverDiscoveryDeviceTest {
    @Test
    fun discoversMacReceiverOverBonjour() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("vqBonjourProbe") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val discovery = ReceiverDiscovery(instrumentation.targetContext)
        val found = CountDownLatch(1)
        instrumentation.runOnMainSync {
            discovery.start({ endpoints ->
                endpoints.forEach { android.util.Log.i("VQMetrixDiscoveryTest", "Resolved ${it.name}: ${it.baseUrl}") }
                if (endpoints.any { URI(it.baseUrl).port == 18787 }) found.countDown()
            }, { code -> android.util.Log.e("VQMetrixDiscoveryTest", "Discovery failed: $code") })
        }
        try {
            assertTrue("The Mac Bonjour probe was not resolved within 20 seconds", found.await(20, TimeUnit.SECONDS))
        } finally {
            instrumentation.runOnMainSync { discovery.stop() }
        }
    }
}
