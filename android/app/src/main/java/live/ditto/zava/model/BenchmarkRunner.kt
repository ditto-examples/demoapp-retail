package live.ditto.zava.model

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/// SDK-decoupled benchmark orchestration (unit tests drive it with a fake
/// executor): preQueries run once → timed iterations (break on first error) →
/// postQueries ALWAYS run. Iteration error outranks cleanup error.
object BenchmarkRunner {
    suspend fun runOrchestrated(
        prepared: PreparedBenchmark,
        iterations: Int,
        execute: suspend (String) -> Int,
    ): BenchmarkRunResult {
        for (query in prepared.preQueries) {
            execute(query)
        }
        val durationsMs = mutableListOf<Double>()
        var rowCount = 0
        var iterationError: Throwable? = null
        for (i in 0 until iterations) {
            val start = System.nanoTime()
            try {
                rowCount = execute(prepared.query)
            } catch (e: Throwable) {
                iterationError = e
                break
            }
            durationsMs += (System.nanoTime() - start) / 1_000_000.0
        }
        // Cleanup runs even when the CALLING coroutine was cancelled mid-run
        // (navigating away from a mutating benchmark): without NonCancellable
        // every cleanup execute would throw before touching Ditto, stranding
        // the synthetic doc on Big Peer. A cleanup error never masks the
        // iteration error.
        val cleanupError: Throwable? = withContext(NonCancellable) {
            var first: Throwable? = null
            for (query in prepared.postQueries) {
                try {
                    execute(query)
                } catch (e: Throwable) {
                    first = e
                }
            }
            first
        }
        iterationError?.let { throw it }
        cleanupError?.let { throw it }
        return BenchmarkRunResult(
            iterations = durationsMs.size,
            stats = BenchmarkStats.of(durationsMs),
            resultCount = rowCount,
        )
    }
}
