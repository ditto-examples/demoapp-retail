import Anvil
import DittoSwift
import OSLog
import SwiftUI

/// The orders list is a live store observer (PLAN §4.2.2). The "recent"
/// filter anchors to max(order_date) in the local store — the dataset ends
/// 2025-06-27, so a device-clock-relative filter would show zero rows.
@MainActor
@Observable
final class OrdersState {
    var orders: [Order] = []
    var recentOnly = false
    var limit = 100
    var error: String?

    private var observer: DittoStoreObserver?
    /// Restart serialization: every restart cancels and awaits the in-flight
    /// one, so rapid filter changes can't leave two observers alive (M7).
    private var restartTask: Task<Void, Never>?

    private struct MaxDateRow: Sendable, Decodable {
        let max_date: String?
    }

    static let baseQuery = """
    SELECT * FROM orders WHERE store_id = :storeId AND deleted = false
    """

    /// Non-blocking restart entry point for view events: serializes against
    /// any in-flight restart so two rapid changes can't interleave.
    func restart(appState: AppState) {
        let previous = restartTask
        restartTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await restartNow(appState: appState)
        }
    }

    private func restartNow(appState: AppState) async {
        // Not stop(): stop() also cancels restartTask — which is US.
        observer?.cancel()
        observer = nil
        guard let storeId = appState.selectedStoreId else { return }

        var query = Self.baseQuery
        var arguments: [String: Sendable] = ["storeId": storeId]
        if recentOnly,
           let maxDate = await latestOrderDate(storeId: storeId),
           let cutoff = Self.cutoffDate(from: maxDate, days: 30)
        {
            query += " AND order_date > :cutoff"
            arguments["cutoff"] = cutoff
        }
        // LIMIT is interpolated (Int from our own stepper — never user text).
        query += " ORDER BY order_date DESC LIMIT \(limit)"

        do {
            observer = try await DittoManager.shared.observe(query, arguments: arguments, as: Order.self) { [weak self] orders in
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
        observer?.cancel()
        observer = nil
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
                } else {
                    List(state.orders) { order in
                        NavigationLink(destination: OrderDetailView(order: order)) {
                            OrderRow(order: order)
                        }
                    }
                    .listStyle(.plain)
                }
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
                ToolbarItem(placement: .automatic) {
                    Menu("Show \(state.limit)") {
                        ForEach([50, 100, 500, 1000], id: \.self) { value in
                            Button("\(value)") { state.limit = value }
                        }
                    }
                }
            }
            .task { state.restart(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                state.restart(appState: appState)
            }
            .onChange(of: state.recentOnly) { _, _ in
                state.restart(appState: appState)
            }
            .onChange(of: state.limit) { _, _ in
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
                        Text("Line items")
                            .font(.headline).foregroundStyle(colors.foregroundNormal)
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
                        QueryCallout(query: Self.itemsQuery)
                        Text("DQL has no JOINs: order detail = orders by _id + order_items by order_id.")
                            .font(.caption)
                            .foregroundStyle(colors.foregroundSubtle)
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
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
