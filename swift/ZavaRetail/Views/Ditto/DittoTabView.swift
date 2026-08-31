import Anvil
import DittoAllToolsMenu
import DittoSwift
import SwiftUI

/// The Ditto tab: Query Runner entry point, live sync status
/// (system:data_sync_info), indexes (system:indexes), the official Ditto
/// tools menu, and store switching.
struct DittoTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: QueryCatalogView()) {
                        Label("Query Runner", systemImage: "gauge.with.dots.needle.67percent")
                    }
                } footer: {
                    Text("Browse and run the 72-query retail benchmark catalog against the synced store, with timing.")
                }

                Section {
                    NavigationLink(destination: SyncStatusView()) {
                        Label("Sync status", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink(destination: IndexesView()) {
                        Label("Indexes", systemImage: "list.bullet.indent")
                    }
                } footer: {
                    Text("Live views over Ditto's system:data_sync_info and system:indexes virtual collections.")
                }

                Section {
                    if appState.ditto != nil {
                        NavigationLink(destination: ToolsHostView()) {
                            Label("Ditto tools", systemImage: "wrench.and.screwdriver")
                        }
                    }
                } footer: {
                    Text("The official DittoSwiftTools diagnostic menu (DittoAllToolsMenu).")
                }

                Section {
                    Button(role: .destructive) {
                        appState.switchStore()
                    } label: {
                        Label("Switch store", systemImage: "arrow.triangle.swap")
                    }
                } footer: {
                    Text("""
                    Returns to the store picker. The current store keeps syncing until you pick \
                    a new one — picking it cancels its subscriptions, evicts its local data \
                    (EVICT — local only), and subscribes to the new store.
                    """)
                }
            }
            .navigationTitle("Ditto")
        }
    }
}

/// Hosts DittoAllToolsMenu — kept behind a small wrapper so the Ditto instance
/// requirement is explicit.
private struct ToolsHostView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let ditto = appState.ditto {
            AllToolsMenu(ditto: ditto)
        } else {
            ContentUnavailableView("Ditto not open", systemImage: "exclamationmark.triangle")
        }
    }
}

// MARK: - Sync status (system:data_sync_info)

@MainActor
@Observable
final class SyncStatusState {
    var rows: [SyncStatusInfo] = []
    var error: String?

    private var observer: DittoStoreObserver?

    static let query = "SELECT * FROM system:data_sync_info"

    func start() async {
        guard observer == nil else { return }
        do {
            observer = try await DittoManager.shared.observeRawJSON(Self.query) { [weak self] jsonRows in
                self?.rows = jsonRows.compactMap { json in
                    guard let data = json.data(using: .utf8),
                          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any?] else { return nil }
                    return SyncStatusInfo(from: dict)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
    }
}

struct SyncStatusView: View {
    @Environment(\.dittoColors) private var colors
    @State private var state = SyncStatusState()

    var body: some View {
        List {
            if state.rows.isEmpty {
                ContentUnavailableView(
                    "No sync sessions yet",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Status appears once sync sessions establish.")
                )
            }
            ForEach(state.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.id)
                        .font(.dittoCode(size: 11))
                        .foregroundStyle(colors.foregroundNormal)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        AnvilBadge(
                            row.isDittoServer ? "Big Peer" : "peer",
                            status: row.isDittoServer ? .promo : .info
                        )
                        AnvilBadge(
                            row.syncSessionStatus,
                            status: row.syncSessionStatus == "Connected" ? .success : .warning
                        )
                        if let commit = row.syncedUpToLocalCommitId {
                            Text("commit \(commit)")
                                .font(.dittoCode(size: 11))
                                .foregroundStyle(colors.foregroundSubtle)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Sync status")
        .task { await state.start() }
        .onDisappear { state.stop() }
    }
}

// MARK: - Indexes (system:indexes)

@MainActor
@Observable
final class IndexesState {
    var rows: [IndexInfo] = []
    var error: String?

    private var observer: DittoStoreObserver?

    static let query = "SELECT * FROM system:indexes"

    func start() async {
        guard observer == nil else { return }
        do {
            observer = try await DittoManager.shared.observeRawJSON(Self.query) { [weak self] jsonRows in
                self?.rows = jsonRows.compactMap { json in
                    guard let data = json.data(using: .utf8),
                          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any?] else { return nil }
                    return IndexInfo(from: dict)
                }.sorted { $0.id < $1.id }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
    }
}

struct IndexesView: View {
    @Environment(\.dittoColors) private var colors
    @State private var state = IndexesState()

    var body: some View {
        List {
            ForEach(state.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.id)
                        .font(.dittoCode(size: 12))
                        .foregroundStyle(colors.foregroundNormal)
                    if !row.definition.isEmpty {
                        Text(row.definition)
                            .font(.dittoCode(size: 11))
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Indexes")
        .task { await state.start() }
        .onDisappear { state.stop() }
    }
}
