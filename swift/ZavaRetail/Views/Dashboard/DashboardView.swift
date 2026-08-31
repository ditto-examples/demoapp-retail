import Anvil
import DittoSwift
import OSLog
import SwiftUI

/// Dashboard KPI queries — derived from the benchmark's AGGREGATION entries
/// (orders__aggregation__sum_total_by_status, orders__aggregation__count_by_month,
/// order_items__aggregation__top_products_by_revenue, inventory__select__low_stock_*).
/// Aliases are added so rows decode into typed models; the exact string that
/// executed is always shown in the card's info sheet.
enum DashboardQueries {
    static let statusRevenue = """
    SELECT status, COUNT(*) AS orders, SUM(total) AS revenue \
    FROM orders WHERE store_id = :storeId AND deleted = false GROUP BY status
    """
    static let monthlyTrend = """
    SELECT substr(order_date, 0, 7) AS month, COUNT(*) AS orders, SUM(total) AS revenue \
    FROM orders WHERE store_id = :storeId AND deleted = false \
    GROUP BY substr(order_date, 0, 7) ORDER BY substr(order_date, 0, 7) DESC LIMIT 12
    """
    /// Benchmark-shaped (inventory__select__low_stock): the store predicate
    /// keeps the KPI correct even if a store switch left stale inventory
    /// behind (don't rely on the eviction invariant alone).
    static let lowStock = """
    SELECT COUNT(*) AS count FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false
    """
    /// The rows behind the count — the card lists the most critical SKUs.
    static let lowStockItems = """
    SELECT * FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false \
    ORDER BY stock_level LIMIT 5
    """
    /// subscription__customers_all is unfiltered — this count is the shared
    /// directory every device holds (25K docs).
    static let customersCount = "SELECT COUNT(*) AS count FROM customers WHERE deleted = false"
    /// The shared catalog (400 products, unfiltered subscription).
    static let productsCount = "SELECT COUNT(*) AS count FROM products WHERE deleted = false"
    /// Top products by revenue — verbatim order_items__aggregation__top_products_by_revenue
    /// apart from the LIMIT the card's pull-down controls (10/25/50/100).
    /// DQL v5.0 GROUP BY projects only group keys + aggregates, so product
    /// names resolve client-side against the synced catalog.
    static func topProducts(limit: Int) -> String {
        """
        SELECT product_id, SUM(line_total) AS revenue \
        FROM order_items WHERE store_id = :storeId AND deleted = false \
        GROUP BY product_id ORDER BY revenue DESC LIMIT \(limit)
        """
    }

    /// The whole catalog is small (400 docs) — fetched once per refresh so
    /// aggregate rows (product_id only) can display product names.
    static let productsCatalog = "SELECT * FROM products WHERE deleted = false"
}

/// Aggregate row models (decoded via the same DittoManager.fetch path).
struct StatusRevenueRow: Sendable, Decodable {
    let status: String
    let orders: Int
    let revenue: Double
}

struct MonthTrendRow: Sendable, Decodable, Identifiable {
    let month: String
    let orders: Int
    let revenue: Double
    var id: String {
        month
    }
}

struct TopProductRow: Sendable, Decodable, Identifiable {
    let product_id: String
    let revenue: Double
    var id: String {
        product_id
    }
}

@MainActor
@Observable
final class DashboardState {
    var statusRows: [StatusRevenueRow] = []
    var monthRows: [MonthTrendRow] = []
    var lowStockCount: Int?
    var lowStockItems: [InventoryItem] = []
    var topProducts: [TopProductRow] = []
    var topProductsLimit = 5
    var customersCount: Int?
    var productsCount: Int?
    var productNames: [String: String] = [:]
    var isLoading = false
    var error: String?

    private var loadedFor: String?

    /// Display name for a product id — resolved from the synced catalog,
    /// falling back to the raw id when the catalog hasn't synced yet.
    func productName(_ productId: String) -> String {
        productNames[productId] ?? productId
    }

