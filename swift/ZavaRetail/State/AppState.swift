import Foundation
import DittoSwift
import OSLog

/// App-visible diagnostics (os_log — never print(); see repo conventions).
extension Logger {
    static let sync = Logger(subsystem: "live.ditto.zava", category: "sync")
    static let ui = Logger(subsystem: "live.ditto.zava", category: "ui")
}

/// App-wide state, observed by SwiftUI. `@MainActor @Observable` — views read
/// it directly; the DittoManager actor publishes decoded Sendable values here.
@MainActor
@Observable
final class AppState {
    enum Boot: Equatable {
        case loading
        case missingConfig
        case ready
        case failed(String)
    }

    private static let selectedStoreKey = "selectedStoreId"

    var boot: Boot = .loading
    var stores: [Store] = []
    var selectedStoreId: String? {
        didSet {
            let defaults = UserDefaults.standard
            if let selectedStoreId {
                defaults.set(selectedStoreId, forKey: Self.selectedStoreKey)
            } else {
                defaults.removeObject(forKey: Self.selectedStoreKey)
            }
        }
    }
    var lastError: String?

    /// The live Ditto instance (Sendable) — the Tools tab hands it to
    /// DittoAllToolsMenu. Published after open.
    private(set) var ditto: Ditto?

    private var storesObserver: DittoStoreObserver?

    init() {
        // UI-test hook: force the store picker on launch regardless of any
        // persisted selection.
        if ProcessInfo.processInfo.arguments.contains("-resetStoreSelection") {
            UserDefaults.standard.removeObject(forKey: Self.selectedStoreKey)
        }
        selectedStoreId = UserDefaults.standard.string(forKey: Self.selectedStoreKey)
    }

    func bootApp() async {
        guard boot == .loading else { return }
        guard let config = DatabaseConfig.load() else {
            boot = .missingConfig
            return
        }
        do {
            DittoLogger.minimumLogLevel = .debug
            let instance = try await DittoManager.shared.open(config: config) { [weak self] message in
                self?.lastError = message
            }
            ditto = instance
            Logger.sync.info("Ditto open; sync started")

            // The store picker and dashboard header observe the shared
            // (unfiltered) stores collection.
            storesObserver = try await DittoManager.shared.observe(
                "SELECT * FROM stores",
                as: Store.self
            ) { [weak self] stores in
                Logger.sync.info("stores observer fired: \(stores.count) stores")
                self?.stores = stores.sorted { $0.store_name < $1.store_name }
            }

            if let selectedStoreId {
                Logger.sync.info("applying persisted store selection: \(selectedStoreId, privacy: .public)")
                try await DittoManager.shared.applyStoreSelection(selectedStoreId)
            }
            boot = .ready
        } catch {
            Logger.sync.error("boot failed: \(error.localizedDescription, privacy: .public)")
            boot = .failed(error.localizedDescription)
        }
    }

    /// Store switch showcase (PLAN §4.1): re-points subscriptions and evicts
    /// the old store's data. Called from the store picker and the Ditto tab.
    func selectStore(_ storeId: String) {
        selectedStoreId = storeId
        Task {
            do {
                try await DittoManager.shared.applyStoreSelection(storeId)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// "Switch store" — returns to the picker; the per-store subscriptions for
    /// the current store stay live until a new selection replaces them (and
    /// evicts its data), so the dashboard never shows an empty-limbo state.
    func switchStore() {
        selectedStoreId = nil
    }
}
