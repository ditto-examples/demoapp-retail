import 'dart:async';
import 'dart:developer' as developer;

import 'package:anvil/anvil.dart';
import 'package:ditto_live/ditto_live.dart' show StoreObserver;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ditto_manager.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../components.dart';
import '../formatters.dart';

/// The orders list is a live, PAGED store observer (PLAN §4.2.2): the page
/// slice is `ORDER BY order_date DESC LIMIT pageSize OFFSET (page-1)*pageSize`
/// and the total comes from a COUNT observer — both live-update as sync runs.
/// The "recent" filter anchors to max(order_date) in the local store — the
/// dataset ends 2025-06-27, so a device-clock-relative filter would show
/// zero rows.
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  static const searchQuery = '''
SELECT * FROM orders WHERE store_id = :storeId AND deleted = false
AND (order_id ILIKE :like OR customer_name ILIKE :like)
ORDER BY order_date DESC, _id DESC LIMIT 50''';

  static const baseWhere = 'FROM orders WHERE store_id = :storeId AND deleted = false';

  static const screenExplanation =
      "The orders list is a LIVE observer over this store's synced orders — new matches appear as sync delivers them, no refresh step. The query shown above is the exact one running (cutoff/args resolved).\n\nPagination is LIMIT/OFFSET in DQL: the visible slice runs ORDER BY order_date DESC, _id DESC LIMIT <pageSize> OFFSET <(page−1)×pageSize>, while a second live observer runs COUNT(*) over the same WHERE — so the page count climbs as sync delivers. The _id tiebreaker keeps OFFSET paging stable (no skipped or repeated rows across pages).\n\n\"Recent only\" anchors to max(order_date) IN THE DATA (the benchmark dataset ends 2025-06-27), not the device clock — a naive now-minus-30-days filter would show zero rows. Search runs one-shot case-insensitive ILIKE queries on order number and customer name (500 ms debounce, capped at 50 rows) — '%' and '_' in your input act as wildcards, and search matches across all dates (it ignores the \"Recent only\" filter); clear it (×) to return to the live, paginated list.";

  var _orders = <Order>[];
  var _totalCount = 0;
  var _page = 1;
  var _pageSize = 25;
  var _recentOnly = false;
  var _activeQuery = '';
  String? _error;
  List<Order>? _searchResults;
  final _searchController = TextEditingController();

  bool get _isSearching => _searchResults != null;
  List<Order> get _visibleOrders => _searchResults ?? _orders;

  StoreObserver? _pageObserver;
  StoreObserver? _countObserver;
  String? _lastStoreId;
  Timer? _searchDebounce;

  /// Search input cleanup: trim whitespace and drop leading '#' characters —
  /// the list renders order numbers as "#20250115_0001" but the stored id is
  /// "order_20250115_0001". '%' and '_' pass through as ILIKE wildcards.
  static String sanitizedSearchTerm(String raw) {
    final trimmed = raw.trim();
    return trimmed.replaceFirst(RegExp('^#+'), '');
  }

  @override
  void dispose() {
    _stop();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _stop() {
    _pageObserver?.cancel();
    _countObserver?.cancel();
    _pageObserver = null;
    _countObserver = null;
  }

  Future<void> _restart(String? storeId) async {
    _stop();
    if (storeId == null) return;
    // Never render the previous store's rows: clear before re-registering.
    if (_lastStoreId != storeId) {
      setState(() {
        _orders = [];
        _totalCount = 0;
        _page = 1;
      });
    }
    _lastStoreId = storeId;

    var whereClause = baseWhere;
    final arguments = <String, dynamic>{'storeId': storeId};
    if (_recentOnly) {
      final maxDate = await _latestOrderDate(storeId);
      final cutoff = maxDate != null ? cutoffDate(maxDate, 30) : null;
      if (cutoff != null) {
        whereClause += ' AND order_date > :cutoff';
        arguments['cutoff'] = cutoff;
      }
    }
    if (!mounted || _lastStoreId != storeId) return;

    // Unique tiebreaker: OFFSET paging over a non-unique key can skip or
    // repeat rows across pages.
    final pageQuery = Paging.pageQuery(
      'SELECT * $whereClause',
      'order_date DESC, _id DESC',
      _page,
      _pageSize,
    );
    var displayQuery = pageQuery;
    arguments.forEach((key, value) => displayQuery = displayQuery.replaceAll(':$key', "'$value'"));

    try {
      _countObserver = DittoManager.instance.observe<CountRow>(
        'SELECT COUNT(*) AS count $whereClause',
        CountRow.fromJson,
        arguments: arguments,
        onChange: (rows) {
          setState(() => _totalCount = rows.firstOrNull?.count ?? 0);
          final clamped = Paging.clampPage(_page, _totalCount, _pageSize);
          if (clamped != _page) {
            _page = clamped;
            _restart(storeId);
          }
        },
      );
      _pageObserver = DittoManager.instance.observe<Order>(
        pageQuery,
        Order.fromJson,
        arguments: arguments,
        onChange: (orders) => setState(() => _orders = orders),
      );
      setState(() {
        _activeQuery = displayQuery;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<String?> _latestOrderDate(String storeId) async {
    try {
      final rows = await DittoManager.instance.fetch<Map<String, dynamic>>(
        'SELECT MAX(order_date) AS max_date FROM orders WHERE store_id = :storeId AND deleted = false',
        (m) => m,
        arguments: {'storeId': storeId},
      );
      return rows.firstOrNull?['max_date'] as String?;
    } catch (e) {
      developer.log('latestOrderDate failed — "recent" shows the full list: $e', name: 'Orders');
      return null;
    }
  }

  /// ISO8601 strings sort lexicographically; the cutoff keeps that property.
  static String? cutoffDate(String iso, int days) {
    final date = DateTime.tryParse(iso);
    if (date == null) return null;
    return date.subtract(Duration(days: days)).toUtc().toIso8601String();
  }

  void _search(String? storeId) {
    _searchDebounce?.cancel();
    final term = sanitizedSearchTerm(_searchController.text);
    if (term.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      // Read the store AFTER the debounce: a store switch during the sleep
      // must not fetch the old store's rows into the new context.
      final currentStoreId = ref.read(appSelectedStoreIdProvider);
      if (currentStoreId == null) return;
      try {
        final results = await DittoManager.instance.fetch<Order>(
          searchQuery,
          Order.fromJson,
          arguments: {'storeId': currentStoreId, 'like': '%$term%'},
        );
        if (mounted) {
          setState(() {
            _searchResults = results;
            _error = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
    });
  }

  /// Store switch while a search may be active: drop the old store's matches
  /// immediately (never render another store's data), restart the paged
  /// observers, and re-run the search against the new store.
  void _handleStoreSwitch(String? storeId) {
    _searchResults = null;
    _restart(storeId);
    if (_searchController.text.isNotEmpty) _search(storeId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider);

    ref.listen(appSelectedStoreIdProvider, (previous, next) => _handleStoreSwitch(next));
    if (_lastStoreId == null && selectedStoreId != null && _pageObserver == null) {
      _restart(selectedStoreId);
    }

    final displayedQuery = _isSearching && selectedStoreId != null
        ? searchQuery
            .replaceAll(':storeId', "'$selectedStoreId'")
            .replaceAll(':like', "'%${sanitizedSearchTerm(_searchController.text)}%'")
        : _activeQuery.isEmpty
            ? 'SELECT * $baseWhere ORDER BY order_date DESC'
            : _activeQuery;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Orders'),
        actions: [QueryInfoButton(query: displayedQuery, explanation: screenExplanation, tooltip: 'About this screen')],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ZavaSearchField(
              controller: _searchController,
              placeholder: 'Search order # or customer…',
              onChanged: (_) => _search(selectedStoreId),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Row(
              children: [
                Text('Recent only (last 30 days of data)', style: TextStyle(fontSize: 14, color: colors.foregroundNormal)),
                const SizedBox(width: 16), // M3 list-item spacing: label → control
                Switch(
                  value: _recentOnly,
                  onChanged: (value) {
                    setState(() {
                      _recentOnly = value;
                      _page = 1;
                    });
                    _restart(selectedStoreId);
                  },
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.borderNormal),
          Expanded(
            child: _visibleOrders.isEmpty
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
                    itemCount: _visibleOrders.length,
                    separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
                    itemBuilder: (context, index) => _OrderRow(
                      _visibleOrders[index],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => OrderDetailScreen(order: _visibleOrders[index])),
                      ),
                    ),
                  ),
          ),
          Divider(height: 1, color: colors.borderNormal),
          if (_isSearching)
            // Same height as the pagination bar so the list doesn't jump;
            // discloses the LIMIT 50 cap.
            Container(
              color: colors.surface,
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.centerLeft,
              child: Text(
                _visibleOrders.length >= 50
                    ? 'First 50 matches shown (cap) — refine the term, or clear search for the paged list'
                    : '${_visibleOrders.length} ${_visibleOrders.length == 1 ? 'match' : 'matches'} — clear search for the paged list',
                style: TextStyle(fontSize: 12, color: colors.foregroundSubtle),
              ),
            )
          else
            PaginationBar(
              totalCount: _totalCount,
              page: _page,
              pageSize: _pageSize,
              pageSizes: const [25, 50, 100, 250],
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
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow(this.order, {required this.onTap});
  final Order order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.order_id.replaceFirst('order_', '#'),
                  style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 13, color: colors.foregroundNormal),
                ),
                Text(
                  '${order.customer_name} · ${Formatters.dateTime(order.order_date)}',
                  style: TextStyle(fontSize: 14, color: colors.foregroundSubtle),
                ),
              ],
            ),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Formatters.usd(order.total),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal),
                ),
                Text(
                  '${order.item_count} item${order.item_count == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 12, color: colors.foregroundSubtle),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Order detail = order + its items via the canonical two-query pattern.
/// DQL v5.0 has no JOINs: the first query fetched the order (the list's
/// observer), this view runs the second (items by order_id).
class OrderDetailScreen extends ConsumerStatefulWidget {
  const OrderDetailScreen({super.key, required this.order});
  final Order order;

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  static const itemsQuery = 'SELECT * FROM order_items WHERE order_id = :orderId AND deleted = false';
  static const explanation = "DQL v5.0 has no JOINs, so order detail is two queries: the list's live observer fetched this order, and this screen ran the second query — order_items filtered by order_id. That's the canonical DQL pattern the benchmark measures as the orders__select__by_id + order_items__select__by_order pair.";

  var _items = <OrderItem>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await DittoManager.instance.fetch<OrderItem>(
        itemsQuery,
        OrderItem.fromJson,
        arguments: {'orderId': widget.order.order_id},
      );
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final order = widget.order;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Order'),
        actions: [QueryInfoButton(query: itemsQuery, explanation: explanation, tooltip: 'About this screen')],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DittoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(order.order_id, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 14, color: colors.foregroundNormal)),
                Text(order.customer_name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                Text('${Formatters.dateTime(order.order_date)} · ${order.store_name}', style: TextStyle(color: colors.foregroundSubtle)),
                Row(children: [
                  DittoBadge(order.status, status: BadgeStatus.success),
                  const Spacer(),
                  Text(Formatters.usd(order.total), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 16),
          DittoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Line items', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                const SizedBox(height: 10),
                for (final item in _items)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item.product_name, style: TextStyle(color: colors.foregroundNormal)),
                          Text(item.sku, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundSubtle)),
                        ]),
                      ),
                      Text('×${item.quantity}', style: TextStyle(color: colors.foregroundSubtle)),
                      SizedBox(
                        width: 90,
                        child: Text(Formatters.usd(item.line_total), style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 13, color: colors.foregroundNormal), textAlign: TextAlign.right),
                      ),
                    ]),
                  ),
                if (_items.isEmpty && _error == null) const Padding(padding: EdgeInsets.only(top: 8), child: CircularProgressIndicator()),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: DittoBadge(_error!, status: BadgeStatus.critical)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
