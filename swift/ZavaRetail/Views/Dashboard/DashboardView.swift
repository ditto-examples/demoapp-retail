import SwiftUI
import Anvil
import DittoSwift
import OSLog

/// Dashboard KPI queries — derived from the benchmark's AGGREGATION entries
/// (orders__aggregation__sum_total_by_status, orders__aggregation__count_by_month,
/// order_items__aggregation__top_products_by_revenue, inventory__select__low_stock_*).
/// Aliases are added so rows decode into typed models; the exact string that
/// executed is always shown in the card's DQL callout.
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
    static let lowStock = """
        SELECT COUNT(*) AS count FROM inventory WHERE stock_level < 5 AND deleted = false
        """
    // Verbatim order_items__aggregation__top_products_by_revenue (the
    // benchmark projects ONLY group keys + aggregates — DQL rejects
    // projecting product_name here: "must depend only on group keys or
    // aggregates"). The row shows product_id; names resolve client-side
    // against the shared products catalog if ever needed.
    static let topProducts = """
        SELECT product_id, SUM(line_total) AS revenue \
        FROM order_items WHERE store_id = :storeId AND deleted = false \
        GROUP BY product_id ORDER BY revenue DESC LIMIT 5
        """
}

// Aggregate row models (decoded via the same DittoManager.fetch path).
struct StatusRevenueRow: Sendable, Decodable {
    let status: String
    let orders: Int
    let revenue: Double
}
struct MonthTrendRow: Sendable, Decodable, Identifiable {
    let month: String
    let orders: Int
    let revenue: Double
    var id: String { month }
}
struct CountRow: Sendable, Decodable {
    let count: Int
}
struct TopProductRow: Sendable, Decodable, Identifiable {
    let product_id: String
    let revenue: Double
    var id: String { product_id }
}

@MainActor
@Observable
final class DashboardState {
    var statusRows: [StatusRevenueRow] = []
    var monthRows: [MonthTrendRow] = []
    var lowStockCount: Int?
    var topProducts: [TopProductRow] = []
    var isLoading = false
    var error: String?

    private var loadedFor: String?

    func refresh(appState: AppState) async {
        guard let storeId = appState.selectedStoreId else { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let status: [StatusRevenueRow] = DittoManager.shared.fetch(
                DashboardQueries.statusRevenue, arguments: ["storeId": storeId], as: StatusRevenueRow.self)
            async let months: [MonthTrendRow] = DittoManager.shared.fetch(
                DashboardQueries.monthlyTrend, arguments: ["storeId": storeId], as: MonthTrendRow.self)
            async let lowStock: [CountRow] = DittoManager.shared.fetch(
                DashboardQueries.lowStock, as: CountRow.self)
            async let top: [TopProductRow] = DittoManager.shared.fetch(
                DashboardQueries.topProducts, arguments: ["storeId": storeId], as: TopProductRow.self)
            statusRows = try await status.sorted { $0.orders > $1.orders }
            monthRows = try await months
            lowStockCount = try await lowStock.first?.count
            topProducts = try await top
            loadedFor = storeId
            Logger.sync.info("dashboard refresh for \(storeId, privacy: .public): \(self.statusRows.count) status rows, \(self.monthRows.count) months, lowStock=\(self.lowStockCount ?? -1), topProducts=\(self.topProducts.count)")
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

    private var totalOrders: Int { state.statusRows.reduce(0) { $0 + $1.orders } }
    private var totalRevenue: Double { state.statusRows.reduce(0) { $0 + $1.revenue } }

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store?.store_name ?? appState.selectedStoreId ?? "—")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(colors.foregroundNormal)
            if let store {
                Text("\(store.location.address), \(store.location.city), \(store.location.state)")
                    .font(.subheadline)
                    .foregroundStyle(colors.foregroundSubtle)
            }
            if let error = state.error {
                AnvilBadge(error, status: .critical)
            }
        }
    }

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            KpiCard(title: "Orders", value: "\(totalOrders.formatted())",
                    query: DashboardQueries.statusRevenue, identifier: "kpi.orders")
            KpiCard(title: "Revenue (all time)", value: Formatters.usd(totalRevenue),
                    query: DashboardQueries.statusRevenue, identifier: "kpi.revenue")
        }
    }

    private var trendCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Monthly trend")
                    .font(.headline).foregroundStyle(colors.foregroundNormal)
                let maxOrders = max(1, state.monthRows.map(\.orders).max() ?? 1)
                ForEach(state.monthRows) { row in
                    HStack {
                        Text(row.month)
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundSubtle)
                            .frame(width: 60, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(colors.fillBrandPrimary)
                                .frame(width: geo.size.width * CGFloat(row.orders) / CGFloat(maxOrders))
                        }
                        .frame(height: 14)
                        Text("\(row.orders.formatted())")
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundNormal)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                if state.monthRows.isEmpty && !state.isLoading {
                    Text("No orders synced yet for this store.")
                        .foregroundStyle(colors.foregroundSubtle)
                }
                QueryCallout(query: DashboardQueries.monthlyTrend)
            }
        }
    }

    private var lowStockCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Low stock")
                        .font(.headline).foregroundStyle(colors.foregroundNormal)
                    Spacer()
                    if let count = state.lowStockCount {
                        AnvilBadge("\(count) SKU\(count == 1 ? "" : "s") under 5 units",
                                   status: count > 0 ? .warning : .success)
                    }
                }
                QueryCallout(query: DashboardQueries.lowStock)
            }
        }
    }

    private var topProductsCard: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top products by revenue")
                    .font(.headline).foregroundStyle(colors.foregroundNormal)
                ForEach(state.topProducts) { row in
                    HStack {
                        Text(row.product_id)
                            .font(.dittoCode(size: 12))
                            .foregroundStyle(colors.foregroundNormal)
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
                QueryCallout(query: DashboardQueries.topProducts)
            }
        }
    }
}

private struct KpiCard: View {
    let title: String
    let value: String
    let query: String
    var identifier: String?
    @Environment(\.dittoColors) private var colors

    var body: some View {
        AnvilCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(colors.foregroundSubtle)
                Text(value)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(colors.foregroundNormal)
                    .accessibilityIdentifier(identifier ?? "")
                QueryCallout(query: query)
            }
        }
    }
}

#Preview {
    DittoTheme {
        DashboardView()
            .environment(AppState())
    }
}
