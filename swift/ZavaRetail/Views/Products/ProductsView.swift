import Anvil
import DittoSwift
import OSLog
import SwiftUI

/// Products catalog: paged live observers over the shared catalog (400 docs),
/// joined in-memory with this store's inventory (per-store subscription) for
/// stock badges. Low-stock mode pages the inventory collection directly. The
/// composite-_id teaching moment lives in the detail view's location lookup.
@MainActor
@Observable
final class ProductsState {
    var categories: [Category] = []
    var rows: [Row] = []
    var totalCount = 0
    var page = 1
    var pageSize = 25
    var selectedCategoryId: String?
    var searchText = ""
    var searchResults: [Product]?
    var lowStockOnly = false
    var error: String?

    /// A row is a product plus (when stocked at this store) its inventory.
    struct Row: Identifiable, Equatable {
        let product: Product
        let stock: InventoryItem?
        var id: String {
            product.id
        }
    }

    private var categoriesObserver: DittoStoreObserver?
    private var productsAllObserver: DittoStoreObserver?
    private var inventoryAllObserver: DittoStoreObserver?
    private var pageObserver: DittoStoreObserver?
    private var countObserver: DittoStoreObserver?
    private var restartTask: Task<Void, Never>?
    /// Dedicated search task — deliberately NOT restartTask: typing must not
    /// cancel a pending observer restart, and a restart must not await the
    /// 500 ms debounce (same discipline as OrdersState).
    private var searchTask: Task<Void, Never>?
    private var productsById: [String: Product] = [:]
    private var startedFor: String?
    private var lastStoreId: String?

    static let productsWhere = "FROM products WHERE deleted = false"
    static let productsByCategoryWhere = "FROM products WHERE category_id = :categoryId AND deleted = false"
    /// Benchmark-shaped (inventory__select__low_stock): the store predicate
    /// keeps the list correct even if a store switch left stale inventory
    /// behind (don't rely on the eviction invariant alone — same hardening as
    /// the dashboard's low-stock card).
    static let lowStockWhere = "FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false"
    static let searchQuery = """
    SELECT * FROM products WHERE deleted = false \
    AND (sku = :term OR product_name ILIKE :like) ORDER BY product_name LIMIT 50
    """

    func start(appState: AppState) async {
        guard startedFor == nil else { return }
        startedFor = appState.selectedStoreId
        // Register sequentially: on a mid-start throw, cancel whatever
        // registered rather than leaking live observers (array-literal
        // registration drops partial results untracked).
        var registered: [DittoStoreObserver] = []
        do {
            let categories = try await DittoManager.shared.observe(
                "SELECT * FROM categories", as: Category.self
            ) { [weak self] categories in
                self?.categories = categories.sorted { $0.category_name < $1.category_name }
            }
            registered.append(categories)
            try Task.checkCancellation()
            // The full catalog (400 docs) stays resident: id → name lookups
            // for inventory rows and the low-stock view.
            let productsAll = try await DittoManager.shared.observe(
                "SELECT * FROM products WHERE deleted = false", as: Product.self
            ) { [weak self] products in
                // Safe to trap on duplicate keys: products is the globally
                // unique shared catalog (unlike per-store inventory, two
                // stores' rows can never coexist here).
                self?.productsById = Dictionary(uniqueKeysWithValues: products.map { ($0.product_id, $0) })
            }
            registered.append(productsAll)
            try Task.checkCancellation()
            // Inventory is already the selected store's slice (subscription) —
            // but the store predicate keeps it correct even if a switch left
            // stale rows behind (never trust the eviction invariant alone).
            let storeId = appState.selectedStoreId ?? ""
            let inventoryAll = try await DittoManager.shared.observe(
                "SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false",
                arguments: ["storeId": storeId], as: InventoryItem.self
            ) { [weak self] items in
                guard let self else { return }
                // uniquingKeysWith: two stores' rows can coexist in the
                // re-evict window — never trap on duplicate keys.
                stockByProduct = Dictionary(items.map { ($0.product_id, $0) }, uniquingKeysWith: { _, new in new })
                // Refresh badges on the visible page when stock changes.
                rows = rows.map { Row(product: $0.product, stock: stockByProduct[$0.product.product_id]) }
            }
            registered.append(inventoryAll)
            categoriesObserver = registered[0]
            productsAllObserver = registered[1]
            inventoryAllObserver = registered[2]
            restart(appState: appState)
        } catch is CancellationError {
            registered.forEach { $0.cancel() }
            // View torn down mid-start — not an error state.
        } catch {
            registered.forEach { $0.cancel() }
            self.error = error.localizedDescription
        }
    }

    private var stockByProduct: [String: InventoryItem] = [:]

