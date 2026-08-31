import Anvil
import DittoSwift
import OSLog
import SwiftUI

/// The orders list is a live, PAGED store observer (PLAN §4.2.2): the page
/// slice is `ORDER BY order_date DESC LIMIT pageSize OFFSET (page-1)*pageSize`
/// and the total comes from a COUNT observer — both live-update as sync runs.
/// The "recent" filter anchors to max(order_date) in the local store — the
/// dataset ends 2025-06-27, so a device-clock-relative filter would show
/// zero rows.
@MainActor
@Observable
final class OrdersState {
    var orders: [Order] = []
    var totalCount = 0
    var page = 1
    var pageSize = 25
    var recentOnly = false
    /// The exact query currently observed — shown verbatim in the info sheet
    /// (with the resolved cutoff substituted, not a template).
    var activeQuery = ""
    var error: String?

    /// Search (partial order number or customer name) — one-shot
    /// case-insensitive ILIKE queries with 500 ms debounce; the paged observer
    /// drives the list otherwise.
    var searchText = ""
    var searchResults: [Order]?
    var isSearching: Bool {
        searchResults != nil
    }

    var visibleOrders: [Order] {
        searchResults ?? orders
    }

    /// DQL ILIKE (LIKE's case-insensitive variant) on both order number and
    /// customer name. nonisolated: read by tests off the main actor.
    nonisolated static let searchQuery = """
    SELECT * FROM orders WHERE store_id = :storeId AND deleted = false \
    AND (order_id ILIKE :like OR customer_name ILIKE :like) \
    ORDER BY order_date DESC, _id DESC LIMIT 50
    """

    /// Search input cleanup: trim whitespace and drop leading '#' characters —
    /// the list renders order numbers as "#20250115_0001" but the stored id is
    /// "order_20250115_0001". '%' and '_' are left alone: they're ILIKE
    /// wildcards (the info sheet says so), and '_' matches real order ids.
    nonisolated static func sanitizedSearchTerm(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return String(trimmed.drop(while: { $0 == "#" }))
    }

    /// Dedicated search task — deliberately NOT restartTask: typing must not
    /// cancel a pending observer restart (store switch / page change), and a
    /// restart must not await the 500 ms debounce.
    private var searchTask: Task<Void, Never>?

