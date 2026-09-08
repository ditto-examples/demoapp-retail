import 'dart:async';

import 'package:anvil/anvil.dart';
import 'package:ditto_live/ditto_live.dart' show StoreObserver;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ditto_manager.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../components.dart';
import '../formatters.dart';

/// Products catalog: paged live observers over the shared catalog (424 docs),
/// joined in-memory with this store's inventory (per-store subscription) for
/// stock badges. Low-stock mode pages the inventory collection directly. The
/// composite-_id teaching moment lives in the detail view's location lookup.
class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _Row {
  const _Row(this.product, this.stock);
  final Product product;
  final InventoryItem? stock;
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  static const productsWhere = 'FROM products WHERE deleted = false';
  static const productsByCategoryWhere = 'FROM products WHERE category_id = :categoryId AND deleted = false';

  /// Benchmark-shaped (inventory__select__low_stock): the store predicate
  /// keeps the list correct even if a store switch left stale inventory
  /// behind (don't rely on the eviction invariant alone).
  static const lowStockWhere = 'FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false';
  static const searchQuery = '''
SELECT * FROM products WHERE deleted = false
AND (sku = :term OR product_name ILIKE :like) ORDER BY product_name LIMIT 50''';

  static const screenExplanation =
      'The 400-product catalog is subscribed UNFILTERED — every device holds the whole thing, so chips and paging are instant and offline. Pagination is LIMIT/OFFSET in DQL (ORDER BY product_name, _id LIMIT <pageSize> OFFSET <…>) with a live COUNT(*) observer for the total — the query above is the exact paged query running now.\n\nCategory chips filter in the query (category_id), not in memory. "⚠ Low stock" pages the inventory collection directly (stock_level < 5, store-scoped via _id.store_id). Rows join the paged products with this store\'s inventory in memory for the stock badges — inventory syncs per-store, so badges climb as the store slice arrives. Search is one-shot (500 ms debounce): exact SKU match OR product-name ILIKE, first 50 matches.';

  var _categories = <Category>[];
  var _rows = <_Row>[];
  var _totalCount = 0;
  var _page = 1;
  var _pageSize = 25;
  String? _selectedCategoryId;
  List<Product>? _searchResults;
  var _lowStockOnly = false;
  String? _error;
  var _activeQuery = '';
  final _searchController = TextEditingController();

  bool get _isSearching => _searchResults != null;

  final _observers = <StoreObserver>[];
  StoreObserver? _pageObserver;
  StoreObserver? _countObserver;
  Timer? _searchDebounce;
  var _productsById = <String, Product>{};
  var _stockByProduct = <String, InventoryItem>{};
  String? _lastStoreId;

  List<_Row> get _visibleRows =>
      _searchResults?.map((p) => _Row(p, _stockByProduct[p.product_id])).toList() ?? _rows;