    /// All dashboard queries run as one parallel fan-out (per store).
    private struct Snapshot {
        let statusRows: [StatusRevenueRow]
        let monthRows: [MonthTrendRow]
        let lowStockCount: Int?
        let lowStockItems: [InventoryItem]
        let topProducts: [TopProductRow]
        let customersCount: Int?
        let productsCount: Int?
        let productNames: [String: String]
    }

    private func fetchSnapshot(storeId: String, limit: Int) async throws -> Snapshot {
        async let status = DittoManager.shared.fetch(
            DashboardQueries.statusRevenue, arguments: ["storeId": storeId], as: StatusRevenueRow.self
        )
        async let months = DittoManager.shared.fetch(
            DashboardQueries.monthlyTrend, arguments: ["storeId": storeId], as: MonthTrendRow.self
        )
        async let lowStock = DittoManager.shared.fetch(
            DashboardQueries.lowStock, arguments: ["storeId": storeId], as: CountRow.self
        )
        async let lowStockRows = DittoManager.shared.fetch(
            DashboardQueries.lowStockItems, arguments: ["storeId": storeId], as: InventoryItem.self
        )
        async let top = DittoManager.shared.fetch(
            DashboardQueries.topProducts(limit: limit), arguments: ["storeId": storeId], as: TopProductRow.self
        )
        async let customers = DittoManager.shared.fetch(
            DashboardQueries.customersCount, as: CountRow.self
        )
        async let catalog = DittoManager.shared.fetch(
            DashboardQueries.productsCatalog, as: Product.self
        )
        async let products = DittoManager.shared.fetch(
            DashboardQueries.productsCount, as: CountRow.self
        )
        let catalogProducts = try await catalog
        return try await Snapshot(
            statusRows: status.sorted { $0.orders > $1.orders },
            monthRows: months,
            lowStockCount: lowStock.first?.count,
            lowStockItems: lowStockRows,
            topProducts: top,
            customersCount: customers.first?.count,
            productsCount: products.first?.count,
            productNames: Dictionary(uniqueKeysWithValues: catalogProducts.map { ($0.product_id, $0.product_name) })
        )
    }

    func refresh(appState: AppState) async {
        guard let storeId = appState.selectedStoreId else { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let snapshot = try await fetchSnapshot(storeId: storeId, limit: topProductsLimit)
            statusRows = snapshot.statusRows
            monthRows = snapshot.monthRows
            lowStockCount = snapshot.lowStockCount
            lowStockItems = snapshot.lowStockItems
            topProducts = snapshot.topProducts
            customersCount = snapshot.customersCount
            productsCount = snapshot.productsCount
            productNames = snapshot.productNames
            loadedFor = storeId
            Logger.sync.info("dashboard refresh for \(storeId, privacy: .public) complete")
        } catch is CancellationError {
            // View torn down mid-refresh — not an error state.
        } catch {
            Logger.sync.error("dashboard refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func refreshIfNeeded(appState: AppState) async {
        if loadedFor != appState.selectedStoreId {
            await refresh(appState: appState)
        }
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = DashboardState()

    private var store: Store? {
        appState.stores.first { $0.store_id == appState.selectedStoreId }
    }

    private var totalOrders: Int {
        state.statusRows.reduce(0) { $0 + $1.orders }
    }

    private var totalRevenue: Double {
        state.statusRows.reduce(0) { $0 + $1.revenue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    kpiGrid
                    trendCard
                    lowStockCard
                    topProductsCard
                }
                .padding()
            }
            .background(colors.background)
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if state.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await state.refresh(appState: appState) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await state.refreshIfNeeded(appState: appState) }
            .onChange(of: appState.selectedStoreId) { _, _ in
                Task { await state.refreshIfNeeded(appState: appState) }
            }
        }
    }

    /// One line: store name (tap to switch stores in place — no trip to the
    /// Ditto tab) · location. The store picker is the showcase flow; this menu
    /// is the fast path.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(appState.stores) { store in
                        Button {
                            if store.store_id != appState.selectedStoreId {
                                appState.selectStore(store.store_id)
                            }
                        } label: {
                            HStack {
                                Text(store.store_name)
                                if store.store_id == appState.selectedStoreId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(store?.store_name ?? appState.selectedStoreId ?? "—")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(colors.foregroundNormal)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }
                .accessibilityIdentifier("storeSwitcher")

                if let store {
                    Text("· \(locationOneLiner(store))")
                        .font(.subheadline)
                        .foregroundStyle(colors.foregroundSubtle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
            }
            if let error = state.error {
                AnvilBadge(error, status: .critical)
            }
        }
    }

