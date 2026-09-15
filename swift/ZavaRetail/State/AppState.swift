import DittoSwift
import Foundation
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

    /// Drives RootView when no store is selected: the picker appears only for
    /// an explicit "Switch store" or when the store catalog hasn't synced yet
    /// — first launch auto-selects the smallest-order store instead
    /// (`Store.demo_default`, stamped by the loader).
    var showStorePicker = false

    /// The live Ditto instance (Sendable) — the Tools tab hands it to
    /// DittoAllToolsMenu. Published after open.
    private(set) var ditto: Ditto?

    private var storesObserver: DittoStoreObserver?
    /// Once per launch: the auto-default selection happens exactly once, so it
    /// can never override a deliberate user pick later in the session.
    private var didAutoSelectDefaultStore = false

    init() {
        // UI-test hook: force the store picker on launch regardless of any
        // persisted selection.
        if ProcessInfo.processInfo.arguments.contains("-resetStoreSelection") {
            UserDefaults.standard.removeObject(forKey: Self.selectedStoreKey)
        }
        selectedStoreId = UserDefaults.standard.string(forKey: Self.selectedStoreKey)
    }

    /// Boot is retryable: a transient failure (network, auth) must not brick
    /// the app. The Failed screen's Retry button calls this.
    func retryBoot() {
        guard case .failed = boot else { return }
        boot = .loading
        booting = false
    }

    /// Re-entrancy guard: boot only runs once per loading phase — two windows
    /// booting AppState at once must not double-register the stores observer.
    private var booting = false

    func bootApp() async {
        guard boot == .loading, !booting else { return }
        booting = true
        defer { booting = false }
        guard let config = DatabaseConfig.load() else {
            boot = .missingConfig
            return
        }
        do {
            #if DEBUG
            DittoLogger.minimumLogLevel = .debug
            #endif
            let instance = try await DittoManager.shared.open(config: config) { [weak self] message in
                self?.lastError = message
            }
            ditto = instance
            Logger.sync.info("Ditto open; sync started")

            // The dashboard header and the (on-demand) store picker observe
            // the shared (unfiltered) stores collection.
            if storesObserver == nil {
                storesObserver = try await DittoManager.shared.observe(
                    "SELECT * FROM stores",
                    as: Store.self
                ) { [weak self] stores in
                    Logger.sync.info("stores observer fired: \(stores.count) stores")
                    self?.stores = stores.sorted { $0.store_name < $1.store_name }
                    self?.autoSelectDefaultStoreIfNeeded()
                }
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

    /// First-launch default (no picker step): as soon as the store catalog has
    /// synced, select the store the loader flagged `demo_default` — the one
    /// with the fewest orders in the loaded slice, i.e. the smallest first
    /// sync. Fallback for unflagged catalogs (older loads): the first physical
    /// store by name. Runs once per launch and never overrides a user pick.
    private func autoSelectDefaultStoreIfNeeded() {
        guard selectedStoreId == nil, !didAutoSelectDefaultStore, !stores.isEmpty else { return }
        guard let defaultStore = stores.first(where: { $0.demo_default == true })
            ?? stores.first(where: { !$0.is_online }) ?? stores.first else { return }
        didAutoSelectDefaultStore = true
        Logger.sync.info("auto-selecting default store: \(defaultStore.store_id, privacy: .public)")
        selectStore(defaultStore.store_id)
    }

    /// Store switch showcase (PLAN §4.1): re-points subscriptions and evicts
    /// the old store's data. Called from the store picker and the Ditto tab.
    /// On failure the UI rolls back to whatever store the manager actually
    /// serves, and the error surfaces in the banner (never a silent divergence
    /// between the store name on screen and the synced data).
    func selectStore(_ storeId: String) {
        showStorePicker = false
        selectedStoreId = storeId
        Task {
            do {
                try await DittoManager.shared.applyStoreSelection(storeId)
            } catch {
                lastError = "Store switch failed: \(error.localizedDescription)"
                selectedStoreId = await DittoManager.shared.currentStoreId
                if selectedStoreId == nil {
                    showStorePicker = true
                }
            }
        }
    }

    /// "Switch store" — shows the on-demand picker; the per-store
    /// subscriptions for the current store stay live until a new selection
    /// replaces them (and evicts its data), so the dashboard never shows an
    /// empty-limbo state.
    func switchStore() {
        showStorePicker = true
        selectedStoreId = nil
    }
}
