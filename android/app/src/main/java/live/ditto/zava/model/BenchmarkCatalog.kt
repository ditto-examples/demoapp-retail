package live.ditto.zava.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

/// Bundled shared/benchmarks.json — the 96-query retail-JOINs DQL benchmark
/// catalog (asset). Key = benchmark name (<collection>__<descriptor>),
/// value = entry.
@Serializable
data class BenchmarkEntry(
    val query: String,
    val category: String,
    val preQueries: List<String>? = null,
    val postQueries: List<String>? = null,
    /// The harness's oracle count for this query on the full dataset —
    /// displayed next to the device's result count in the runner (sliced
    /// datasets legitimately differ; the runner copy says so).
    val expected_count: Int? = null,
) {
    val isMutating: Boolean get() = category in setOf("INSERT", "UPDATE", "DELETE", "EVICT", "UPSERT")
}

class AppError(message: String) : Exception(message)

data class BenchmarkCatalog(
    /// Flat list sorted by benchmark name, ascending, lexicographic.
    val entries: List<Pair<String, BenchmarkEntry>>,
) {
    data class Group(val collection: String, val entries: List<Pair<String, BenchmarkEntry>>)

    /// Grouped by the name segment before the first `__`, groups sorted by
    /// collection, entries name-sorted within each group.
    val groups: List<Group> by lazy {
        entries.groupBy { (name, _) -> name.split("__").first().ifEmpty { "other" } }
            .map { (collection, groupEntries) -> Group(collection, groupEntries.sortedBy { it.first }) }
            .sortedBy { it.collection }
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun parse(text: String): BenchmarkCatalog {
            val decoded = json.decodeFromString<Map<String, BenchmarkEntry>>(text)
            return BenchmarkCatalog(decoded.entries.map { it.key to it.value }.sortedBy { it.first })
        }
    }
}

/// A benchmark with every substitution baked in — the exact DQL that will run,
/// plus human-readable notes for the UI.
data class PreparedBenchmark(
    val name: String,
    val category: String,
    val isMutating: Boolean,
    val preQueries: List<String>,
    val query: String,
    val postQueries: List<String>,
    val substitutions: List<String>,
)

data class BenchmarkRunResult(
    val iterations: Int, // successful timed iterations (may be < requested)
    val stats: BenchmarkStats,
    val resultCount: Int, // row count of the last successful timed execution
)

/// Population statistics, matching the benchmark harness.
data class BenchmarkStats(
    val meanMs: Double,
    val medianMs: Double,
    val p95Ms: Double,
    val minMs: Double,
    val maxMs: Double,
) {
    companion object {
        fun of(durationsMs: List<Double>): BenchmarkStats {
            if (durationsMs.isEmpty()) return BenchmarkStats(0.0, 0.0, 0.0, 0.0, 0.0)
            val sorted = durationsMs.sorted()
            val n = sorted.size
            val median = if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            val p95 = sorted[minOf(n - 1, (n * 0.95).toInt())]
            return BenchmarkStats(
                meanMs = sorted.sum() / n,
                medianMs = median,
                p95Ms = p95,
                minMs = sorted.first(),
                maxMs = sorted.last(),
            )
        }
    }
}

/// The substitution engine that makes the benchmark catalog correct against a
/// live synced store (PLAN §4.2.6): store literal substitution, per-run ids
/// for mutating runs, EVICT cleanup rewritten to propagating DELETE.
object QueryPreparation {

    /// Same contract as DittoManager.isValidStoreId.
    fun isValidStoreId(storeId: String): Boolean =
        Regex("^[a-z0-9_\\-]+$").matches(storeId)

    fun prepare(
        name: String,
        entry: BenchmarkEntry,
        storeId: String,
        runId: String = UUID.randomUUID().toString().take(8),
    ): PreparedBenchmark {
        val notes = mutableListOf<String>()
        val safeStoreId = if (isValidStoreId(storeId)) {
            storeId
        } else {
            notes += "Selected store id '$storeId' doesn't match the dataset id pattern — substitution skipped."
            "store_seattle"
        }

        fun transform(text: String): String {
            var result = text
            if (result.contains("store_seattle") && safeStoreId != "store_seattle") {
                result = result.replace("store_seattle", safeStoreId)
            }
            if (entry.isMutating) {
                result = result.replace("bench-", "bench-$runId-")
            }
            return result
        }

        if (entry.isMutating) {
            notes += "Synthetic bench ids got the per-run suffix $runId, so repeat runs can’t conflict — even if a previous run left residue on the mesh."
        }

        val post = buildPostQueries(entry, ::transform, notes)

        if (entry.query.contains("store_seattle") && safeStoreId != "store_seattle") {
            notes += "The benchmark literal store_seattle was substituted with your selected store ($storeId) — visible in the query text below."
        }

        return PreparedBenchmark(
            name = name,
            category = entry.category,
            isMutating = entry.isMutating,
            preQueries = (entry.preQueries ?: emptyList()).map(::transform),
            query = transform(entry.query),
            postQueries = post,
            substitutions = notes,
        )
    }

    private fun buildPostQueries(
        entry: BenchmarkEntry,
        transform: (String) -> String,
        notes: MutableList<String>,
    ): List<String> {
        var post = (entry.postQueries ?: emptyList()).map(transform)
        if (entry.isMutating) {
            val hadEvict = entry.postQueries?.any { it.startsWith("EVICT ") } == true
            // EVICT is local-only: on a synced device the synthetic doc would
            // stay on Big Peer and re-sync everywhere, breaking repeat runs.
            // Swap the leading keyword for a propagating DELETE.
            post = post.map { if (it.startsWith("EVICT ")) "DELETE " + it.drop(6) else it }
            if (hadEvict) {
                notes += "Cleanup ran as DELETE instead of the benchmark’s EVICT — EVICT is local-only and the synthetic doc would otherwise stay on Big Peer and re-sync to every device."
            }
            if (entry.category == "EVICT") {
                val cleanup = evictCleanup(entry, transform)
                if (cleanup != null) {
                    post = post + cleanup
                    notes += "Added a propagating DELETE after the EVICT — otherwise the doc stays on the server and re-syncs."
                } else {
                    notes += "WARNING: could not derive a cleanup DELETE for this EVICT — the synthetic doc may stay on Big Peer and re-sync to other devices."
                }
            }
        }
        return post
    }

    /// EVICT benchmarks carry no cleanup of their own; derive a propagating
    /// DELETE reusing the EVICT's whole WHERE clause — scalar/composite
    /// `_id` targets and bulk `order_id = 'bench-…-bulk-…'` predicates alike.
    fun evictCleanup(entry: BenchmarkEntry, transform: (String) -> String): String? {
        if (entry.category != "EVICT") return null
        val whereMatch = Regex("\\bWHERE\\b", RegexOption.IGNORE_CASE).find(entry.query) ?: return null
        val collectionMatch = Regex("EVICT\\s+FROM\\s+\\w+", RegexOption.IGNORE_CASE).find(entry.query) ?: return null
        val collection = collectionMatch.value
            .replace(Regex("EVICT\\s+FROM\\s+", RegexOption.IGNORE_CASE), "")
            .trim()
        if (collection.isEmpty()) return null
        val predicate = transform(entry.query.substring(whereMatch.range.last + 1).trim())
        if (predicate.isEmpty()) return null
        return "DELETE FROM $collection WHERE $predicate"
    }
}