    func search(appState: AppState) {
        searchTask?.cancel()
        let term = Self.sanitizedSearchTerm(searchText)
        if term.isEmpty {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Read the store AFTER the debounce: a store switch during the
            // sleep must not fetch the old store's rows into the new context.
            guard let storeId = appState.selectedStoreId else { return }
            do {
                let results = try await DittoManager.shared.fetch(
                    Self.searchQuery,
                    arguments: ["storeId": storeId, "like": "%\(term)%"],
                    as: Order.self
                )
                guard !Task.isCancelled else { return }
                self?.searchResults = results
                self?.error = nil
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    /// Store switch while a search may be active: drop the old store's matches
    /// immediately (never render another store's data), restart the paged
    /// observers, and re-run the search against the new store (search()
    /// cancels any in-flight search fetch first, so late old-store results
    /// are discarded by its cancellation guard).
    func handleStoreSwitch(appState: AppState) {
        searchResults = nil
        page = 1
        restart(appState: appState)
        search(appState: appState)
    }

    private var pageObserver: DittoStoreObserver?
    private var countObserver: DittoStoreObserver?
    private var lastStoreId: String?
    /// Restart serialization: every restart cancels and awaits the in-flight
    /// one, so rapid filter/page changes can't leave two observers alive.
    private var restartTask: Task<Void, Never>?

    private struct MaxDateRow: Sendable, Decodable {
        let max_date: String?
    }

    static let baseWhere = "FROM orders WHERE store_id = :storeId AND deleted = false"

    /// Non-blocking restart entry point for view events (serializes).
    func restart(appState: AppState) {
        let previous = restartTask
        restartTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await restartNow(appState: appState)
        }
    }

    private func restartNow(appState: AppState) async {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil
        guard let storeId = appState.selectedStoreId else { return }

        // Never render the previous store's rows: clear before re-registering
        // so the skeleton shows instead of stale data.
        if lastStoreId != storeId {
            orders = []
            totalCount = 0
        }
        lastStoreId = storeId

        let built = await buildQueries(storeId: storeId)
        activeQuery = built.displayQuery

        do {
            countObserver = try await DittoManager.shared.observe(
                built.countQuery, arguments: built.arguments, as: CountRow.self
            ) { [weak self] rows in
                guard let self else { return }
                totalCount = rows.first?.count ?? 0
                let clamped = Paging.clampPage(page, total: totalCount, pageSize: pageSize)
                if clamped != page {
                    page = clamped
                    restart(appState: appState)
                }
            }
            pageObserver = try await DittoManager.shared.observe(
                built.pageQuery, arguments: built.arguments, as: Order.self
            ) { [weak self] orders in
                self?.orders = orders
            }
            error = nil
        } catch is CancellationError {
            // View torn down mid-restart — not an error state.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The queries for the current filters (page + count + the display string
    /// for the info sheet with args resolved inline).
    private struct BuiltQueries {
        let pageQuery: String
        let countQuery: String
        let displayQuery: String
        let arguments: [String: Sendable]
    }

    private func buildQueries(storeId: String) async -> BuiltQueries {
        var whereClause = Self.baseWhere
        var arguments: [String: Sendable] = ["storeId": storeId]
        if recentOnly,
           let maxDate = await latestOrderDate(storeId: storeId),
           let cutoff = Self.cutoffDate(from: maxDate, days: 30)
        {
            whereClause += " AND order_date > :cutoff"
            arguments["cutoff"] = cutoff
        }

        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        let pageQuery = Paging.pageQuery(
            base: "SELECT * \(whereClause)",
            orderBy: "order_date DESC, _id DESC",
            page: page,
            pageSize: pageSize
        )
        let countQuery = "SELECT COUNT(*) AS count \(whereClause)"
        var displayQuery = pageQuery
        for (key, value) in arguments {
            displayQuery = displayQuery.replacingOccurrences(of: ":\(key)", with: "'\(value)'")
        }
        return BuiltQueries(
            pageQuery: pageQuery,
            countQuery: countQuery,
            displayQuery: displayQuery,
            arguments: arguments
        )
    }

    func stop() {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil
        restartTask?.cancel()
        restartTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func latestOrderDate(storeId: String) async -> String? {
        let query = """
        SELECT MAX(order_date) AS max_date FROM orders \
        WHERE store_id = :storeId AND deleted = false
        """
        do {
            return try await DittoManager.shared.fetch(query, arguments: ["storeId": storeId], as: MaxDateRow.self)
                .first?.max_date
        } catch {
            Logger.ui.error("latestOrderDate failed — 'recent' shows the full list: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// ISO8601 strings sort lexicographically; the cutoff keeps that property.
    /// `nonisolated static` and internal so unit tests can reach it.
    nonisolated static func cutoffDate(from iso: String, days: Int) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso),
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: date) else { return nil }
        return formatter.string(from: cutoff)
    }
}

struct OrdersView: View {
    /// Why "Recent only" anchors to the DATA, not the clock — the single most
    /// surprising thing about demoing on a fixed benchmark dataset.
    static let recentExplanation = """
    Filters to orders from the last 30 days OF THE DATASET — the benchmark's \
    data ends 2025-06-27, so the cutoff is anchored to the newest synced order \
    (max(order_date) − 30 days), not to today's date. A naive "now minus 30 \
    days" filter would show zero rows in a demo. This is the benchmark's \
    date-range query shape (orders__select__by_date_range) with a parameterized \
    cutoff — the info sheet above shows the exact query running, cutoff included.
    """

    /// What the info sheet shows WHILE searching — the list is then driven by
    /// the ILIKE one-shot, not the paged observer, so the sheet says so.
    static let searchExplanation = """
    While you type, the list is driven by this one-shot query (500 ms debounce) \
    instead of the live paged observer. ILIKE is LIKE's case-insensitive \
    variant, so partial order numbers and customer names match regardless of \
    case. '%' and '_' in your input act as wildcards, and matches are capped \
    at 50 rows. Search matches across all dates — it ignores the "Recent only" \
    filter. Clear the field (the × button) to return to the live, paginated list.
    """

    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = OrdersState()

    /// The query actually driving the list right now: the ILIKE one-shot with
    /// args resolved inline while searching, else the live paged observer
    /// query (or its template before the first emission).
    private var displayedQuery: String {
        if state.isSearching, let storeId = appState.selectedStoreId {
            let term = OrdersState.sanitizedSearchTerm(state.searchText)
            return OrdersState.searchQuery
                .replacingOccurrences(of: ":storeId", with: "'\(storeId)'")
                .replacingOccurrences(of: ":like", with: "'%\(term)%'")
        }
        return state.activeQuery.isEmpty
            ? "SELECT * \(OrdersState.baseWhere) ORDER BY order_date DESC"
            : state.activeQuery
    }

    /// Footer shown in place of the pagination bar while searching — same 44pt
    /// height so the list doesn't jump, and it discloses the LIMIT 50 cap.
    private var searchFooterText: String {
        let count = state.visibleOrders.count
        if count >= 50 {
            return "First 50 matches shown (cap) — refine the term, or clear search for the paged list"
        }
        return "\(count) \(count == 1 ? "match" : "matches") — clear search for the paged list"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter row: labeled toggle + info sheet showing the ACTUAL
                // query running (the search query while searching), not a
                // template. Search itself is the platform-standard .searchable
                // field (nav bar on iOS, toolbar on macOS) — with the standard
                // × clear affordance, which a plain TextField lacks.
                HStack(spacing: 8) {
                    Toggle(isOn: $state.recentOnly) {
                        Text("Recent only (last 30 days of data)")
                            .font(.callout)
                            .foregroundStyle(colors.foregroundNormal)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    Spacer()
                    QueryInfoButton(
                        query: displayedQuery,
                        explanation: state.isSearching
                            ? Self.searchExplanation
                            : Self.recentExplanation
                    )
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                Group {
                    if state.visibleOrders.isEmpty {
                        VStack(spacing: 12) {
                            if let error = state.error {
                                AnvilBadge(error, status: .critical)
                            } else if state.isSearching {
                                Text("No matches")
                                    .foregroundStyle(colors.foregroundSubtle)
                            } else {
                                SkeletonRows(count: 8)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List(state.visibleOrders) { order in
                            NavigationLink(destination: OrderDetailView(order: order)) {
                                OrderRow(order: order)
                            }
                        }
                        .listStyle(.plain)
                    }
                }

                Divider()
                if state.isSearching {
                    HStack {
                        Text(searchFooterText)
                            .font(.caption)
                            .foregroundStyle(colors.foregroundSubtle)
                        Spacer()
                    }
                    .padding(.horizontal)
                    // Match the pagination bar's height (32pt controls + 6+6
                    // padding) so the list doesn't jump when search toggles.
                    .frame(height: 44)
                    .background(colors.surface)
                } else {
                    PaginationBar(
                        totalCount: state.totalCount,
                        page: $state.page,
                        pageSize: $state.pageSize,
                        pageSizes: [25, 50, 100, 250]
                    ) {
                        state.restart(appState: appState)
                    }
                    .background(colors.surface)
                }
            }
            .background(colors.background)
            .navigationTitle("Orders")
            .searchable(text: $state.searchText, prompt: "Search order # or customer…")
            .task { state.restart(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                state.handleStoreSwitch(appState: appState)
            }
            .onChange(of: state.recentOnly) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.searchText) { _, _ in
                state.search(appState: appState)
            }
        }
    }
}

private struct OrderRow: View {
    let order: Order
    @Environment(\.dittoColors) private var colors

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.order_id.replacingOccurrences(of: "order_", with: "#"))
                    .font(.dittoCode(size: 13))
                    .foregroundStyle(colors.foregroundNormal)
                Text("\(order.customer_name) · \(Formatters.dateTime(order.order_date))")
                    .font(.subheadline)
                    .foregroundStyle(colors.foregroundSubtle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.usd(order.total))
                    .font(.headline)
                    .foregroundStyle(colors.foregroundNormal)
                Text("\(order.item_count) item\(order.item_count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(colors.foregroundSubtle)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Order detail = order + its items via the canonical two-query pattern.
/// DQL v5.0 has no JOINs: the first query fetched the order (the list's
/// observer), this view runs the second (items by order_id).
struct OrderDetailView: View {
    let order: Order
    @Environment(\.dittoColors) private var colors
    @State private var items: [OrderItem] = []
    @State private var error: String?

    static let itemsQuery = "SELECT * FROM order_items WHERE order_id = :orderId AND deleted = false"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnvilCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(order.order_id)
                            .font(.dittoCode(size: 14))
                            .foregroundStyle(colors.foregroundNormal)
                        Text(order.customer_name)
                            .font(.title3).foregroundStyle(colors.foregroundNormal)
                        Text("\(Formatters.dateTime(order.order_date)) · \(order.store_name)")
                            .foregroundStyle(colors.foregroundSubtle)
                        HStack {
                            AnvilBadge(order.status, status: .success)
                            Spacer()
                            Text(Formatters.usd(order.total))
                                .font(.title2).fontWeight(.semibold)
                                .foregroundStyle(colors.foregroundNormal)
                        }
                    }
                }

                AnvilCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Line items")
                                .font(.headline).foregroundStyle(colors.foregroundNormal)
                            Spacer()
                            QueryInfoButton(query: Self.itemsQuery, explanation: Self.explanation)
                        }
                        ForEach(items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.product_name)
                                        .foregroundStyle(colors.foregroundNormal)
                                    Text(item.sku)
                                        .font(.dittoCode(size: 11))
                                        .foregroundStyle(colors.foregroundSubtle)
                                }
                                Spacer()
                                Text("×\(item.quantity)")
                                    .foregroundStyle(colors.foregroundSubtle)
                                Text(Formatters.usd(item.line_total))
                                    .font(.dittoCode(size: 13))
                                    .foregroundStyle(colors.foregroundNormal)
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                        if items.isEmpty {
                            ProgressView()
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
        .navigationTitle("Order")
        .task {
            do {
                items = try await DittoManager.shared.fetch(
                    Self.itemsQuery,
                    arguments: ["orderId": order.order_id],
                    as: OrderItem.self
                )
            } catch is CancellationError {
                // View torn down mid-fetch — not an error state.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static let explanation = """
    DQL v5.0 has no JOINs, so order detail is two queries: the list's live \
    observer fetched this order, and this screen ran the second query — \
    order_items filtered by order_id. That's the canonical DQL pattern the \
    benchmark measures as the orders__select__by_id + order_items__select__by_order pair.
    """
}