    private func locationOneLiner(_ store: Store) -> String {
        let address = store.location.address
        let cityState = "\(store.location.city), \(store.location.state)"
        // The online store's address is the placeholder "n/a".
        return address == "n/a" ? cityState : "\(address), \(cityState)"
    }

    /// Four KPI widgets share the row evenly (2×2 on narrow screens) — no
    /// blank space at the trailing edge.
    private var kpiGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 16, alignment: .top)],
            spacing: 16
        ) {
            KpiCard(
                title: "Orders",
                value: "\(totalOrders.formatted())",
                query: DashboardQueries.statusRevenue,
                explanation: Explanations.statusRevenue,
                identifier: "kpi.orders"
            )
            KpiCard(
                title: "Revenue (all time)",
                value: Formatters.usd(totalRevenue),
                query: DashboardQueries.statusRevenue,
                explanation: Explanations.statusRevenue,
                identifier: "kpi.revenue"
            )
            KpiCard(
                title: "Customers synced",
                value: state.customersCount?.formatted() ?? "…",
                query: DashboardQueries.customersCount,
                explanation: Explanations.customersCount,
                identifier: "kpi.customers"
            )
            KpiCard(
                title: "Catalog products",
                value: state.productsCount?.formatted() ?? "…",
                query: DashboardQueries.productsCount,
                explanation: Explanations.productsCount,
                identifier: "kpi.products"
            )
        }
    }

    private var trendCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Monthly trend")
                        .font(.headline).foregroundStyle(colors.foregroundNormal)
                    Spacer()
                    QueryInfoButton(query: DashboardQueries.monthlyTrend, explanation: Explanations.monthlyTrend)
                }
                // Column headers — a table of unlabeled numbers is unreadable.
                HStack {
                    Text("Month")
                        .frame(width: 64, alignment: .leading)
                    Spacer()
                    Text("Orders")
                        .frame(width: 70, alignment: .trailing)
                    Text("Revenue")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.dittoCode(size: 11))
                .foregroundStyle(colors.foregroundSubtle)
                let maxOrders = max(1, state.monthRows.map(\.orders).max() ?? 1)
                ForEach(state.monthRows) { row in
                    HStack {
                        Text(row.month)
                            .frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(colors.fillBrandPrimary)
                                .frame(width: geo.size.width * CGFloat(row.orders) / CGFloat(maxOrders))
                        }
                        .frame(height: 14)
                        Spacer()
                        Text("\(row.orders.formatted())")
                            .frame(width: 70, alignment: .trailing)
                            .foregroundStyle(colors.foregroundNormal)
                        Text(Formatters.usd(row.revenue))
                            .frame(width: 110, alignment: .trailing)
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                    .font(.dittoCode(size: 12))
                }
                if state.monthRows.isEmpty && !state.isLoading {
                    Text("No orders synced yet for this store.")
                        .foregroundStyle(colors.foregroundSubtle)
                }
            }
        }
    }

    private var lowStockCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Low stock")
                        .font(.headline).foregroundStyle(colors.foregroundNormal)
                    Spacer()
                    if let count = state.lowStockCount {
                        AnvilBadge(
                            count == 0 ? "No low stock found" : "\(count) SKU\(count == 1 ? "" : "s") under 5 units",
                            status: count > 0 ? .warning : .success
                        )
                        .accessibilityIdentifier("lowStock.badge")
                    }
                    QueryInfoButton(query: DashboardQueries.lowStock, explanation: Explanations.lowStock)
                }

                if let count = state.lowStockCount {
                    if count == 0 {
                        Text("Everything at this store has 5+ units on hand.")
                            .font(.callout)
                            .foregroundStyle(colors.foregroundSubtle)
                    } else {
                        ForEach(state.lowStockItems) { item in
                            HStack {
                                Text(state.productName(item.product_id))
                                    .foregroundStyle(colors.foregroundNormal)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer()
                                Text("Aisle \(item.location.aisle)")
                                    .font(.dittoCode(size: 11))
                                    .foregroundStyle(colors.foregroundSubtle)
                                AnvilBadge(
                                    item.stock_level == 0 ? "out" : "\(item.stock_level) left",
                                    status: item.stock_level == 0 ? .critical : .warning
                                )
                            }
                        }
                        if count > state.lowStockItems.count {
                            Text("+ \(count - state.lowStockItems.count) more — full list in Products → ⚠ Low stock")
                                .font(.caption)
                                .foregroundStyle(colors.foregroundSubtle)
                        }
                    }
                } else if state.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var topProductsCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Top products by revenue")
                        .font(.headline).foregroundStyle(colors.foregroundNormal)
                    Spacer()
                    Menu("Top \(state.topProductsLimit)") {
                        ForEach([5, 10, 25, 50, 100], id: \.self) { limit in
                            Button("\(limit)") {
                                state.topProductsLimit = limit
                                Task { await state.refresh(appState: appState) }
                            }
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(colors.foregroundSubtle)
                    .accessibilityIdentifier("topProducts.limit")
                    QueryInfoButton(
                        query: DashboardQueries.topProducts(limit: state.topProductsLimit),
                        explanation: Explanations.topProducts
                    )
                }
                ForEach(Array(state.topProducts.enumerated()), id: \.element.id) { rank, row in
                    HStack {
                        Text("\(rank + 1).")
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundSubtle)
                            .frame(width: 28, alignment: .trailing)
                        Text(state.productName(row.product_id))
                            .foregroundStyle(colors.foregroundNormal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        Text(Formatters.usd(row.revenue))
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }
                if state.topProducts.isEmpty && !state.isLoading {
                    Text("No sales yet for this store.")
                        .foregroundStyle(colors.foregroundSubtle)
                }
            }
        }
    }
}

