package live.ditto.zava

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import live.ditto.zava.data.ResultCoalescer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/// ResultCoalescer is the sync-storm backbone (100 ms latest-wins flush to
/// main) and was entirely untested. These pin the contract.
class CoalescerTests {

    private fun withMainDispatcher(block: () -> Unit) {
        val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(dispatcher)
        try {
            block()
        } finally {
            Dispatchers.resetMain()
            dispatcher.close()
        }
    }

    @Test
    fun latestWinsWithinWindow() = runTest {
        withMainDispatcher {
            val delivered = Collections.synchronizedList(mutableListOf<Int>())
            val latch = CountDownLatch(1)
            val coalescer = ResultCoalescer<Int>(flushIntervalMs = 50) { v ->
                delivered += v
                latch.countDown()
            }
            coalescer.enqueue(1)
            coalescer.enqueue(2)
            coalescer.enqueue(3)
            assertTrue("flush must land", latch.await(2, TimeUnit.SECONDS))
            Thread.sleep(150) // window + slack — no further flush may occur
            assertEquals("one flush, latest value only", listOf(3), delivered)
        }
    }

    @Test
    fun separateWindowsDeliverSeparately() = runTest {
        withMainDispatcher {
            val delivered = Collections.synchronizedList(mutableListOf<Int>())
            var latch = CountDownLatch(1)
            val coalescer = ResultCoalescer<Int>(flushIntervalMs = 50) { v ->
                delivered += v
                latch.countDown()
            }
            coalescer.enqueue(1)
            assertTrue(latch.await(2, TimeUnit.SECONDS))
            latch = CountDownLatch(1)
            coalescer.enqueue(2)
            assertTrue(latch.await(2, TimeUnit.SECONDS))
            assertEquals(listOf(1, 2), delivered)
        }
    }
}
