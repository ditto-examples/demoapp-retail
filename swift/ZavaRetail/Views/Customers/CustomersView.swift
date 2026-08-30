import SwiftUI
import Anvil
import DittoSwift

/// The full 25K-row customer directory, synced unfiltered
/// (subscription__customers_all — a walk-in could be anyone). The list is a
/// live observer; the search box runs one-shot point queries (debounced).
@MainActor
@Observable
final class CustomersState {
    var customers: [Customer] = []
    var thisStoreOnly = false
    var searchText = ""
    var searchResults: [Customer]?
    var error: String?

    private var observer: DittoStoreObserver?
    private var searchTask: Task<Void, Never>?
    private var started = false

    static let directoryQuery = """
        SELECT * FROM customers WHERE deleted = false ORDER BY last_name, first_name
        """
    /// customers__select__by_email_* — the benchmark's indexed/no-index pair
    /// is runnable side-by-side in the Query Runner tab.
    static let emailQuery = "SELECT * FROM customers WHERE email = :email AND deleted = false"
    static let nameQuery = """
        SELECT * FROM customers WHERE deleted = false \
        AND (first_name LIKE :like OR last_name LIKE :like) ORDER BY last_name LIMIT 50
        """

    func start(appState: AppState) async {
        guard !started else { return }
        started = true
        do {
            observer = try await DittoManager.shared.observe(Self.directoryQuery, as: Customer.self) { [weak self] customers in
                self?.customers = customers
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        observer?.cancel()
        observer = nil
        started = false
    }

    func search() {
        searchTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespaces)
        if term.isEmpty {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                if term.contains("@") {
                    // exact-email lookup — the benchmark's indexed pair member
                    self?.searchResults = try await DittoManager.shared.fetch(
                        Self.emailQuery, arguments: ["email": term], as: Customer.self)
                } else {
                    self?.searchResults = try await DittoManager.shared.fetch(
                        Self.nameQuery, arguments: ["like": "\(term)%"], as: Customer.self)
                }
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    func visibleCustomers(appState: AppState) -> [Customer] {
        let base = searchResults ?? customers
        guard thisStoreOnly, let storeId = appState.selectedStoreId else { return base }
        return base.filter { $0.primary_store_id == storeId }
    }
}

struct CustomersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = CustomersState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                        Text("\(state.visibleCustomers(appState: appState).count.formatted()) customers")
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                let visible = state.visibleCustomers(appState: appState)
                if visible.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(state.searchText.isEmpty
                             ? "Syncing the customer directory…"
                             : "No matches")
                            .foregroundStyle(colors.foregroundSubtle)
                        if let error = state.error {
                            AnvilBadge(error, status: .critical)
                        }
                    }
                    Spacer()
                } else {
                    List(visible) { customer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(customer.displayName)
                                .foregroundStyle(colors.foregroundNormal)
                            Text("\(customer.email)")
                                .font(.subheadline)
                                .foregroundStyle(colors.foregroundSubtle)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .background(colors.background)
            .navigationTitle("Customers")
            .task { await state.start(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: state.searchText) { _, _ in state.search() }
        }
    }
}