  @override
  void dispose() {
    _stop();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _stop() {
    for (final o in _observers) {
      o.cancel();
    }
    _observers.clear();
    _pageObserver?.cancel();
    _countObserver?.cancel();
    _pageObserver = null;
    _countObserver = null;
    _stockByProduct = {}; // never let the previous store's badges linger
  }

  void _start(String? storeId) {
    _stop();
    final manager = DittoManager.instance;
    try {
      _observers.add(manager.observe<Category>(
        'SELECT * FROM categories',
        Category.fromJson,
        onChange: (list) => setState(() => _categories = list..sort((a, b) => a.category_name.compareTo(b.category_name))),
      ));
      // The full catalog (424 docs) stays resident: id → name lookups.
      _observers.add(manager.observe<Product>(
        'SELECT * FROM products WHERE deleted = false',
        Product.fromJson,
        onChange: (list) => setState(() => _productsById = {for (final p in list) p.product_id: p}),
      ));
      // Inventory is already the selected store's slice (subscription) — the
      // store predicate keeps it correct even mid-switch.
      _observers.add(manager.observe<InventoryItem>(
        'SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false',
        InventoryItem.fromJson,
        arguments: {'storeId': storeId ?? ''},
        onChange: (items) => setState(() {
          // last-wins on duplicate keys: two stores' rows can coexist in the
          // re-evict window — never trap.
          _stockByProduct = {for (final i in items) i.product_id: i};
          _rows = _rows.map((r) => _Row(r.product, _stockByProduct[r.product.product_id])).toList();
        }),
      ));
      _restart(storeId);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _restart(String? storeId) {
    _pageObserver?.cancel();
    _countObserver?.cancel();
    _pageObserver = null;
    _countObserver = null;

    // Never render the previous store's rows.
    if (_lastStoreId != storeId) {
      setState(() {
        _rows = [];
        _totalCount = 0;
        _page = 1;
      });
    }
    _lastStoreId = storeId;

    try {
      if (_lowStockOnly) {
        _observeLowStockPage(storeId);
      } else {
        _observeProductsPage(storeId);
      }
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _clampIfNeeded(String? storeId) {
    final clamped = Paging.clampPage(_page, _totalCount, _pageSize);
    if (clamped != _page) {
      _page = clamped;
      _restart(storeId);
    }
  }

  void _observeProductsPage(String? storeId) {
    final categoryId = _selectedCategoryId;
    final whereClause = categoryId != null ? productsByCategoryWhere : productsWhere;
    final arguments = <String, dynamic>{'categoryId': ?categoryId};
    _countObserver = DittoManager.instance.observe<CountRow>(
      'SELECT COUNT(*) AS count $whereClause',
      CountRow.fromJson,
      arguments: arguments,
      onChange: (rows) {
        setState(() => _totalCount = rows.firstOrNull?.count ?? 0);
        _clampIfNeeded(storeId);
      },
    );
    final pageQuery = Paging.pageQuery('SELECT * $whereClause', 'product_name, _id', _page, _pageSize);
    setState(() => _activeQuery = categoryId != null ? pageQuery.replaceAll(':categoryId', "'$categoryId'") : pageQuery);
    _pageObserver = DittoManager.instance.observe<Product>(
      pageQuery,
      Product.fromJson,
      arguments: arguments,
      onChange: (products) => setState(() => _rows = products.map((p) => _Row(p, _stockByProduct[p.product_id])).toList()),
    );
  }

  void _observeLowStockPage(String? storeId) {
    final arguments = <String, dynamic>{'storeId': storeId ?? ''};
    _countObserver = DittoManager.instance.observe<CountRow>(
      'SELECT COUNT(*) AS count $lowStockWhere',
      CountRow.fromJson,
      arguments: arguments,
      onChange: (rows) {
        setState(() => _totalCount = rows.firstOrNull?.count ?? 0);
        _clampIfNeeded(storeId);
      },
    );
    final pageQuery = Paging.pageQuery('SELECT * $lowStockWhere', 'stock_level, _id', _page, _pageSize);
    setState(() => _activeQuery = pageQuery.replaceAll(':storeId', "'${storeId ?? ''}'"));
    _pageObserver = DittoManager.instance.observe<InventoryItem>(
      pageQuery,
      InventoryItem.fromJson,
      arguments: arguments,
      onChange: (items) => setState(() => _rows = [
        for (final item in items)
          if (_productsById[item.product_id] != null) _Row(_productsById[item.product_id]!, item),
      ]),
    );
  }

  /// One-shot search with 500 ms debounce — observers are for live screens;
  /// search-as-you-type is a series of point queries (first 50 matches).
  void _search() {
    _searchDebounce?.cancel();
    final term = _searchController.text.trim();
    if (term.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final results = await DittoManager.instance.fetch<Product>(
          searchQuery,
          Product.fromJson,
          arguments: {'term': term, 'like': '%$term%'},
        );
        if (mounted) setState(() => _searchResults = results);
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider);

    ref.listen(appSelectedStoreIdProvider, (previous, next) {
      // Products are global; the inventory slice is per-store.
      setState(() => _searchResults = null);
      _start(next);
    });
    if (_lastStoreId == null && selectedStoreId != null && _observers.isEmpty) {
      _start(selectedStoreId);
    }

    final infoQuery = _activeQuery.isEmpty ? 'SELECT * $productsWhere ORDER BY product_name, _id' : _activeQuery;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Products'),
        actions: [QueryInfoButton(query: infoQuery, explanation: screenExplanation, tooltip: 'About this screen')],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ZavaSearchField(
              controller: _searchController,
              placeholder: 'Search name or SKU…',
              onChanged: (_) => _search(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CategoryChip('All', _selectedCategoryId == null && !_lowStockOnly, () {
                    setState(() {
                      _selectedCategoryId = null;
                      _lowStockOnly = false;
                      _page = 1;
                    });
                    _restart(selectedStoreId);
                  }),
                  for (final category in _categories)
                    _CategoryChip(
                      category.category_name,
                      _selectedCategoryId == category.category_id && !_lowStockOnly,
                      () {
                        setState(() {
                          _selectedCategoryId = category.category_id;
                          _lowStockOnly = false;
                          _page = 1;
                        });
                        _restart(selectedStoreId);
                      },
                    ),
                  _CategoryChip('⚠ Low stock', _lowStockOnly, () {
                    setState(() {
                      _lowStockOnly = true;
                      _selectedCategoryId = null;
                      _page = 1;
                    });
                    _restart(selectedStoreId);
                  }),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colors.borderNormal),
          Expanded(
            child: _visibleRows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: _error != null
                          ? DittoBadge(_error!, status: BadgeStatus.critical)
                          : _isSearching
                              ? Text('No matches', style: TextStyle(color: colors.foregroundSubtle))
                              : const SkeletonRows(count: 8),
                    ),
                  )
                : ListView.separated(
                    itemCount: _visibleRows.length,
                    separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
                    itemBuilder: (context, index) {
                      final row = _visibleRows[index];
                      return _ProductRow(row, onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ProductDetailScreen(product: row.product, stock: row.stock)),
                          ));
                    },
                  ),
          ),
          if (!_isSearching) ...[
            Divider(height: 1, color: colors.borderNormal),
            PaginationBar(
              totalCount: _totalCount,
              page: _page,
              pageSize: _pageSize,
              pageSizes: const [25, 50, 100],
              onPage: (p) {
                setState(() => _page = p);
                _restart(selectedStoreId);
              },
              onPageSize: (s) {
                setState(() => _pageSize = s);
                _restart(selectedStoreId);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip(this.title, this.isSelected, this.onTap);
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? colors.fillBrandPrimary : colors.surfaceSecondary,
          borderRadius: BorderRadius.circular(999),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: isSelected ? colors.foregroundOnBrandPrimary : colors.foregroundNormal,
          ),
        ),
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow(this.row, {required this.onTap});
  final _Row row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final stock = row.stock;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row.product.product_name, style: TextStyle(color: colors.foregroundNormal)),
                Text(row.product.sku, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundSubtle)),
              ]),
            ),
            if (stock != null) ...[
              DittoBadge(
                '${stock.stock_level} in stock',
                status: stock.stock_level < 5 ? BadgeStatus.warning : BadgeStatus.info,
              ),
              const SizedBox(width: 8),
            ],
            Text(Formatters.usd(row.product.base_price), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
          ],
        ),
      ),
    );
  }
}

