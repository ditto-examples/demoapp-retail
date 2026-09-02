import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ditto_live/ditto_live.dart' show Authenticator, Ditto, QueryResult, StoreObserver, SyncSubscription;

import '../config/database_config.dart';
import '../models/benchmark_catalog.dart';
import '../models/models.dart';
import 'result_coalescer.dart';

/// The only Ditto access point in the app (1:1 port of the Swift reference's
/// `actor DittoManager`; a singleton, not a DI container — the repo's "no DI
/// frameworks, one thin access point" convention).
///
/// Contracts (mirrored from the other platforms):
/// - `open()` shares one in-flight future — Ditto.open never runs twice
///   concurrently against the same persistence dir.
/// - Store switches carry [selectionEpoch]; any step that suspends mid-switch
///   re-checks the epoch before mutating subscription state.
/// - Store ids must match ^[a-z0-9_\-]+$ before flowing into DQL or args.
/// - Errors surface to the AppState banner via the onError callback — never
///   to nowhere.
class DittoManager {
  DittoManager._();
  static final DittoManager instance = DittoManager._();

  Ditto? _ditto;
  String? _currentStoreId;
  String? get currentStoreId => _currentStoreId;

  final _sharedSubscriptions = <SyncSubscription>[];
  final _storeSubscriptions = <SyncSubscription>[];
  Completer<Ditto>? _openCompleter;

  /// Generation guard so open() only clears its OWN in-flight future.
  var _openGeneration = 0;
  var _selectionEpoch = 0;
  Timer? _reEvictTimer;

  /// ^[a-z0-9_\-]+$ — the dataset's store id shape.
  static bool isValidStoreId(String storeId) => QueryPreparation.isValidStoreId(storeId);

  // MARK: - Open / close

  /// Single in-flight open; on failure the state is torn down so a retry is
  /// clean. onError is invoked for async failures (auth refresh).
  Future<Ditto> open(DatabaseConfig config, {required void Function(String) onError}) {
    final existing = _ditto;
    if (existing != null) return Future.value(existing);
    final inFlight = _openCompleter;
    if (inFlight != null) return inFlight.future;

    final generation = ++_openGeneration;
    final completer = Completer<Ditto>();
    _openCompleter = completer;
    _openAndConfigure(config, onError).then((ditto) {
      if (_openGeneration == generation) _openCompleter = null;
      completer.complete(ditto);
    }, onError: (Object e) {
      if (_openGeneration == generation) _openCompleter = null;
      completer.completeError(e);
    });
    return completer.future;
  }

  var _initialized = false;

  Future<Ditto> _openAndConfigure(DatabaseConfig config, void Function(String) onError) async {
    // Ditto.init() must be awaited before ANY SDK touch — even the static
    // Ditto.defaultRootDirectory throws "Ditto not initialized" otherwise.
    if (!_initialized) {
      await Ditto.init();
      _initialized = true;
    }
    final persistenceDirectory = '${Ditto.defaultRootDirectory}/zava/ditto';
    final dittoConfig = config.makeDittoConfig(persistenceDirectory);
    // The single access point.
    final instance = await Ditto.open(dittoConfig);

    // Auth: development provider; capture the token BY VALUE (never the
    // manager) into the SDK-held handler. Login failures surface via onError.
    final token = config.developmentToken;
    await instance.auth.setExpirationHandler((ditto, _) {
      Future<void> reLogin() async {
        try {
          await ditto.auth.login(token: token, provider: Authenticator.developmentProvider);
        } catch (e) {
          onError('Ditto auth failed: $e');
        }
      }

      reLogin();
    });

    try {
      _registerSharedSubscriptions(instance);
      await _createSupportingIndexes(instance);
      instance.sync.start();
    } catch (_) {
      // Never pin a half-initialized instance.
      instance.sync.stop();
      for (final sub in _sharedSubscriptions) {
        sub.cancel();
      }
      _sharedSubscriptions.clear();
      _ditto = null;
      rethrow;
    }
    _ditto = instance;
    return instance;
  }

  // MARK: - Subscriptions & indexes (DQL strings stay visible at the call site)