    func stop() {
        categoriesObserver?.cancel()
        productsAllObserver?.cancel()
        inventoryAllObserver?.cancel()
        pageObserver?.cancel()
        countObserver?.cancel()
        categoriesObserver = nil
        productsAllObserver = nil
        inventoryAllObserver = nil
        pageObserver = nil
        countObserver = nil
        restartTask?.cancel()
        restartTask = nil
        searchTask?.cancel()
        searchTask = nil
        stockByProduct = [:] // never let the previous store's badges linger
        startedFor = nil
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

        // Never render the previous store's rows: clear before re-registering
        // so the skeleton shows instead of stale data.
        if lastStoreId != appState.selectedStoreId {
            rows = []
            totalCount = 0
            page = 1
        }
        lastStoreId = appState.selectedStoreId

        do {
            if lowStockOnly {
                try await observeLowStockPage(appState: appState)
            } else {
                try await observeProductsPage(appState: appState)
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// When the count shrinks under the current page (deletion, store switch,
    /// filter change), clamp and restart — same discipline as OrdersState;
    /// otherwise the page observer's OFFSET returns nothing and the screen
    /// sits on skeletons forever.
    private func clampIfNeeded(appState: AppState) {
        let clamped = Paging.clampPage(page, total: totalCount, pageSize: pageSize)
        if clamped != page {
            page = clamped
            restart(appState: appState)
        }
    }

    private func observeProductsPage(appState: AppState) async throws {
        let whereClause: String
        var arguments: [String: Sendable] = [:]
        if let categoryId = selectedCategoryId {
            whereClause = Self.productsByCategoryWhere
            arguments["categoryId"] = categoryId
        } else {
            whereClause = Self.productsWhere
        }
        countObserver = try await DittoManager.shared.observe(
            "SELECT COUNT(*) AS count \(whereClause)", arguments: arguments, as: CountRow.self
        ) { [weak self] rows in
            guard let self else { return }
            totalCount = rows.first?.count ?? 0
            clampIfNeeded(appState: appState)
        }
        // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
        // repeat rows across pages.
        let pageQuery = Paging.pageQuery(
            base: "SELECT * \(whereClause)", orderBy: "product_name, _id",
            page: page, pageSize: pageSize
        )
        pageObserver = try await DittoManager.shared.observe(
            pageQuery, arguments: arguments, as: Product.self
        ) { [weak self] products in
            guard let self else { return }
            rows = products.map { Row(product: $0, stock: stockByProduct[$0.product_id]) }
        }
    }

    private func observeLowStockPage(appState: AppState) async throws {
        let storeId = appState.selectedStoreId ?? ""
        let arguments: [String: Sendable] = ["storeId": storeId]
        countObserver = try await DittoManager.shared.observe(
            "SELECT COUNT(*) AS count \(Self.lowStockWhere)", arguments: arguments, as: CountRow.self
        ) { [weak self] rows in
            guard let self else { return }
            totalCount = rows.first?.count ?? 0
            clampIfNeeded(appState: appState)
        }
        let pageQuery = Paging.pageQuery(
            base: "SELECT * \(Self.lowStockWhere)", orderBy: "stock_level, _id",
            page: page, pageSize: pageSize
        )
        pageObserver = try await DittoManager.shared.observe(
            pageQuery, arguments: arguments, as: InventoryItem.self
        ) { [weak self] items in
            guard let self else { return }
            rows = items.compactMap { item in
                guard let product = productsById[item.product_id] else { return nil }
                return Row(product: product, stock: item)
            }
        }
    }

    /// One-shot search with 500 ms debounce — observers are for live screens;
    /// search-as-you-type is a series of point queries (first 50 matches).
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
                let results = try await DittoManager.shared.fetch(
                    Self.searchQuery,
                    arguments: ["term": term, "like": "%\(term)%"],
                    as: Product.self
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

    var isSearching: Bool {
        searchResults != nil
    }

    var visibleRows: [Row] {
        if let searchResults {
            return searchResults.map { Row(product: $0, stock: stockByProduct[$0.product_id]) }
        }
        return rows
    }
}

struct ProductsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors
    @State private var state = ProductsState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls

                Group {
                    if state.visibleRows.isEmpty {
                        Spacer()
                        // The error must render — a failed observer/search
                        // must never look like an eternal skeleton.
                        if let error = state.error {
                            AnvilBadge(error, status: .critical)
                        } else if state.isSearching {
                            Text("No matches")
                                .foregroundStyle(colors.foregroundSubtle)
                        } else {
                            SkeletonRows(count: 8)
                                .padding()
                        }
                        Spacer()
                    } else {
                        List(state.visibleRows) { row in
                            NavigationLink(destination: ProductDetailView(product: row.product, stock: row.stock)) {
                                ProductRow(product: row.product, stock: row.stock)
                            }
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
            .navigationTitle("Products")
            .searchable(text: $state.searchText, prompt: "Search name or SKU…")
            .task { await state.start(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                state.stop()
                Task { await state.start(appState: appState) }
            }
            .onChange(of: state.selectedCategoryId) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.lowStockOnly) { _, _ in
                state.page = 1
                state.restart(appState: appState)
            }
            .onChange(of: state.searchText) { _, _ in state.search() }
        }
    }

    private var controls: some View {
        // Flow layout so chips WRAP instead of clipping on narrow windows
        // (macOS resize, iPad split view). Search is the platform-standard
        // .searchable field (nav bar / toolbar) with its × clear affordance.
        FlowLayout {
            CategoryChip(title: "All", isSelected: state.selectedCategoryId == nil && !state.lowStockOnly) {
                state.selectedCategoryId = nil
                state.lowStockOnly = false
            }
            ForEach(state.categories) { category in
                CategoryChip(
                    title: category.category_name,
                    isSelected: state.selectedCategoryId == category.category_id && !state.lowStockOnly
                ) {
                    state.selectedCategoryId = category.category_id
                    state.lowStockOnly = false
                }
            }
            CategoryChip(title: "⚠ Low stock", isSelected: state.lowStockOnly) {
                state.lowStockOnly = true
                state.selectedCategoryId = nil
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.dittoColors) private var colors

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? colors.fillBrandPrimary : colors.surfaceSecondary)
                .foregroundStyle(isSelected ? colors.foregroundOnBrandPrimary : colors.foregroundNormal)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ProductRow: View {
    let product: Product
    let stock: InventoryItem?
    @Environment(\.dittoColors) private var colors

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.product_name)
                    .foregroundStyle(colors.foregroundNormal)
                Text(product.sku)
                    .font(.dittoCode(size: 11))
                    .foregroundStyle(colors.foregroundSubtle)
            }
            Spacer()
            if let stock {
                let level = stock.stock_level
                AnvilBadge(
                    "\(level) in stock",
                    status: level < 5 ? .warning : .info
                )
            }
            Text(Formatters.usd(product.base_price))
                .font(.headline)
                .foregroundStyle(colors.foregroundNormal)
        }
        .padding(.vertical, 2)
    }
}

/// Product detail: this store's stock + shelf location. The location lookup is
/// the composite-_id subfield pattern (inventory._id is {store_id, product_id}).
struct ProductDetailView: View {
    let product: Product
    let stock: InventoryItem?
    @Environment(\.dittoColors) private var colors

    static let locationQuery = """
    SELECT * FROM inventory \
    WHERE _id.store_id = :storeId AND _id.product_id = :productId AND deleted = false
    """

    static let explanation = """
    inventory._id is a composite key {store_id, product_id}. This query filters on \
    its subfields to find the shelf location (aisle/shelf/bin) of a product at your \
    store — the worker-app "find it on the shelf" pattern from the benchmark. \
    Composite-subfield queries need an explicit index (the app creates zava_inventory_store).
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AnvilCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(product.product_name)
                            .font(.title3).foregroundStyle(colors.foregroundNormal)
                        HStack {
                            Text(product.sku)
                                .font(.dittoCode(size: 12))
                                .foregroundStyle(colors.foregroundSubtle)
                            Spacer()
                            Text(Formatters.usd(product.base_price))
                                .font(.title2).fontWeight(.semibold)
                                .foregroundStyle(colors.foregroundNormal)
                        }
                        Text("cost \(Formatters.usd(product.cost)) · margin \(Int(product.gross_margin_percent))%")
                            .font(.subheadline)
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }

                AnvilCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Stock at this store")
                                .font(.headline).foregroundStyle(colors.foregroundNormal)
                            Spacer()
                            QueryInfoButton(query: Self.locationQuery, explanation: Self.explanation)
                        }
                        if let stock {
                            HStack {
                                AnvilBadge(
                                    "\(stock.stock_level) units",
                                    status: stock.stock_level < 5 ? .warning : .success
                                )
                                Spacer()
                                Text("Aisle \(stock.location.aisle) · Shelf \(stock.location.shelf) · Bin \(stock.location.bin)")
                                    .font(.dittoCode(size: 13))
                                    .foregroundStyle(colors.foregroundNormal)
                            }
                        } else {
                            Text("Not stocked at this store.")
                                .foregroundStyle(colors.foregroundSubtle)
                        }
                    }
                }
            }
            .padding()
        }
        .background(colors.background)
        .navigationTitle("Product")
    }
}