/// Product detail: this store's stock + shelf location. The location lookup is
/// the composite-_id subfield pattern (inventory._id is {store_id, product_id}).
class ProductDetailScreen extends StatelessWidget {
  const ProductDetailScreen({super.key, required this.product, required this.stock});
  final Product product;
  final InventoryItem? stock;

  static const locationQuery = '''
SELECT * FROM inventory
WHERE _id.store_id = :storeId AND _id.product_id = :productId AND deleted = false''';
  static const explanation = 'inventory._id is a composite key {store_id, product_id}. This query filters on its subfields to find the shelf location (aisle/shelf/bin) of a product at your store — the worker-app "find it on the shelf" pattern from the benchmark. Composite-subfield queries need an explicit index (the app creates zava_inventory_store).';

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Product'),
        actions: [QueryInfoButton(query: locationQuery, explanation: explanation, tooltip: 'About this screen')],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DittoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(product.product_name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                Row(children: [
                  Text(product.sku, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundSubtle)),
                  const Spacer(),
                  Text(Formatters.usd(product.base_price), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                ]),
                Text(
                  'cost ${Formatters.usd(product.cost)} · margin ${product.gross_margin_percent.toInt()}%',
                  style: TextStyle(fontSize: 14, color: colors.foregroundSubtle),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          DittoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Stock at this store', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                const SizedBox(height: 8),
                if (stock != null)
                  Row(children: [
                    DittoBadge('${stock!.stock_level} units', status: stock!.stock_level < 5 ? BadgeStatus.warning : BadgeStatus.success),
                    const Spacer(),
                    Text(
                      'Aisle ${stock!.location.aisle} · Shelf ${stock!.location.shelf} · Bin ${stock!.location.bin}',
                      style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 13, color: colors.foregroundNormal),
                    ),
                  ])
                else
                  Text('Not stocked at this store.', style: TextStyle(color: colors.foregroundSubtle)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
