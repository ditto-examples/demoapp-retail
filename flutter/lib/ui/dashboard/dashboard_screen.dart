import 'package:anvil/anvil.dart';
import 'package:ditto_live/ditto_live.dart' show StoreObserver;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/ditto_manager.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../components.dart';
import '../formatters.dart';

/// Dashboard KPI queries — derived from the benchmark's AGGREGATION entries.
/// Aliases are added so rows decode into typed models; the exact string that
/// executes is always shown in the card's info sheet.
class DashboardQueries {
  static const statusRevenue = '''
SELECT status, COUNT(*) AS orders, SUM(total) AS revenue
FROM orders WHERE store_id = :storeId AND deleted = false GROUP BY status''';
  static const monthlyTrend = '''
SELECT substr(order_date, 0, 7) AS month, COUNT(*) AS orders, SUM(total) AS revenue
FROM orders WHERE store_id = :storeId AND deleted = false
GROUP BY substr(order_date, 0, 7) ORDER BY substr(order_date, 0, 7) DESC LIMIT 12''';

  /// Benchmark-shaped (inventory__select__low_stock): the store predicate
  /// keeps the KPI correct even if a store switch left stale inventory
  /// behind (don't rely on the eviction invariant alone).
  static const lowStock = '''
SELECT COUNT(*) AS count FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false''';

  /// The rows behind the count — the card lists the most critical SKUs.
  static const lowStockItems = '''
SELECT * FROM inventory WHERE stock_level < 5 AND _id.store_id = :storeId AND deleted = false
ORDER BY stock_level LIMIT 5''';

  /// The full customer directory is an unfiltered subscription — this count
  /// is the shared directory every device holds (25K docs).
  static const customersCount = 'SELECT COUNT(*) AS count FROM customers WHERE deleted = false';

  /// The shared catalog (400 products, unfiltered subscription).
  static const productsCount = 'SELECT COUNT(*) AS count FROM products WHERE deleted = false';

  /// Top products by revenue for the selected store. order_items has no
  /// store_id in the normalized schema — the store filter applies to the
  /// parent order through an INNER JOIN (the suite's canonical "items via
  /// orders" shape). LIMIT comes from the card's pull-down (5/10/25/50/100).
  /// DQL GROUP BY projects only group keys + aggregates, so product names
  /// resolve client-side against the synced catalog.
  static String topProducts(int limit) => '''
SELECT oi.product_id, SUM(oi.line_total) AS revenue
FROM order_items AS oi INNER JOIN orders AS o ON oi.order_id = o._id
WHERE o.store_id = :storeId AND o.deleted = false AND oi.deleted = false
GROUP BY oi.product_id ORDER BY revenue DESC LIMIT $limit''';

  /// The whole catalog is small (400 docs) — observed live so aggregate rows
  /// (product_id only) can display product names.
  static const productsCatalog = 'SELECT * FROM products WHERE deleted = false';
}

class _Explanations {
  static const statusRevenue = "Counts this store's non-deleted orders and sums their totals, grouped by status. It's the benchmark's by-status aggregation scoped to your store — the same DQL shape the performance suite measures.";
  static const customersCount = 'Counts the customer documents synced to this device. The app subscribes to ALL customers unfiltered — a walk-in could be anyone, so the whole 25K-row directory lives on device.';
  static const productsCount = 'Counts the shared product catalog synced to this device (400 docs). The catalog is subscribed unfiltered: a rep can sell anything, from any store.';
  static const monthlyTrend = "Groups this store's orders into calendar months with substr(order_date, 0, 7) (DQL's substr is zero-based — a classic gotcha) and shows the latest 12. One of the heavier aggregation queries in the benchmark.";
  static const lowStock = 'Counts and lists inventory rows at your store with fewer than 5 units left. The store filter rides the composite _id.store_id subfield (_id.store_id) — the benchmark\'s index-backed "low stock alert" query.';
  static const topProducts = "Sums line totals per product across this store's order items and takes the top N by revenue (the pull-down sets N). Items carry no store of their own in the normalized schema — the store filter rides an INNER JOIN to the parent order. The GROUP BY projects product_id only, so names resolve against the synced catalog. This card is a live observer: values climb as sync delivers the store.";
  static const screen = 'Every card is a LIVE store observer, not a one-shot fetch — after a store switch the values climb as the new store syncs, and ghost cards cover the gap so you never see another store\'s rows. The KPI cards aggregate orders by status (COUNT + SUM, above with your store substituted); the trend groups orders into months with substr(order_date, 0, 7) (DQL\'s substr is zero-based); low stock rides the composite _id.store_id subfield; top products sums line totals per product with the store filter applied through an INNER JOIN to the parent order (normalized order_items carry no store of their own). Each card\'s own ⓘ shows the exact query behind it.';
}