private struct KpiCard: View {
    let title: String
    let value: String
    let query: String
    let explanation: String
    var identifier: String?
    @Environment(\.dittoColors) private var colors

    var body: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(colors.foregroundSubtle)
                    Spacer()
                    QueryInfoButton(query: query, explanation: explanation)
                }
                Text(value)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(colors.foregroundNormal)
                    // KPI values must never wrap ("$19,513,528.40" bleeding to
                    // a second line) — shrink to fit instead; the cards have
                    // ample width.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier(identifier ?? "")
                Spacer(minLength: 0)
            }
            // Fill the grid cell so all four cards render at identical size.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Plain-language explanations for the info sheets (QueryInfoButton) — written
/// for people new to DQL, not for the benchmark authors.
private enum Explanations {
    static let statusRevenue = """
    Counts this store's non-deleted orders and sums their totals, grouped by \
    status. It's the benchmark's by-status aggregation scoped to your store — \
    the same DQL shape the performance suite measures.
    """
    static let customersCount = """
    Counts the customer documents synced to this device. The app subscribes to \
    ALL customers unfiltered (subscription__customers_all) — a walk-in could be \
    anyone, so the whole 25K-row directory lives on device.
    """
    static let productsCount = """
    Counts the shared product catalog synced to this device (400 docs). The \
    catalog is subscribed unfiltered: a rep can sell anything, from any store.
    """
    static let monthlyTrend = """
    Groups this store's orders into calendar months with substr(order_date, 0, 7) \
    (DQL's substr is zero-based — a classic gotcha) and shows the latest 12. \
    One of the heavier aggregation queries in the benchmark.
    """
    static let lowStock = """
    Counts and lists inventory rows at your store with fewer than 5 units left. \
    The store filter rides the composite _id subfield (_id.store_id) — the \
    benchmark's index-backed "low stock alert" query.
    """
    static let topProducts = """
    Sums line totals per product across this store's order items and takes the \
    top N by revenue (the pull-down sets N). DQL v5.0 has no JOINs, so the query \
    projects product_id only and names resolve against the synced catalog.
    """
}

#Preview {
    DittoTheme {
        DashboardView()
            .environment(AppState())
    }
}
