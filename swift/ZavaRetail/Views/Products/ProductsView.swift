import Anvil
import DittoSwift
import SwiftUI

/// Products catalog (shared) joined in-memory with this store's inventory
/// (per-store subscription) for stock badges — the composite-_id teaching
/// moment lives in the detail view's location lookup.
@MainActor
@Observable
final class ProductsState {
    var categories: [Category] = []
    var products: [Product] = []
    var selectedCategoryId: String?
    var searchText = ""
    var searchResults: [Product]?
    var stockByProduct: [String: InventoryItem] = [:]
    var lowStockOnly = false
    var error: String?

    private var categoriesObserver: DittoStoreObserver?
    private var productsObserver: DittoStoreObserver?
    private var inventoryObserver: DittoStoreObserver?
    private var searchTask: Task<Void, Never>?
    private var startedFor: String?

    static let productsQuery = "SELECT * FROM products WHERE deleted = false ORDER BY product_name"
    static let productsByCategoryQuery = """
    SELECT * FROM products WHERE category_id = :categoryId AND deleted = false ORDER BY product_name
    """
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
            // Inventory is already the selected store's slice (subscription) —
            // observe it all locally and index by product for stock badges.
            inventoryObserver = try await DittoManager.shared.observe(
                "SELECT * FROM inventory WHERE deleted = false", as: InventoryItem.self
            ) { [weak self] items in
                self?.stockByProduct = Dictionary(uniqueKeysWithValues: items.map { ($0.product_id, $0) })
            }
            await reloadProducts()
        } catch is CancellationError {
            // View torn down mid-start — not an error state.
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        categoriesObserver?.cancel()
        productsObserver?.cancel()
        inventoryObserver?.cancel()
        categoriesObserver = nil
        productsObserver = nil
        inventoryObserver = nil
        startedFor = nil
    }

    func restart(appState: AppState) async {
        stop()
        await start(appState: appState)
    }

    func reloadProducts() async {
        // Cancel the previous products observer FIRST — observers stay live
        // until cancelled, and an overwritten (non-cancelled) observer keeps
        // writing stale category results into `products` during sync storms.
        productsObserver?.cancel()
        productsObserver = nil
        do {
            if let categoryId = selectedCategoryId {
                productsObserver = try await DittoManager.shared.observe(
                    Self.productsByCategoryQuery,
                    arguments: ["categoryId": categoryId],
                    as: Product.self
                ) { [weak self] products in
                    self?.products = products
                }
            } else {
                productsObserver = try await DittoManager.shared.observe(
                    Self.productsQuery, as: Product.self
                ) { [weak self] products in
                    self?.products = products
                }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One-shot search with 500 ms debounce (mflix pattern) — observers are
    /// for live screens; search-as-you-type is a series of point queries.
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
                self?.searchResults = results
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    var visibleProducts: [Product] {
        let base = searchResults ?? products
        guard lowStockOnly else { return base }
        return base.filter { (stockByProduct[$0.product_id]?.stock_level ?? .max) < 5 }
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
                if state.visibleProducts.isEmpty {
                    Spacer()
                    Text(state.searchText.isEmpty ? "No products" : "No matches")
                        .foregroundStyle(colors.foregroundSubtle)
                    Spacer()
                } else {
                    List(state.visibleProducts) { product in
                        NavigationLink(destination: ProductDetailView(
                            product: product,
                            stock: state.stockByProduct[product.product_id]
                        )) {
                            ProductRow(
                                product: product,
                                stock: state.stockByProduct[product.product_id]
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(colors.background)
            .navigationTitle("Products")
            .task { await state.start(appState: appState) }
            .onDisappear { state.stop() }
            .onChange(of: appState.selectedStoreId) { _, _ in
                Task { await state.restart(appState: appState) }
            }
            .onChange(of: state.selectedCategoryId) { _, _ in
                Task { await state.reloadProducts() }
            }
            .onChange(of: state.searchText) { _, _ in state.search() }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            AnvilInput(placeholder: "Search name or SKU…", text: $state.searchText)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    CategoryChip(title: "All", isSelected: state.selectedCategoryId == nil) {
                        state.selectedCategoryId = nil
                    }
                    ForEach(state.categories) { category in
                        CategoryChip(
                            title: category.category_name,
                            isSelected: state.selectedCategoryId == category.category_id
                        ) {
                            state.selectedCategoryId = category.category_id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 0)
            Toggle(isOn: $state.lowStockOnly) {
                Text("Low stock only (this store)")
                    .font(.callout)
                    .foregroundStyle(colors.foregroundSubtle)
            }
            .toggleStyle(.switch)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors

    static let locationQuery = """
    SELECT * FROM inventory \
    WHERE _id.store_id = :storeId AND _id.product_id = :productId AND deleted = false
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
                        Text("Stock at this store")
                            .font(.headline).foregroundStyle(colors.foregroundNormal)
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
                        QueryCallout(query: Self.locationQuery)
                        Text("inventory._id is a composite key {store_id, product_id} — this query filters on its subfields.")
                            .font(.caption)
                            .foregroundStyle(colors.foregroundSubtle)
                    }
                }
            }
            .padding()
        }
        .background(colors.background)
        .navigationTitle("Product")
    }
}