  void _registerSharedSubscriptions(Ditto instance) {
    if (_sharedSubscriptions.isNotEmpty) return;
    // Register one at a time INTO the tracked list: if a registration throws,
    // the already-registered ones are tracked (and cancelled by the caller's
    // teardown) rather than leaked as anonymous live subs.
    _sharedSubscriptions.addAll([
      // shared catalog (registered once)
      instance.sync.registerSubscription('SELECT * FROM stores'),
      instance.sync.registerSubscription('SELECT * FROM categories'),
      instance.sync.registerSubscription('SELECT * FROM products'),
      // subscription__customers_all — the whole directory (a walk-in could be anyone)
      instance.sync.registerSubscription('SELECT * FROM customers WHERE deleted = false'),
    ]);
  }

  Future<void> _createSupportingIndexes(Ditto instance) async {
    // App-namespaced zava_* names so the Query Runner's benchmark
    // postQueries (DROP INDEX on benchmark-named indexes) can never drop
    // the app's own indexes (PLAN §4.1).
    for (final statement in [
      'CREATE INDEX IF NOT EXISTS zava_inventory_store ON inventory (_id.store_id)',
      'CREATE INDEX IF NOT EXISTS zava_orders_store ON orders (store_id, deleted)',
      'CREATE INDEX IF NOT EXISTS zava_order_items_store ON order_items (store_id, deleted)',
    ]) {
      await instance.store.execute(statement);
    }
  }

  // MARK: - Store switch (epoch-guarded)

  /// Superseded switches simply RETURN (the latest pick wins). Failure path:
  /// if an EVICT throws mid-switch, the old store's subs are already closed
  /// and its data partially evicted — the old store no longer exists as a
  /// coherent target, so _currentStoreId is cleared before rethrowing and the
  /// UI rolls back to the picker, not to a torn store.
  Future<void> applyStoreSelection(String storeId) async {
    if (!isValidStoreId(storeId)) throw AppError("Invalid store id '$storeId'");
    final instance = _ditto ?? (throw AppError('Ditto is not open yet'));
    if (storeId == _currentStoreId) return;

    final epoch = ++_selectionEpoch;
    developer.log('store selection → $storeId: re-registering per-store subscriptions', name: 'DittoManager');

    for (final sub in _storeSubscriptions) {
      sub.cancel();
    }
    _storeSubscriptions.clear();

    // Local-only removal of the old store's slice (EVICT vs DELETE is a
    // teaching moment). Docs in flight can still land afterwards — hence the
    // re-evict pass below.
    try {
      for (final collection in ['order_items', 'orders', 'inventory']) {
        await instance.store.execute(
          'EVICT FROM $collection WHERE store_id != :storeId',
          arguments: {'storeId': storeId},
        );
        if (_selectionEpoch != epoch) return; // superseded mid-evict
      }
    } catch (_) {
      _currentStoreId = null;
      rethrow;
    }
    if (_selectionEpoch != epoch) return;

    // The benchmark's subscription__* queries verbatim, parameterized.
    // Add as registered: a mid-sequence throw leaves the earlier subs
    // tracked (the next switch's cancel loop owns them), never leaked.
    _storeSubscriptions.add(
      instance.sync.registerSubscription(
        'SELECT * FROM inventory WHERE _id.store_id = :storeId AND deleted = false',
        arguments: {'storeId': storeId},
      ),
    );
    _storeSubscriptions.add(
      instance.sync.registerSubscription(
        'SELECT * FROM orders WHERE store_id = :storeId AND deleted = false',
        arguments: {'storeId': storeId},
      ),
    );
    _storeSubscriptions.add(
      instance.sync.registerSubscription(
        'SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false',
        arguments: {'storeId': storeId},
      ),
    );
    _currentStoreId = storeId;
    _scheduleReEvict(storeId, epoch);
  }

  /// Docs already in flight from the cancelled subscription can land after
  /// the first EVICT; re-evict once things settle (3 s), unless superseded.
  void _scheduleReEvict(String storeId, int epoch) {
    _reEvictTimer?.cancel();
    _reEvictTimer = Timer(const Duration(seconds: 3), () async {
      if (_selectionEpoch != epoch) return;
      developer.log('re-evict pass for $storeId', name: 'DittoManager');
      for (final collection in ['order_items', 'orders', 'inventory']) {
        // Re-check the epoch after every suspension, same discipline as the
        // primary switch path.
        final instance = _ditto;
        if (_selectionEpoch != epoch || instance == null) return;
        try {
          await instance.store.execute(
            'EVICT FROM $collection WHERE store_id != :storeId',
            arguments: {'storeId': storeId},
          );
        } catch (e) {
          developer.log('re-evict failed for $collection: $e', name: 'DittoManager', level: 1000);
        }
      }
    });
  }

