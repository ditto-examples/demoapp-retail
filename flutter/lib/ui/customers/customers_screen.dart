import 'dart:async';

import 'package:anvil/anvil.dart';
import 'package:ditto_live/ditto_live.dart' show StoreObserver;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ditto_manager.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../components.dart';

/// The full 25K-row customer directory, synced unfiltered
/// (a walk-in could be anyone), PAGED with
/// LIMIT/OFFSET so the demo handles the full directory gracefully. "This store
/// only" filters inside the query (customers__select__by_primary_store_id_*),
/// not in memory. The search field runs one-shot point queries (debounced).
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  static const directoryWhere = 'FROM customers WHERE deleted = false';
  static const storeWhere = 'FROM customers WHERE primary_store_id = :storeId AND deleted = false';

  /// The store filter lives IN the query (the benchmark's
  /// customers__select__by_primary_store_id shape), not in memory.
  static String whereClause(bool thisStoreOnly, String? storeId) =>
      thisStoreOnly && storeId != null ? storeWhere : directoryWhere;

  /// customers__select__by_email_* — the benchmark's indexed/no-index pair
  /// is runnable side-by-side in the Query Runner tab.
  static const emailQuery = 'SELECT * FROM customers WHERE email = :email AND deleted = false';
  static const nameQuery = '''
SELECT * FROM customers WHERE deleted = false
AND (first_name ILIKE :like OR last_name ILIKE :like) ORDER BY last_name LIMIT 50''';

  static const screenExplanation =
      'The 25K-row customer directory is subscribed UNFILTERED (a walk-in could be anyone), so this screen pages entirely on-device: LIMIT/OFFSET for the slice (ORDER BY last_name, first_name, _id) plus a live COUNT(*) observer for the total — the query above is the exact paged query running now.\n\n"This store only" filters IN the query (primary_store_id = your store), not in memory. Search: an \'@\' runs an exact-email lookup (run the customers__select__by_id / indexed pairs side by side in the Query Runner); otherwise a name-prefix ILIKE on first/last name, first 50 matches.';

  var _customers = <Customer>[];
  var _totalCount = 0;
  var _page = 1;
  var _pageSize = 25;
  var _thisStoreOnly = false;
  List<Customer>? _searchResults;
  String? _error;
  var _activeQuery = '';
  final _searchController = TextEditingController();

  bool get _isSearching => _searchResults != null;
  List<Customer> get _visibleCustomers => _searchResults ?? _customers;

  StoreObserver? _pageObserver;
  StoreObserver? _countObserver;
  String? _lastStoreId;
  Timer? _searchDebounce;

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

  void _restart(String? storeId) {
    _stop();
    // Never render the previous store's rows.
    if (_lastStoreId != storeId) {
      setState(() {
        _customers = [];
        _totalCount = 0;
        _page = 1;
      });
    }
    _lastStoreId = storeId;

    final where = whereClause(_thisStoreOnly, storeId);
    final arguments = <String, dynamic>{if (_thisStoreOnly && storeId != null) 'storeId': storeId};

    try {
      _countObserver = DittoManager.instance.observe<CountRow>(
        'SELECT COUNT(*) AS count $where',
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
      final pageQuery = Paging.pageQuery('SELECT * $where', 'last_name, first_name, _id', _page, _pageSize);
      setState(() => _activeQuery = _thisStoreOnly && storeId != null ? pageQuery.replaceAll(':storeId', "'$storeId'") : pageQuery);
      _pageObserver = DittoManager.instance.observe<Customer>(
        pageQuery,
        Customer.fromJson,
        arguments: arguments,
        onChange: (customers) => setState(() => _customers = customers),
      );
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _search() {
    _searchDebounce?.cancel();
    final term = _searchController.text.trim();
    if (term.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final results = term.contains('@')
            // exact-email lookup — the benchmark's indexed pair member
            ? await DittoManager.instance.fetch<Customer>(emailQuery, Customer.fromJson, arguments: {'email': term})
            : await DittoManager.instance.fetch<Customer>(nameQuery, Customer.fromJson, arguments: {'like': '$term%'});
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

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider);

    ref.listen(appSelectedStoreIdProvider, (previous, next) => _restart(next));
    if (_lastStoreId == null && selectedStoreId != null && _pageObserver == null) {
      _restart(selectedStoreId);
    }

    final infoQuery = _activeQuery.isEmpty ? 'SELECT * $directoryWhere ORDER BY last_name, first_name, _id' : _activeQuery;

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Customers'),
        actions: [QueryInfoButton(query: infoQuery, explanation: screenExplanation, tooltip: 'About this screen')],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ZavaSearchField(
              controller: _searchController,
              placeholder: 'Search name, or exact email…',
              onChanged: (_) => _search(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Row(children: [
              Text('This store only', style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
              const SizedBox(width: 16), // M3 list-item spacing: label → control
              Switch(
                value: _thisStoreOnly,
                onChanged: (value) {
                  setState(() {
                    _thisStoreOnly = value;
                    _page = 1;
                  });
                  _restart(selectedStoreId);
                },
              ),
              const Spacer(),
              if (!_isSearching)
                Text(
                  '${formatInt(_totalCount)} customers',
                  style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundSubtle),
                ),
            ]),
          ),
          Divider(height: 1, color: colors.borderNormal),
          Expanded(
            child: _visibleCustomers.isEmpty
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
                    itemCount: _visibleCustomers.length,
                    separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
                    itemBuilder: (context, index) {
                      final customer = _visibleCustomers[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(customer.displayName, style: TextStyle(color: colors.foregroundNormal)),
                          Text(customer.email, style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
                        ]),
                      );
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
