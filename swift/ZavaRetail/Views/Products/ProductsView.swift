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
    private var productsById: [String: Product] = [:]
    private var startedFor: String?

    static let productsWhere = "FROM products WHERE deleted = false"
    static let productsByCategoryWhere = "FROM products WHERE category_id = :categoryId AND deleted = false"
    static let lowStockWhere = "FROM inventory WHERE stock_level < 5 AND deleted = false"
    static let searchQuery = """
    SELECT * FROM products WHERE deleted = false \
    AND (sku = :term OR product_name LIKE :like) ORDER BY product_name LIMIT 50
    """

    func start(appState: AppState) async {
        guard startedFor == nil else { return }
        startedFor = appState.selectedStoreId
        do {
            categoriesObserver = try await DittoManager.shared.observe(
                "SELECT * FROM categories", as: Category.self
            ) { [weak self] categories in
                self?.categories = categories.sorted { $0.category_name < $1.category_name }
            }
            // The full catalog (400 docs) stays resident: id → name lookups
            // for inventory rows and the low-stock view.
            productsAllObserver = try await DittoManager.shared.observe(
                "SELECT * FROM products WHERE deleted = false", as: Product.self
            ) { [weak self] products in
                self?.productsById = Dictionary(uniqueKeysWithValues: products.map { ($0.product_id, $0) })
            }
            // Inventory is already the selected store's slice (subscription).
            inventoryAllObserver = try await DittoManager.shared.observe(
                "SELECT * FROM inventory WHERE deleted = false", as: InventoryItem.self
            ) { [weak self] items in
                guard let self else { return }
                stockByProduct = Dictionary(uniqueKeysWithValues: items.map { ($0.product_id, $0) })
                // Refresh badges on the visible page when stock changes.
                rows = rows.map { Row(product: $0.product, stock: stockByProduct[$0.product.id]) }
            }
            restart(appState: appState)
        } catch is CancellationError {
            // View torn down mid-start — not an error state.
        } catch {
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
        startedFor = nil
    }

    func restart(appState: AppState) {
        let previous = restartTask
        restartTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await reloadPage()
        }
    }

    private func reloadPage() async {
        pageObserver?.cancel()
        countObserver?.cancel()
        pageObserver = nil
        countObserver = nil

        do {
            if lowStockOnly {
                try await observeLowStockPage()
            } else {
                try await observeProductsPage()
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func observeProductsPage() async throws {
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
            self?.totalCount = rows.first?.count ?? 0
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

    private func observeLowStockPage() async throws {
        countObserver = try await DittoManager.shared.observe(
            "SELECT COUNT(*) AS count \(Self.lowStockWhere)", as: CountRow.self
        ) { [weak self] rows in
            self?.totalCount = rows.first?.count ?? 0
        }
        let pageQuery = Paging.pageQuery(
            base: "SELECT * \(Self.lowStockWhere)", orderBy: "stock_level, _id",
            page: page, pageSize: pageSize
        )
        pageObserver = try await DittoManager.shared.observe(
            pageQuery, as: InventoryItem.self
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
                let results = try await DittoManager.shared.fetch(
                    Self.searchQuery,
                    arguments: ["term": term, "like": "%\(term)%"],
                    as: Product.self
                )
                self?.searchResults = results
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
                        Text(state.isSearching ? "No matches" : "No products on this page yet — sync may still be running")
                            .foregroundStyle(colors.foregroundSubtle)
                            .multilineTextAlignment(.center)
                            .padding()
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
        VStack(spacing: 10) {
            AnvilInput(placeholder: "Search name or SKU…", text: $state.searchText)
            // Flow layout so chips WRAP instead of clipping on narrow windows
            // (macOS resize, iPad split view).
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
