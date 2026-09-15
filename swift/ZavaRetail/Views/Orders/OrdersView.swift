import Anvil
import DittoSwift
import OSLog
import SwiftUI

/// The orders list is a live, PAGED store observer over an INNER JOIN
/// (orders ⨝ customers — PLAN §4.2.2): the page slice is
/// `ORDER BY o.order_date DESC LIMIT pageSize OFFSET (page-1)*pageSize` and
/// the total comes from a COUNT observer over the same join — both
/// live-update as sync runs. The join replaces v5.0's denormalized
/// `orders.customer_name`; the normalized dataset carries customer ids only.
/// The "recent" filter anchors to max(order_date) in the local store — the
/// dataset ends 2025-06-27, so a device-clock-relative filter would show
/// zero rows.
@MainActor
@Observable
final class OrdersState {
    var orders: [OrderSummaryRow] = []
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
    var searchResults: [OrderSummaryRow]?
    var isSearching: Bool {
        searchResults != nil
    }

    var visibleOrders: [OrderSummaryRow] {
        searchResults ?? orders
    }

    /// DQL ILIKE (LIKE's case-insensitive variant) on order number and both
    /// customer name fields — the name lives on `customers`, reached through
    /// the join. nonisolated: read by tests off the main actor.
    nonisolated static let searchQuery = """
    SELECT \(selectList) \(joinedFrom) \
    AND (o.order_id ILIKE :like OR c.first_name ILIKE :like OR c.last_name ILIKE :like) \
    ORDER BY o.order_date DESC, o._id DESC LIMIT 50
    """

    /// Projection shared by the paged observer and search — one row per order
    /// with the joined customer display name. Does NOT project `o._id`
    /// (observer-shaped JOIN emissions namespace `_id` per alias; the row
    /// derives it from `order_id`).
    nonisolated static let selectList =
        "o.order_id, o.store_id, o.order_date, o.status, o.subtotal, " +
        "o.total, o.item_count, o.customer_id, c.first_name, c.last_name"

    /// The joined FROM up to and including the store/deleted predicates; the
    /// "Recent only" cutoff is appended when active.
    nonisolated static let joinedFrom =
        "FROM orders AS o INNER JOIN customers AS c ON o.customer_id = c._id " +
        "WHERE o.store_id = :storeId AND o.deleted = false"

    /// Search input cleanup: trim whitespace and drop leading '#' characters —
    /// the list renders order numbers as "#197663" but the stored id is
    /// "order_197663". '%' and '_' are left alone: they're ILIKE
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
                    as: OrderSummaryRow.self
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

    static let baseFrom = joinedFrom

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
                built.pageQuery, arguments: built.arguments, as: OrderSummaryRow.self
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
        var fromClause = Self.baseFrom
        var arguments: [String: Sendable] = ["storeId": storeId]
        if recentOnly,
           let maxDate = await latestOrderDate(storeId: storeId),
           let cutoff = Self.cutoffDate(from: maxDate, days: 30)
        {
            fromClause += " AND o.order_date > :cutoff"
            arguments["cutoff"] = cutoff
        }

        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        let pageQuery = Paging.pageQuery(
            base: "SELECT \(Self.selectList) \(fromClause)",
            orderBy: "o.order_date DESC, o._id DESC",
            page: page,
            pageSize: pageSize
        )
        let countQuery = "SELECT COUNT(*) AS count \(fromClause)"
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
    days" filter would show zero rows in a demo. The list itself is a live \
    INNER JOIN to customers (the normalized schema carries customer ids only — \
    the name comes from the join). The info sheet above shows the exact query \
    running, cutoff included.
    """

    /// What the info sheet shows WHILE searching — the list is then driven by
    /// the ILIKE one-shot, not the paged observer, so the sheet says so.
    static let searchExplanation = """
    While you type, the list is driven by this one-shot query (500 ms debounce) \
    instead of the live paged observer. ILIKE is LIKE's case-insensitive \
    variant, so partial order numbers and customer first/last names match \
    regardless of case — the customer name is matched through the INNER JOIN \
    to the customers collection. '%' and '_' in your input act as wildcards, \
    and matches are capped at 50 rows. Search matches across all dates — it \
    ignores the "Recent only" filter. Clear the field (the × button) to return \
    to the live, paginated list.
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
            ? "SELECT \(OrdersState.selectList) \(OrdersState.baseFrom) ORDER BY o.order_date DESC"
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
    let order: OrderSummaryRow
    @Environment(\.dittoColors) private var colors

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.order_id.replacingOccurrences(of: "order_", with: "#"))
                    .font(.dittoCode(size: 13))
                    .foregroundStyle(colors.foregroundNormal)
                Text("\(order.customerName) · \(Formatters.dateTime(order.order_date))")
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

/// Order detail = the order row (already joined to its customer by the list)
/// plus its line items through a second INNER JOIN (order_items ⨝ products) —
/// product names/SKUs live only on the products collection in the normalized
/// schema. Ditto SDK 5.1 runs both joins on-device; sync subscriptions can't
/// JOIN, which is why items carry a denormalized store_id and sync per-store.
struct OrderDetailView: View {
    let order: OrderSummaryRow
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var items: [OrderLineRow] = []
    @State private var error: String?
    @State private var loaded = false

    static let itemsQuery = """
    SELECT oi._id, oi.order_id, oi.product_id, oi.quantity, oi.unit_price, \
    oi.discount_percent, oi.discount_amount, oi.line_total, p.product_name, p.sku \
    FROM order_items AS oi INNER JOIN products AS p ON oi.product_id = p._id \
    WHERE oi.order_id = :orderId AND oi.deleted = false
    """

    /// The store display name lives on the synced `stores` catalog (shared),
    /// not on the order document — look it up instead of joining.
    private var storeName: String {
        appState.stores.first { $0.store_id == order.store_id }?.store_name ?? order.store_id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnvilCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(order.order_id)
                            .font(.dittoCode(size: 14))
                            .foregroundStyle(colors.foregroundNormal)
                        Text(order.customerName)
                            .font(.title3).foregroundStyle(colors.foregroundNormal)
                        Text("\(Formatters.dateTime(order.order_date)) · \(storeName)")
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
                                    Text(item.product_name ?? item.product_id)
                                        .foregroundStyle(colors.foregroundNormal)
                                    Text(item.sku ?? "—")
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
                            if loaded && error == nil {
                                // The fetch resolved with no rows (an order
                                // whose line items never synced or has none).
                                Text("No line items")
                                    .foregroundStyle(colors.foregroundSubtle)
                            } else if error == nil {
                                ProgressView()
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
        .navigationTitle("Order")
        .task {
            do {
                items = try await DittoManager.shared.fetch(
                    Self.itemsQuery,
                    arguments: ["orderId": order.order_id],
                    as: OrderLineRow.self
                )
                loaded = true
            } catch is CancellationError {
                // View torn down mid-fetch — not an error state.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static let explanation = """
    One INNER JOIN per hop: the list joined orders ⨝ customers for the name \
    on this card, and this screen joins order_items ⨝ products for the item \
    names and SKUs. The normalized dataset carries ids only (no embedded \
    customer_name / product_name copies) — Ditto SDK 5.1 resolves them \
    on-device. This is the benchmark's items__join__products shape with a \
    parameterized order id.
    """
}
