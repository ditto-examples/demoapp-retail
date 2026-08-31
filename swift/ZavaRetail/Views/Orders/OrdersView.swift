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
    var error: String?

    private var pageObserver: DittoStoreObserver?
    private var countObserver: DittoStoreObserver?
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

        do {
            countObserver = try await DittoManager.shared.observe(
                countQuery, arguments: arguments, as: CountRow.self
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
                pageQuery, arguments: arguments, as: Order.self
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

    func stop() {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil
        restartTask?.cancel()
        restartTask = nil
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
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = OrdersState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if state.orders.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Syncing orders for this store…")
                                .foregroundStyle(colors.foregroundSubtle)
                            if let error = state.error {
                                AnvilBadge(error, status: .critical)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List(state.orders) { order in
                            NavigationLink(destination: OrderDetailView(order: order)) {
                                OrderRow(order: order)
                            }
                        }
                        .listStyle(.plain)
                    }
                }

                Divider()
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
            .background(colors.background)
            .navigationTitle("Orders")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $state.recentOnly) {
                        Text("Recent (30d of data)")
                            .font(.callout)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                }
            }
            .task { state.restart(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.recentOnly) { _, _ in
                state.page = 1
                state.restart(appState: appState)
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
