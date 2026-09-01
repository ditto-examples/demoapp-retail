package live.ditto.zava.model

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
        var cleanupError: Throwable? = null
        for (query in prepared.postQueries) {
            try {
                execute(query)
            } catch (e: Throwable) {
                cleanupError = e
            }
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
