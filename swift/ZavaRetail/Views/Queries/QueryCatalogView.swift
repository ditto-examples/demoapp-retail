import SwiftUI
import Anvil

/// The 72-query benchmark catalog shipped in the app bundle, browsable by
/// collection. Every query is runnable against the live synced store with
/// timing — this is how the app "shows off" the benchmark (PLAN §4.2.6).
struct QueryCatalogView: View {
    @Environment(\.dittoColors) private var colors
    @State private var catalog: BenchmarkCatalog?
    @State private var error: String?

    var body: some View {
        Group {
            if let catalog {
                List {
                    ForEach(catalog.groups, id: \.collection) { group in
                        Section {
                            ForEach(group.entries, id: \.name) { item in
                                NavigationLink(destination: QueryDetailView(
                                    name: item.name, entry: item.entry
                                )) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.dittoCode(size: 12))
                                            .foregroundStyle(colors.foregroundNormal)
                                        CategoryBadge(category: item.entry.category)
                                    }
                                }
                            }
                        } header: {
                            Text("\(group.collection) (\(group.entries.count))")
                        }
                    }
                }
                .listStyle(.inset)
            } else if let error {
                ContentUnavailableView("Catalog unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("Loading benchmark catalog…")
            }
        }
        .task {
            do {
                catalog = try BenchmarkCatalog.load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct CategoryBadge: View {
    let category: String

    var body: some View {
        AnvilBadge(category, status: status)
    }

    private var status: AnvilBadge.Status {
        switch category {
        case "SELECT": .info
        case "INDEX_SELECT": .promo
        case "AGGREGATION": .success
        case "INSERT": .warning
        case "UPDATE", "DELETE", "EVICT": .critical
        default: .info
        }
    }
}

struct QueryDetailView: View {
    let name: String
    let entry: BenchmarkEntry

    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors

    @State private var iterations = 10
    @State private var isRunning = false
    @State private var result: BenchmarkRunResult?
    @State private var error: String?
    @State private var showMutationConfirm = false
    @State private var showResults = false
    @State private var previewRows: [String]?

    /// Prepared for the currently selected store (substitutions recompute per
    /// run so each mutating run gets fresh bench ids).
    private var prepared: PreparedBenchmark {
        QueryPreparation.prepare(
            name: name, entry: entry,
            storeId: appState.selectedStoreId ?? "store_seattle",
            runId: "preview"
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.dittoCode(size: 13))
                        .foregroundStyle(colors.foregroundNormal)
                        .textSelection(.enabled)
                    CategoryBadge(category: entry.category)
                }

                AnvilCard {
                    VStack(alignment: .leading, spacing: 10) {
                        queryBlock(title: "Query", text: prepared.query)
                        if !prepared.preQueries.isEmpty {
                            queryBlock(title: "Pre-queries (run once)", text: prepared.preQueries.joined(separator: "\n"))
                        }
                        if !prepared.postQueries.isEmpty {
                            queryBlock(title: "Post-queries (run once)", text: prepared.postQueries.joined(separator: "\n"))
                        }
                    }
                }

                if !prepared.substitutions.isEmpty {
                    AnvilCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Substitutions for a synced device")
                                .font(.headline).foregroundStyle(colors.foregroundNormal)
                            ForEach(prepared.substitutions, id: \.self) { note in
                                Text("• \(note)")
                                    .font(.caption)
                                    .foregroundStyle(colors.foregroundSubtle)
                            }
                        }
                    }
                }

                AnvilCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper("Iterations: \(iterations)", value: $iterations, in: 1...100)
                            .foregroundStyle(colors.foregroundNormal)
                        if isRunning {
                            ProgressView("Running \(iterations) iterations…")
                        } else {
                            AnvilButton("Run benchmark") {
                                if entry.isMutating {
                                    showMutationConfirm = true
                                } else {
                                    runNow()
                                }
                            }
                        }
                        if let result {
                            VStack(alignment: .leading, spacing: 6) {
                                resultRow("Result count", "\(result.resultCount.formatted()) rows")
                                resultRow("Mean", String(format: "%.2f ms", result.stats.meanMs))
                                resultRow("Median", String(format: "%.2f ms", result.stats.medianMs))
                                resultRow("p95", String(format: "%.2f ms", result.stats.p95Ms))
                                resultRow("Min / Max", String(format: "%.2f / %.2f ms", result.stats.minMs, result.stats.maxMs))
                                Text("\(result.iterations) timed iterations, execution only (no rendering). The benchmark harness uses pilot + warmup + 50 iterations; this screen keeps it simple.")
                                    .font(.caption)
                                    .foregroundStyle(colors.foregroundSubtle)
                            }
                        }
                        if let error {
                            AnvilBadge(error, status: .critical)
                        }
                    }
                }
            }
            .padding()
        }
        .background(colors.background)
        .navigationTitle("Benchmark")
        .alert("Run a mutating benchmark?", isPresented: $showMutationConfirm) {
            Button("Run", role: .destructive) { runNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This \(entry.category) benchmark writes a synthetic document. On a synced device that write replicates to Big Peer; the runner uses fresh per-run ids and cleans up with a propagating DELETE (not EVICT, which is local-only).")
        }
    }

    private func runNow() {
        isRunning = true
        result = nil
        error = nil
        Task {
            do {
                let prepared = QueryPreparation.prepare(
                    name: name, entry: entry,
                    storeId: appState.selectedStoreId ?? "store_seattle"
                )
                result = try await DittoManager.shared.runBenchmark(prepared, iterations: iterations)
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func queryBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(colors.codeMuted)
            Text(text)
                .font(.dittoCode(size: 12))
                .foregroundStyle(colors.codeForeground)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(colors.foregroundSubtle)
            Spacer()
            Text(value)
                .font(.dittoCode(size: 13))
                .foregroundStyle(colors.foregroundNormal)
        }
    }
}
