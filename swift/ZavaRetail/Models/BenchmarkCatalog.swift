import Foundation

/// One entry from shared/benchmarks.json (the 72-query DQL benchmark catalog,
/// bundled as an app resource and browsable/runnable in the Query Runner tab).
struct BenchmarkEntry: Sendable, Decodable {
    let query: String
    let category: String
    let preQueries: [String]?
    let postQueries: [String]?

    var isMutating: Bool {
        ["INSERT", "UPDATE", "DELETE", "EVICT"].contains(category)
    }
}

/// The bundled catalog, grouped by collection for browsing.
struct BenchmarkCatalog: Sendable {
    let entries: [(name: String, entry: BenchmarkEntry)]

    /// Grouped as (collection, [(name, entry)]) in stable order.
    var groups: [(collection: String, entries: [(name: String, entry: BenchmarkEntry)])] {
        var byCollection: [String: [(name: String, entry: BenchmarkEntry)]] = [:]
        for item in entries {
            let collection = item.name.split(separator: "__").first.map(String.init) ?? "other"
            byCollection[collection, default: []].append(item)
        }
        return byCollection
            .map { (collection: $0.key, entries: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.collection < $1.collection }
    }

    static func load() throws -> BenchmarkCatalog {
        guard let url = Bundle.main.url(forResource: "benchmarks", withExtension: "json") else {
            throw AppError.error(message: "benchmarks.json is missing from the app bundle")
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([String: BenchmarkEntry].self, from: data)
        return BenchmarkCatalog(entries: decoded.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
}

/// A benchmark after the substitutions a synced, store-scoped demo device
/// needs (PLAN §4.2.6):
/// - the literal 'store_seattle' becomes the user's selected store
/// - mutating benchmarks get per-run unique bench ids (repeat runs can never
///   hit identifier conflicts, even if a previous run left residue)
/// - cleanup EVICT becomes DELETE (EVICT is local-only — on a synced mesh the
///   synthetic doc would otherwise stay on Big Peer and re-sync everywhere)
struct PreparedBenchmark: Sendable {
    let name: String
    let category: String
    let isMutating: Bool
    let preQueries: [String]
    let query: String
    let postQueries: [String]
    /// Human-readable notes about what was substituted (shown in the UI).
    let substitutions: [String]
}

enum QueryPreparation {
    static func prepare(
        name: String,
        entry: BenchmarkEntry,
        storeId: String,
        runId: String = String(UUID().uuidString.prefix(8))
    ) -> PreparedBenchmark {
        var notes: [String] = []
        var appliedRunId = ""

        func transform(_ text: String) -> String {
            var result = text
            if result.contains("store_seattle"), storeId != "store_seattle" {
                result = result.replacingOccurrences(of: "store_seattle", with: storeId)
            }
            if entry.isMutating {
                result = result.replacingOccurrences(of: "bench-", with: "bench-\(runId)-")
            }
            return result
        }

        if entry.isMutating {
            appliedRunId = runId
            notes.append("Synthetic bench ids got the per-run suffix \(runId), so repeat runs can’t conflict — even if a previous run left residue on the mesh.")
        }

        var post = (entry.postQueries ?? []).map { text -> String in
            var result = transform(text)
            if entry.isMutating, result.hasPrefix("EVICT ") {
                result = "DELETE " + result.dropFirst("EVICT ".count)
            }
            return result
        }
        if entry.isMutating, (entry.postQueries ?? []).contains(where: { $0.hasPrefix("EVICT ") }) {
            notes.append("Cleanup ran as DELETE instead of the benchmark’s EVICT — EVICT is local-only and the synthetic doc would otherwise stay on Big Peer and re-sync to every device.")
        }

        // EVICT benchmarks have no cleanup of their own (local removal IS the
        // operation being measured) — on a synced device we add a propagating
        // DELETE so the mesh ends clean.
        if entry.category == "EVICT",
           let idRange = entry.query.range(of: #"_id\s*=\s*'[^']+'"#, options: .regularExpression) {
            let collection = entry.query
                .replacingOccurrences(of: "EVICT FROM ", with: "")
                .split(separator: " ").first.map(String.init) ?? ""
            if !collection.isEmpty {
                // transform() applies the per-run bench-id suffix.
                let predicate = transform(String(entry.query[idRange]))
                post.append("DELETE FROM \(collection) WHERE \(predicate)")
                notes.append("Added a propagating DELETE after the EVICT — otherwise the doc stays on the server and re-syncs.")
            }
        }

        if entry.query.contains("store_seattle") && storeId != "store_seattle" {
            notes.append("The benchmark literal store_seattle was substituted with your selected store (\(storeId)) — visible in the query text below.")
        }

        return PreparedBenchmark(
            name: name,
            category: entry.category,
            isMutating: entry.isMutating,
            preQueries: (entry.preQueries ?? []).map(transform),
            query: transform(entry.query),
            postQueries: post,
            substitutions: notes
        )
    }
}

/// Timing statistics matching the benchmark harness's method (population
/// variance; p95 = sorted[floor(n·0.95)]).
struct BenchmarkStats: Sendable, Equatable {
    let meanMs: Double
    let medianMs: Double
    let p95Ms: Double
    let minMs: Double
    let maxMs: Double

    init(durationsMs: [Double]) {
        let sorted = durationsMs.sorted()
        let n = sorted.count
        if n == 0 {
            meanMs = 0; medianMs = 0; p95Ms = 0; minMs = 0; maxMs = 0
            return
        }
        meanMs = sorted.reduce(0, +) / Double(n)
        medianMs = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        p95Ms = sorted[min(n - 1, Int((Double(n) * 0.95).rounded(.down)))]
        minMs = sorted[0]
        maxMs = sorted[n - 1]
    }
}

struct BenchmarkRunResult: Sendable {
    let iterations: Int
    let stats: BenchmarkStats
    let resultCount: Int
}
