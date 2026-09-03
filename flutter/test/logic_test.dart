import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zava_retail/models/benchmark_catalog.dart';
import 'package:zava_retail/models/models.dart';
import 'package:zava_retail/ui/formatters.dart';

/// Ports of the Swift/Kotlin pure-logic unit tests (paging, store-id
/// validation, runner transforms/stats/orchestration, catalog grouping,
/// formatters).
void main() {
  group('Paging', () {
    test('pageQuery interpolates limit/offset', () {
      expect(
        Paging.pageQuery('SELECT * FROM orders', 'order_date DESC, _id DESC', 3, 25),
        'SELECT * FROM orders ORDER BY order_date DESC, _id DESC LIMIT 25 OFFSET 50',
      );
    });

    test('clampPage keeps in range', () {
      expect(Paging.clampPage(3, 100, 25), 3);
      expect(Paging.clampPage(99, 100, 25), 4);
      expect(Paging.clampPage(-3, 100, 25), 1);
      expect(Paging.clampPage(5, 0, 25), 1);
    });
  });

  group('store id validation', () {
    test('accepts dataset ids, rejects injection', () {
      expect(QueryPreparation.isValidStoreId('store_seattle'), isTrue);
      expect(QueryPreparation.isValidStoreId('store-online_2'), isTrue);
      expect(QueryPreparation.isValidStoreId("store'; DROP TABLE stores; --"), isFalse);
      expect(QueryPreparation.isValidStoreId(''), isFalse);
    });
  });

  group('QueryPreparation', () {
    BenchmarkEntry entry(
      String query, {
      String category = 'SELECT',
      List<String>? preQueries,
      List<String>? postQueries,
    }) =>
        BenchmarkEntry(query: query, category: category, preQueries: preQueries, postQueries: postQueries);

    test('store substitution', () {
      final e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false");
      final prepared = QueryPreparation.prepare('orders__select__by_store', e, storeId: 'store_tacoma', runId: 'testrun1');
      expect(prepared.query, contains("store_id = 'store_tacoma'"));
      expect(prepared.query, isNot(contains('store_seattle')));
      expect(prepared.substitutions, isNotEmpty);
    });

    test('no substitution when Seattle selected', () {
      final e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false");
      final prepared = QueryPreparation.prepare('x', e, storeId: 'store_seattle', runId: 'testrun1');
      expect(prepared.query, contains('store_seattle'));
      expect(prepared.substitutions, isEmpty);
    });

    test('invalid store id skips substitution', () {
      final e = entry("SELECT * FROM orders WHERE store_id = 'store_seattle'");
      final prepared = QueryPreparation.prepare('x', e, storeId: "store'; --", runId: 'r1');
      expect(prepared.query, contains('store_seattle'));
      expect(prepared.substitutions.any((n) => n.contains("doesn't match")), isTrue);
    });

    test('mutating run gets fresh ids and DELETE cleanup', () {
      final e = entry(
        'INSERT INTO customers DOCUMENTS(deserialize_json(\'{"_id":"bench-cust-insert-uuid"}\')) ON ID CONFLICT DO UPDATE',
        category: 'INSERT',
        postQueries: ["EVICT FROM customers WHERE _id = 'bench-cust-insert-uuid'"],
      );
      final prepared = QueryPreparation.prepare('customers__insert__one', e, storeId: 'store_seattle', runId: 'run42');
      expect(prepared.isMutating, isTrue);
      expect(prepared.query, contains('bench-run42-cust-insert-uuid'));
      expect(prepared.postQueries, ["DELETE FROM customers WHERE _id = 'bench-run42-cust-insert-uuid'"]);
    });

    test('EVICT benchmark gets propagating cleanup appended', () {
      final e = entry(
        "EVICT FROM customers WHERE _id = 'bench-cust-evict-uuid'",
        category: 'EVICT',
        preQueries: ['INSERT INTO customers DOCUMENTS(deserialize_json(\'{"_id":"bench-cust-evict-uuid"}\'))'],
      );
      final prepared = QueryPreparation.prepare('customers__evict__by_id', e, storeId: 'store_seattle', runId: 'run7');
      expect(prepared.postQueries, ["DELETE FROM customers WHERE _id = 'bench-run7-cust-evict-uuid'"]);
      // preQueries get the same transform (dropping that map must fail loudly).
      expect(prepared.preQueries, ['INSERT INTO customers DOCUMENTS(deserialize_json(\'{"_id":"bench-run7-cust-evict-uuid"}\'))']);
    });

    test('EVICT cleanup handles composite _id', () {
      final e = entry(
        "EVICT FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-prod'}",
        category: 'EVICT',
      );
      final cleanup = QueryPreparation.evictCleanup(e, (t) => t.replaceAll('bench-', 'bench-r2-'));
      expect(cleanup, "DELETE FROM inventory WHERE _id = {'store_id': 'store_seattle', 'product_id': 'bench-r2-prod'}");
    });

    test('EVICT cleanup ignores non-EVICT', () {
      expect(QueryPreparation.evictCleanup(entry('SELECT * FROM stores'), (t) => t), isNull);
    });

    test('read-only benchmarks are untouched', () {
      final prepared = QueryPreparation.prepare('stores__select__all', entry('SELECT * FROM stores'), storeId: 'store_tacoma', runId: 'x');
      expect(prepared.query, 'SELECT * FROM stores');
      expect(prepared.preQueries, isEmpty);
      expect(prepared.postQueries, isEmpty);
      expect(prepared.substitutions, isEmpty);
    });
  });

  group('BenchmarkStats', () {
    test('stats', () {
      final stats = BenchmarkStats.of([1, 2, 3, 4, 5]);
      expect(stats.meanMs, closeTo(3.0, 0.0001));
      expect(stats.medianMs, closeTo(3.0, 0.0001));
      expect(stats.p95Ms, closeTo(5.0, 0.0001));
      expect(stats.minMs, closeTo(1.0, 0.0001));
      expect(stats.maxMs, closeTo(5.0, 0.0001));
    });

    test('empty', () {
      final stats = BenchmarkStats.of([]);
      expect(stats.meanMs, 0);
      expect(stats.p95Ms, 0);
    });
  });

  group('BenchmarkRunner orchestration', () {
    PreparedBenchmark prepared({
      List<String> pre = const [],
      String query = 'SELECT 1',
      List<String> post = const [],
      String category = 'SELECT',
    }) =>
        PreparedBenchmark(
          name: 'test',
          category: category,
          isMutating: const {'INSERT', 'UPDATE', 'DELETE', 'EVICT'}.contains(category),
          preQueries: pre,
          query: query,
          postQueries: post,
          substitutions: const [],
        );

    test('order', () async {
      final calls = <String>[];
      final result = await BenchmarkRunner.runOrchestrated(
        prepared(pre: ['CREATE INDEX a'], post: ['DROP INDEX a']),
        3,
        (query) async {
          calls.add(query);
          return 7;
        },
      );
      expect(calls, ['CREATE INDEX a', 'SELECT 1', 'SELECT 1', 'SELECT 1', 'DROP INDEX a']);
      expect(result.iterations, 3);
      expect(result.resultCount, 7);
    });

    test('cleanup runs on failure and never masks the iteration error', () async {
      final calls = <String>[];
      var timed = 0;
      Object? thrown;
      try {
        await BenchmarkRunner.runOrchestrated(
          prepared(pre: ['INSERT seed'], query: 'INSERT timed', post: ['DELETE cleanup'], category: 'INSERT'),
          5,
          (query) async {
            if (query == 'INSERT timed') {
              timed++;
              if (timed == 3) throw StateError('boom');
            }
            calls.add(query);
            return 1;
          },
        );
        fail('iteration error must be rethrown after cleanup');
      } catch (e) {
        thrown = e;
      }
      expect((thrown as StateError).message, 'boom');
      expect(calls, ['INSERT seed', 'INSERT timed', 'INSERT timed', 'DELETE cleanup']);
    });
  });

  group('Formatters', () {
    test('usd', () {
      expect(Formatters.usd(1234.5), '\$1,234.50');
      expect(Formatters.usd(0), '\$0.00');
      expect(Formatters.usd(19513528.40), '\$19,513,528.40');
    });

    test('dateTime surgery', () {
      expect(Formatters.dateTime('2025-06-27T18:20:00Z'), '2025-06-27 18:20');
      expect(Formatters.dateTime('short'), 'short');
    });
  });

  group('BenchmarkCatalog (real bundled file)', () {
    test('loads and groups the 72 entries', () {
      final file = File('../shared/benchmarks.json');
      expect(file.existsSync(), isTrue, reason: 'benchmarks.json must be reachable from the test working dir');
      final catalog = BenchmarkCatalog.parse(file.readAsStringSync());
      expect(catalog.entries.length, 72);
      final collections = catalog.groups.map((g) => g.collection).toList();
      expect(collections, containsAll(['orders', 'subscription', 'order_items']));
      expect(collections, orderedEquals(collections.toList()..sort()));
    });
  });
}
