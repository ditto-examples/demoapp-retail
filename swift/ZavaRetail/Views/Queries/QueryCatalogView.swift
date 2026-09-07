import Anvil
import SwiftUI

/// The 96-query retail-JOINs benchmark catalog shipped in the app bundle,
/// browsable by collection. Every query is runnable against the live synced
/// store with timing — this is how the app "shows off" the benchmark
/// (PLAN §4.2.6). JOIN entries need Ditto SDK 5.1+ (small peer); the apps
/// pin 5.1.x.
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
                ContentUnavailableView(
                    "Catalog unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
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
        case "SELECT", "GUARD": .info
        case "INDEX_SELECT": .promo
        case "AGGREGATION": .success
        case let c where c.hasPrefix("JOIN_"): .success
        case "INSERT", "UPSERT": .warning
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
    /// The id suffix the NEXT run will use — shown in the query preview so the
    /// DQL on screen is exactly the DQL that will execute. Regenerated after
    /// each run so repeat runs never conflict.
    @State private var runId = String(UUID().uuidString.prefix(8))

    /// Prepared with the same runId the next run will use — the viewer never
    /// shows a different statement than the one that executes.
    private var prepared: PreparedBenchmark {
        QueryPreparation.prepare(
            name: name, entry: entry,
            storeId: appState.selectedStoreId ?? "store_seattle",
            runId: runId
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

                if result != nil || error != nil {
                    AnvilCard {
                        VStack(alignment: .leading, spacing: 10) {
                            if let result {
                                VStack(alignment: .leading, spacing: 6) {
                                    resultRow("Result count", "\(result.resultCount.formatted()) rows")
                                    if let expected = entry.expected_count {
                                        resultRow("Expected on full dataset", "\(expected.formatted()) rows")
                                    }
                                    resultRow("Mean", String(format: "%.2f ms", result.stats.meanMs))
                                    resultRow("Median", String(format: "%.2f ms", result.stats.medianMs))
                                    resultRow("p95", String(format: "%.2f ms", result.stats.p95Ms))
                                    resultRow("Min / Max", String(format: "%.2f / %.2f ms", result.stats.minMs, result.stats.maxMs))
                                    Text("""
                                    \(result.iterations) timed iterations, execution only (no rendering). \
                                    The benchmark harness uses pilot + warmup + 50 iterations; \
                                    this screen keeps it simple. The expected count comes from the \
                                    suite's full-dataset oracle — on a sliced load (--size below 100k) \
                                    smaller counts are correct, not a bug.
                                    """)
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
            }
            .padding()
        }
        // Floating run toolbar (Edge Studio pattern): iterations + Run in a
        // glass bar docked at the bottom, always reachable while reading DQL.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 88)
        }
        .overlay(alignment: .bottom) {
            RunToolbar(
                iterations: $iterations,
                isRunning: isRunning,
                isMutating: entry.isMutating
            ) {
                if entry.isMutating {
                    showMutationConfirm = true
                } else {
                    runNow()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(colors.background)
        .navigationTitle("Benchmark")
        .alert("Run a mutating benchmark?", isPresented: $showMutationConfirm) {
            Button("Run", role: .destructive) { runNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            This \(entry.category) benchmark writes a synthetic document. On a synced device \
            that write replicates to Big Peer; the runner uses fresh per-run ids and cleans \
            up with a propagating DELETE (not EVICT, which is local-only).
            """)
        }
    }

    private func runNow() {
        isRunning = true
        result = nil
        error = nil
        let runIdForThisRun = runId
        Task {
            do {
                let prepared = QueryPreparation.prepare(
                    name: name, entry: entry,
                    storeId: appState.selectedStoreId ?? "store_seattle",
                    runId: runIdForThisRun
                )
                result = try await DittoManager.shared.runBenchmark(prepared, iterations: iterations)
            } catch is CancellationError {
                // view torn down mid-run — not an error state
            } catch {
                self.error = error.localizedDescription
            }
            // Fresh ids for the NEXT run, and the preview shows them.
            runId = String(UUID().uuidString.prefix(8))
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

/// Floating bottom toolbar for the benchmark screen (Edge Studio's
/// DetailBottomBar pattern, Anvil-styled): iterations stepper + Run, docked
/// above the content in a glass bar so it's reachable while reading the DQL.
private struct RunToolbar: View {
    @Binding var iterations: Int
    let isRunning: Bool
    let isMutating: Bool
    let onRun: () -> Void

    @Environment(\.dittoColors) private var colors

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Button {
                        iterations = max(1, iterations - (iterations > 10 ? 10 : 1))
                    } label: {
                        Image(systemName: "minus")
                            .frame(minWidth: 36, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                    .accessibilityIdentifier("IterationsMinus")

                    Text("×\(iterations)")
                        .font(.dittoCode(size: 14))
                        .foregroundStyle(colors.foregroundNormal)
                        .frame(minWidth: 40)

                    Button {
                        iterations = min(100, iterations + (iterations >= 10 ? 10 : 1))
                    } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: 36, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                    .accessibilityIdentifier("IterationsPlus")
                }

                Spacer()

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running…")
                        .font(.callout)
                        .foregroundStyle(colors.foregroundSubtle)
                } else {
                    AnvilButton(isMutating ? "Run (writes data)" : "Run benchmark") {
                        onRun()
                    }
                    .accessibilityIdentifier("RunBenchmarkButton")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