/// The dashboard is LIVE: every card is a store observer, not a one-shot
/// fetch — after a store switch the cards climb as the new store's data syncs
/// (the demo's headline moment), with no manual refresh and no stale data
/// (a store change clears the snapshot first; ghost cards show meanwhile).
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  var _statusRows = <StatusRevenueRow>[];
  var _monthRows = <MonthTrendRow>[];
  int? _lowStockCount;
  var _lowStockItems = <InventoryItem>[];
  var _topProducts = <TopProductRow>[];
  var _topProductsLimit = 5;
  int? _customersCount;
  int? _productsCount;
  var _productNames = <String, String>{};
  String? _error;

  final _observers = <StoreObserver>[];
  String? _loadedFor;

  String _productName(String productId) => _productNames[productId] ?? productId;

  /// True while the visible snapshot belongs to a different store than the
  /// selection (initial load + the window after a switch).
  bool _isStale(String? selectedStoreId) => _loadedFor != selectedStoreId;

  void _clearForStoreChange() {
    _statusRows = [];
    _monthRows = [];
    _lowStockCount = null;
    _lowStockItems = [];
    _topProducts = [];
    _customersCount = null;
    _productsCount = null;
    _loadedFor = null;
  }

  void _cancelObservers() {
    for (final o in _observers) {
      o.cancel();
    }
    _observers.clear();
  }

  void stop() {
    _cancelObservers();
    _loadedFor = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  void _start(String? storeId) {
    if (storeId == null) return;
    _cancelObservers();
    final manager = DittoManager.instance;
    // Registration is synchronous here (no async gap): the whole sequence is
    // atomic by construction — the async-registration hazards the other
    // platforms guard against don't exist on Dart's event loop.
    try {
      final storeArgs = {'storeId': storeId};
      _observers.add(manager.observe<StatusRevenueRow>(
        DashboardQueries.statusRevenue, StatusRevenueRow.fromJson,
        arguments: storeArgs,
        onChange: (rows) => setState(() => _statusRows = rows.where((r) => r.status != null).toList()
          ..sort((a, b) => b.orders.compareTo(a.orders))),
      ));
      _observers.add(manager.observe<MonthTrendRow>(
        DashboardQueries.monthlyTrend, MonthTrendRow.fromJson,
        arguments: storeArgs,
        onChange: (rows) => setState(() => _monthRows = rows.where((r) => r.month != null).toList()),
      ));
      _observers.add(manager.observe<CountRow>(
        DashboardQueries.lowStock, CountRow.fromJson,
        arguments: storeArgs,
        onChange: (rows) => setState(() => _lowStockCount = rows.firstOrNull?.count ?? 0),
      ));
      _observers.add(manager.observe<InventoryItem>(
        DashboardQueries.lowStockItems, InventoryItem.fromJson,
        arguments: storeArgs,
        onChange: (rows) => setState(() => _lowStockItems = rows),
      ));
      // Shared-catalog observers (no store arg).
      _observers.add(manager.observe<CountRow>(
        DashboardQueries.customersCount, CountRow.fromJson,
        onChange: (rows) => setState(() => _customersCount = rows.firstOrNull?.count ?? 0),
      ));
      _observers.add(manager.observe<CountRow>(
        DashboardQueries.productsCount, CountRow.fromJson,
        onChange: (rows) => setState(() => _productsCount = rows.firstOrNull?.count ?? 0),
      ));
      _observers.add(manager.observe<Product>(
        DashboardQueries.productsCatalog, Product.fromJson,
        onChange: (products) => setState(() => _productNames = {for (final p in products) p.product_id: p.product_name}),
      ));
      _observers.add(manager.observe<TopProductRow>(
        DashboardQueries.topProducts(_topProductsLimit), TopProductRow.fromJson,
        arguments: storeArgs,
        onChange: (rows) => setState(() => _topProducts = rows.where((r) => r.product_id != null).toList()),
      ));
      _loadedFor = storeId;
      _error = null;
    } catch (e) {
      // Registration is synchronous — a throw leaves _observers fully
      // tracked, so nothing leaks.
      setState(() => _error = e.toString());
    }
  }

  /// The Top-N pull-down re-registers just the top-products observer (last in
  /// the list — swap it out atomically; registration is synchronous).
  void _setTopProductsLimit(int limit, String? storeId) {
    setState(() => _topProductsLimit = limit);
    if (storeId == null || _observers.isEmpty) return;
    _observers.last.cancel();
    _observers.removeLast();
    _observers.add(DittoManager.instance.observe<TopProductRow>(
      DashboardQueries.topProducts(limit), TopProductRow.fromJson,
      arguments: {'storeId': storeId},
      onChange: (rows) => setState(() => _topProducts = rows.where((r) => r.product_id != null).toList()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final stores = ref.watch(appStoresProvider);
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider);
    final appState = ref.read(appStateProvider.notifier);
    final store = stores.where((s) => s.store_id == selectedStoreId).firstOrNull;

    // Store-switch handling (mirrors the other platforms' onChange): clear,
    // then re-register for the new store.
    ref.listen(appSelectedStoreIdProvider, (previous, next) {
      _clearForStoreChange();
      _start(next);
    });
    if (_loadedFor == null && selectedStoreId != null && _observers.isEmpty) {
      _start(selectedStoreId);
    }

    final stale = _isStale(selectedStoreId);
    final totalOrders = _statusRows.fold(0, (sum, r) => sum + r.orders);
    final totalRevenue = _statusRows.fold(0.0, (sum, r) => sum + (r.revenue ?? 0));

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Dashboard'),
        actions: [
          QueryInfoButton(
            query: DashboardQueries.statusRevenue.replaceAll(':storeId', "'${selectedStoreId ?? "store_seattle"}'"),
            explanation: _Explanations.screen,
            tooltip: 'About this screen',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(context, store, stores, selectedStoreId, appState),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: DittoBadge(_error!, status: BadgeStatus.critical)),
          const SizedBox(height: 16),
          _kpiGrid(context, stale, totalOrders, totalRevenue),
          const SizedBox(height: 16),
          _trendCard(context, stale),
          const SizedBox(height: 16),
          _lowStockCard(context, stale),
          const SizedBox(height: 16),
          _topProductsCard(context, stale, selectedStoreId),
        ],
      ),
    );
  }

  /// One line: store name (tap to switch stores in place — no trip to the
  /// Ditto tab) · location … and the full Ditto logotype trailing (the same
  /// line, per the design review).
  Widget _header(BuildContext context, Store? store, List<Store> stores, String? selectedStoreId, AppState appState) {
    final colors = context.dittoColors;
    final wide = MediaQuery.sizeOf(context).width > 400;
    return Row(
      children: [
        PopupMenuButton<String>(
          key: const Key('storeSwitcher'),
          onSelected: appState.selectStore,
          itemBuilder: (context) => [
            for (final option in stores)
              PopupMenuItem(
                value: option.store_id,
                child: Row(
                  children: [
                    Text(option.store_name),
                    if (option.store_id == selectedStoreId) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.check, size: 18),
                    ],
                  ],
                ),
              ),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                store?.store_name ?? selectedStoreId ?? '—',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foregroundNormal),
              ),
              Icon(Icons.arrow_drop_down, color: colors.foregroundSubtle),
            ],
          ),
        ),
        if (store != null && wide)
          Flexible(
            child: Text(
              '· ${_locationOneLiner(store)}',
              style: TextStyle(fontSize: 14, color: colors.foregroundSubtle),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const Spacer(),
        // The full Ditto logotype (dark/white variants follow the theme).
        SvgPicture.asset(
          Theme.of(context).brightness == Brightness.dark
              ? 'assets/ditto_full-logotype_white.svg'
              : 'assets/ditto_full-logotype_dark.svg',
          height: 22,
          semanticsLabel: 'Ditto',
        ),
      ],
    );
  }

  String _locationOneLiner(Store store) {
    // The online store's address is the placeholder "n/a".
    final cityState = '${store.location.city}, ${store.location.state}';
    return store.location.address == 'n/a' ? cityState : '${store.location.address}, $cityState';
  }

  /// Centered, width-capped KPI grid: 4-up on wide layouts, 2×2 below 900,
  /// ONE card per row below 500 (narrow screens stack — the revenue value
  /// must never clip). Ghost cards while the snapshot belongs to another store.
  Widget _kpiGrid(BuildContext context, bool stale, int totalOrders, double totalRevenue) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = constraints.maxWidth < 500
            ? 1
            : constraints.maxWidth < 900
                ? 2
                : 4;
        final cards = stale
            ? List<Widget>.generate(4, (_) => const SkeletonCard())
            : [
                _KpiCard('Orders', formatInt(totalOrders), DashboardQueries.statusRevenue, _Explanations.statusRevenue, key: const Key('kpi.orders')),
                _KpiCard('Revenue (all time)', Formatters.usd(totalRevenue), DashboardQueries.statusRevenue, _Explanations.statusRevenue, key: const Key('kpi.revenue')),
                _KpiCard('Customers synced', _customersCount != null ? formatInt(_customersCount!) : '…', DashboardQueries.customersCount, _Explanations.customersCount, key: const Key('kpi.customers')),
                _KpiCard('Catalog products', _productsCount != null ? formatInt(_productsCount!) : '…', DashboardQueries.productsCount, _Explanations.productsCount, key: const Key('kpi.products')),
              ];
        final rows = <Widget>[];
        for (var i = 0; i < cards.length; i += columnCount) {
          final rowCards = cards.sublist(i, i + columnCount);
          rows.add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final card in rowCards) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: card))],
          ));
          rows.add(const SizedBox(height: 16));
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Column(children: rows),
          ),
        );
      },
    );
  }

  Widget _trendCard(BuildContext context, bool stale) {
    final colors = context.dittoColors;
    final mono = TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundNormal);
    return DittoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader('Monthly trend', query: DashboardQueries.monthlyTrend, explanation: _Explanations.monthlyTrend),
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(width: 64, child: Text('Month', style: mono.copyWith(color: colors.foregroundSubtle))),
            const Spacer(),
            SizedBox(width: 70, child: Text('Orders', style: mono.copyWith(color: colors.foregroundSubtle), textAlign: TextAlign.right)),
            SizedBox(width: 110, child: Text('Revenue', style: mono.copyWith(color: colors.foregroundSubtle), textAlign: TextAlign.right)),
          ]),
          if (stale)
            const SkeletonRows(count: 5)
          else ...[
            for (final row in _monthRows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  SizedBox(width: 64, child: Text(row.month ?? '—', style: mono)),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: row.orders / (_monthRows.fold(1, (m, r) => r.orders > m ? r.orders : m)).clamp(1, 1 << 31),
                        child: Container(height: 14, decoration: BoxDecoration(color: colors.fillBrandPrimary, borderRadius: BorderRadius.circular(3))),
                      ),
                    ),
                  ),
                  SizedBox(width: 70, child: Text(formatInt(row.orders), style: mono, textAlign: TextAlign.right)),
                  SizedBox(width: 110, child: Text(Formatters.usd(row.revenue ?? 0), style: mono.copyWith(color: colors.foregroundSubtle), textAlign: TextAlign.right)),
                ]),
              ),
            if (_monthRows.isEmpty)
              Text('No orders synced yet for this store.', style: TextStyle(color: colors.foregroundSubtle)),
          ],
        ],
      ),
    );
  }

  Widget _lowStockCard(BuildContext context, bool stale) {
    final colors = context.dittoColors;
    return DittoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Low stock',
            query: DashboardQueries.lowStock,
            explanation: _Explanations.lowStock,
            trailing: (!stale && _lowStockCount != null)
                ? DittoBadge(
                    _lowStockCount == 0 ? 'No low stock found' : '$_lowStockCount SKU${_lowStockCount == 1 ? '' : 's'} under 5 units',
                    status: _lowStockCount! > 0 ? BadgeStatus.warning : BadgeStatus.success,
                    key: const Key('lowStock.badge'),
                  )
                : null,
          ),
          const SizedBox(height: 10),
          if (stale)
            const SkeletonRows(count: 4)
          else if (_lowStockCount != null) ...[
            if (_lowStockCount == 0)
              Text('Everything at this store has 5+ units on hand.', style: TextStyle(color: colors.foregroundSubtle))
            else ...[
              for (final item in _lowStockItems)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Expanded(child: Text(_productName(item.product_id), style: TextStyle(color: colors.foregroundNormal), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text('Aisle ${item.location.aisle}', style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundSubtle)),
                    const SizedBox(width: 8),
                    DittoBadge(
                      item.stock_level == 0 ? 'out' : '${item.stock_level} left',
                      status: item.stock_level == 0 ? BadgeStatus.critical : BadgeStatus.warning,
                    ),
                  ]),
                ),
              if (_lowStockCount! > _lowStockItems.length)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '+ ${_lowStockCount! - _lowStockItems.length} more — full list in Products → ⚠ Low stock',
                    style: TextStyle(fontSize: 12, color: colors.foregroundSubtle),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _topProductsCard(BuildContext context, bool stale, String? selectedStoreId) {
    final colors = context.dittoColors;
    return DittoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            'Top products by revenue',
            query: DashboardQueries.topProducts(_topProductsLimit),
            explanation: _Explanations.topProducts,
            trailing: MenuAnchor(
              key: const Key('topProducts.limit'),
              menuChildren: [
                for (final limit in const [5, 10, 25, 50, 100])
                  MenuItemButton(child: Text('$limit'), onPressed: () => _setTopProductsLimit(limit, selectedStoreId)),
              ],
              builder: (context, controller, child) => TextButton(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                child: Text('Top $_topProductsLimit', style: TextStyle(color: colors.foregroundSubtle)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (stale)
            const SkeletonRows(count: 5)
          else ...[
            for (var i = 0; i < _topProducts.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  SizedBox(width: 28, child: Text('${i + 1}.', style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundSubtle), textAlign: TextAlign.right)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_productName(_topProducts[i].product_id ?? ''), style: TextStyle(color: colors.foregroundNormal), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text(Formatters.usd(_topProducts[i].revenue ?? 0), style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundSubtle)),
                ]),
              ),
            if (_topProducts.isEmpty) Text('No sales yet for this store.', style: TextStyle(color: colors.foregroundSubtle)),
          ],
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard(this.title, this.value, this.query, this.explanation, {super.key});
  final String title;
  final String value;
  final String query;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return DittoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(title, style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
            const Spacer(),
            QueryInfoButton(query: query, explanation: explanation),
          ]),
          // KPI values must never wrap — shrink to fit instead.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: colors.foregroundNormal),
            ),
          ),
        ],
      ),
    );
  }
}