  // MARK: - One-shot queries

  Ditto _requireInstance() => _ditto ?? (throw AppError('Ditto is not open yet'));

  /// Decodes each item from its document map; the Flutter SDK manages cursor
  /// lifetime by GC, so no dematerialize contract exists here.
  Future<List<T>> fetch<T>(
    String query,
    T Function(Map<String, dynamic>) fromJson, {
    Map<String, dynamic> arguments = const {},
  }) async {
    final result = await _requireInstance().store.execute(query, arguments: arguments);
    return result.items.map((item) => fromJson(item.value)).toList();
  }

  /// The timed unit for the Query Runner: execute + materialize row count,
  /// no row decoding (mirrors the benchmark harness).
  Future<int> executeReturningRowCount(String query, {Map<String, dynamic> arguments = const {}}) async {
    final result = await _requireInstance().store.execute(query, arguments: arguments);
    return result.items.length;
  }

  // MARK: - Live observers (100 ms latest-wins coalesced delivery)

  /// The observer's onChange callback fires on Ditto's delivery machinery;
  /// we decode there and deliver coalesced via [ResultCoalescer].
  StoreObserver observe<T>(
    String query,
    T Function(Map<String, dynamic>) fromJson, {
    Map<String, dynamic> arguments = const {},
    void Function(String)? onDecodeError,
    required void Function(List<T>) onChange,
  }) {
    final coalescer = ResultCoalescer<List<T>>(onChange: onChange);
    late final StoreObserver observer;
    observer = _requireInstance().store.registerObserver(
      query,
      arguments: arguments,
      onChange: (result) {
        try {
          coalescer.enqueue(result.items.map((item) => fromJson(item.value)).toList());
        } catch (e) {
          // Never silent: schema drift must not freeze a screen without a trace.
          if (onDecodeError != null) {
            onDecodeError('observer decode failed: $e');
          } else {
            developer.log('observer decode failed: $e', name: 'DittoManager', level: 1000);
          }
        }
      },
    );
    // The coalescer lives as long as the observer (cancel closes it).
    return _CoalescedStoreObserver(observer, coalescer);
  }

  /// For `system:*` virtual collections: one map per row; observers parse on
  /// the UI side into SyncStatusInfo/IndexInfo.
  StoreObserver observeRaw(
    String query, {
    required void Function(List<Map<String, dynamic>>) onChange,
  }) {
    final coalescer = ResultCoalescer<List<Map<String, dynamic>>>(onChange: onChange);
    final observer = _requireInstance().store.registerObserver(
      query,
      onChange: (result) {
        try {
          coalescer.enqueue(result.items.map((item) => item.value).toList());
        } catch (e) {
          developer.log('raw observer row failed: $e', name: 'DittoManager', level: 1000);
        }
      },
    );
    return _CoalescedStoreObserver(observer, coalescer);
  }

  // MARK: - Benchmark orchestration (Query Runner)

  Future<BenchmarkRunResult> runBenchmark(PreparedBenchmark prepared, int iterations) =>
      BenchmarkRunner.runOrchestrated(prepared, iterations, executeReturningRowCount);
}

/// Pairs the SDK observer with its coalescer so cancelling releases both.
class _CoalescedStoreObserver implements StoreObserver {
  _CoalescedStoreObserver(this._inner, this._coalescer);
  final StoreObserver _inner;
  final ResultCoalescer<dynamic> _coalescer;

  @override
  void cancel() {
    _coalescer.dispose();
    _inner.cancel();
  }

  @override
  bool get isCancelled => _inner.isCancelled;

  @override
  Stream<QueryResult> get changes => _inner.changes;

  @override
  Map<String, dynamic> get queryArguments => _inner.queryArguments;

  @override
  String get queryString => _inner.queryString;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Convenience for tests/debugging: compact sorted-keys JSON of a row.
String rowToSortedJson(Map<String, dynamic> row) {
  final sorted = Map.fromEntries(row.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  return jsonEncode(sorted);
}
