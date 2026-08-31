import Anvil
import DittoSwift
import SwiftUI

/// The full 25K-row customer directory, synced unfiltered
/// (subscription__customers_all — a walk-in could be anyone), PAGED with
/// LIMIT/OFFSET so the demo handles the full directory gracefully. "This store
/// only" filters inside the query (customers__select__by_primary_store_id_*),
/// not in memory. The search box runs one-shot point queries (debounced).
@MainActor
@Observable
final class CustomersState {
    var customers: [Customer] = []
    var totalCount = 0
    var page = 1
    var pageSize = 25
    var thisStoreOnly = false
    var searchText = ""
    var searchResults: [Customer]?
    var error: String?

    private var pageObserver: DittoStoreObserver?
    private var countObserver: DittoStoreObserver?
    private var restartTask: Task<Void, Never>?
    private var started = false

    /// Query text constants are nonisolated: the static whereClause() helper
    /// and tests read them off the main actor.
    nonisolated static let directoryWhere = "FROM customers WHERE deleted = false"
    nonisolated static let storeWhere = "FROM customers WHERE primary_store_id = :storeId AND deleted = false"

    /// The store filter lives IN the query (the benchmark's
    /// customers__select__by_primary_store_id shape), not in memory.
    /// Extracted + static so unit tests can pin the decision.
    nonisolated static func whereClause(thisStoreOnly: Bool, storeId: String?) -> String {
        thisStoreOnly && storeId != nil ? storeWhere : directoryWhere
    }

    /// customers__select__by_email_* — the benchmark's indexed/no-index pair
    /// is runnable side-by-side in the Query Runner tab.
    static let emailQuery = "SELECT * FROM customers WHERE email = :email AND deleted = false"
    static let nameQuery = """
    SELECT * FROM customers WHERE deleted = false \
    AND (first_name LIKE :like OR last_name LIKE :like) ORDER BY last_name LIMIT 50
    """

    func start(appState: AppState) {
        guard !started else { return }
        started = true
        restart(appState: appState)
    }

    func stop() {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil
        restartTask?.cancel()
        restartTask = nil
        started = false
    }

    func restart(appState: AppState) {
        let previous = restartTask
        restartTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await reloadPage(appState: appState)
        }
    }

    private func reloadPage(appState: AppState) async {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil

        let whereClause = Self.whereClause(thisStoreOnly: thisStoreOnly, storeId: appState.selectedStoreId)
        var arguments: [String: Sendable] = [:]
        if thisStoreOnly, let storeId = appState.selectedStoreId {
            arguments["storeId"] = storeId
        }

        do {
            countObserver = try await DittoManager.shared.observe(
                "SELECT COUNT(*) AS count \(whereClause)", arguments: arguments, as: CountRow.self
            ) { [weak self] rows in
                self?.totalCount = rows.first?.count ?? 0
            }
            let pageQuery = Paging.pageQuery(
                base: "SELECT * \(whereClause)", orderBy: "last_name, first_name, _id",
                page: page, pageSize: pageSize
            )
            pageObserver = try await DittoManager.shared.observe(
                pageQuery, arguments: arguments, as: Customer.self
            ) { [weak self] customers in
                self?.customers = customers
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func search() {
        restartTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespaces)
        if term.isEmpty {
            searchResults = nil
            return
        }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                if term.contains("@") {
                    // exact-email lookup — the benchmark's indexed pair member
                    self?.searchResults = try await DittoManager.shared.fetch(
                        Self.emailQuery, arguments: ["email": term], as: Customer.self
                    )
                } else {
                    self?.searchResults = try await DittoManager.shared.fetch(
                        Self.nameQuery, arguments: ["like": "\(term)%"], as: Customer.self
                    )
                }
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    var isSearching: Bool {
        searchResults != nil
    }

    var visibleCustomers: [Customer] {
        searchResults ?? customers
    }
}

struct CustomersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = CustomersState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls

                Group {
                    if state.visibleCustomers.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(state.isSearching
                                ? "No matches"
                                : "Syncing the customer directory…")
                                .foregroundStyle(colors.foregroundSubtle)
                            if let error = state.error {
                                AnvilBadge(error, status: .critical)
                            }
                        }
                        Spacer()
                    } else {
                        List(state.visibleCustomers) { customer in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(customer.displayName)
                                    .foregroundStyle(colors.foregroundNormal)
                                Text(customer.email)
                                    .font(.subheadline)
                                    .foregroundStyle(colors.foregroundSubtle)
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.plain)
                    }
                }

                if !state.isSearching {
                    Divider()
                    PaginationBar(
                        totalCount: state.totalCount,
                        page: $state.page,
                        pageSize: $state.pageSize,
                        pageSizes: [25, 50, 100]
                    ) {
                        state.restart(appState: appState)
                    }
                    .background(colors.surface)
                }
            }
            .background(colors.background)
            .navigationTitle("Customers")
            .task { state.start(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.thisStoreOnly) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.searchText) { _, _ in state.search() }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            AnvilInput(placeholder: "Search name, or exact email…", text: $state.searchText)
            HStack {
                Toggle(isOn: $state.thisStoreOnly) {
                    Text("This store only")
                        .font(.callout)
                        .foregroundStyle(colors.foregroundSubtle)
                }
                .toggleStyle(.switch)
                .fixedSize()
                Spacer()
                if !state.isSearching {
                    Text("\(state.totalCount.formatted()) customers")
                        .font(.dittoCode(size: 12))
                        .foregroundStyle(colors.foregroundSubtle)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
