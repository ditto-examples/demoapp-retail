package live.ditto.zava.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/// Edge-Studio 100 ms latest-wins flush: observer callbacks (which arrive on a
/// Ditto delivery thread) enqueue here; at most one main-thread delivery per
/// 100 ms reaches the UI, so during initial-sync storms the UI only recomposes
/// for the settled state.
///
/// Mutation contract: ALL mutable state lives under [lock]; [onChange] is
/// always invoked on the main dispatcher. Main-safe by construction.
class ResultCoalescer<T>(
    private val flushIntervalMs: Long = 100,
    private val onChange: (T) -> Unit,
) {
    private val lock = ReentrantLock()
    private var pending: T? = null
    private var flushScheduled = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun enqueue(value: T) {
        val shouldSchedule = lock.withLock {
            pending = value
            if (flushScheduled) {
                false
            } else {
                flushScheduled = true
                true
            }
        }
        if (shouldSchedule) {
            scope.launch {
                delay(flushIntervalMs)
                flush()
            }
        }
    }

    private fun flush() {
        val value: T? = lock.withLock {
            val v = pending
            pending = null
            flushScheduled = false
            v
        }
        if (value != null) {
            scope.launch(Dispatchers.Main) {
                onChange(value)
            }
        }
    }
}
