import 'dart:convert';
import 'dart:math';

import 'models.dart';

/// Bundled shared/benchmarks.json (symlinked into assets/) — the 72-query
/// retail benchmark catalog. Key = benchmark name (`collection__descriptor`).
class BenchmarkEntry {
  const BenchmarkEntry({
    required this.query,
    required this.category,
    this.preQueries,
    this.postQueries,
  });

  final String query;
  final String category;
  final List<String>? preQueries;
  final List<String>? postQueries;

  bool get isMutating => const {'INSERT', 'UPDATE', 'DELETE', 'EVICT'}.contains(category);

  factory BenchmarkEntry.fromJson(Map<String, dynamic> j) => BenchmarkEntry(
        query: j['query'] as String,
        category: j['category'] as String,
        preQueries: (j['preQueries'] as List<dynamic>?)?.cast<String>(),
        postQueries: (j['postQueries'] as List<dynamic>?)?.cast<String>(),
      );
}

class BenchmarkCatalog {
  BenchmarkCatalog(this.entries);

  /// Flat list sorted by benchmark name, ascending, lexicographic.
  final List<MapEntry<String, BenchmarkEntry>> entries;

  static BenchmarkCatalog parse(String text) {
    final decoded = (jsonDecode(text) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, BenchmarkEntry.fromJson(v as Map<String, dynamic>)));
    final entries = decoded.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return BenchmarkCatalog(entries);
  }

  /// Grouped by the name segment before the first `__`, groups sorted by
  /// collection, entries name-sorted within each group.
  List<CatalogGroup> get groups {
    final buckets = <String, List<MapEntry<String, BenchmarkEntry>>>{};
    for (final entry in entries) {
      final collection = entry.key.split('__').firstOrNull ?? 'other';
      buckets.putIfAbsent(collection.isEmpty ? 'other' : collection, () => []).add(entry);
    }
    return buckets.entries
        .map((e) => CatalogGroup(e.key, e.value..sort((a, b) => a.key.compareTo(b.key))))
        .toList()
      ..sort((a, b) => a.collection.compareTo(b.collection));
  }
}

class CatalogGroup {
  CatalogGroup(this.collection, this.entries);
  final String collection;
  final List<MapEntry<String, BenchmarkEntry>> entries;
}

/// A benchmark with every substitution baked in — the exact DQL that will run,
/// plus human-readable notes for the UI.
class PreparedBenchmark {
  const PreparedBenchmark({
    required this.name,
    required this.category,
    required this.isMutating,
    required this.preQueries,
    required this.query,
    required this.postQueries,
    required this.substitutions,
  });
  final String name;
  final String category;
  final bool isMutating;
  final List<String> preQueries;
  final String query;
  final List<String> postQueries;
  final List<String> substitutions;
}

class BenchmarkRunResult {
  const BenchmarkRunResult({required this.iterations, required this.stats, required this.resultCount});
  final int iterations; // successful timed iterations (may be < requested)
  final BenchmarkStats stats;
  final int resultCount; // row count of the last successful timed execution
}

/// Population statistics, matching the benchmark harness.
class BenchmarkStats {
  const BenchmarkStats({required this.meanMs, required this.medianMs, required this.p95Ms, required this.minMs, required this.maxMs});
  final double meanMs;
  final double medianMs;
  final double p95Ms;
  final double minMs;
  final double maxMs;

  static BenchmarkStats of(List<double> durationsMs) {
    if (durationsMs.isEmpty) {
      return const BenchmarkStats(meanMs: 0, medianMs: 0, p95Ms: 0, minMs: 0, maxMs: 0);
    }
    final sorted = List<double>.of(durationsMs)..sort();
    final n = sorted.length;
    final median = n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
    final p95 = sorted[min(n - 1, (n * 0.95).floor())];
    return BenchmarkStats(
      meanMs: sorted.reduce((a, b) => a + b) / n,
      medianMs: median,
      p95Ms: p95,
      minMs: sorted.first,
      maxMs: sorted.last,
    );
  }
}

/// The substitution engine that makes the benchmark catalog correct against a
/// live synced store (PLAN §4.2.6): store literal substitution, per-run ids
/// for mutating runs, EVICT cleanup rewritten to propagating DELETE.
class QueryPreparation {
  /// Same contract as DittoManager.isValidStoreId.
  static bool isValidStoreId(String storeId) => RegExp(r'^[a-z0-9_\-]+$').hasMatch(storeId);

  static PreparedBenchmark prepare(
    String name,
    BenchmarkEntry entry, {
    required String storeId,
    required String runId,
  }) {
    final notes = <String>[];
    late final String safeStoreId;
    if (isValidStoreId(storeId)) {
      safeStoreId = storeId;
    } else {
      notes.add("Selected store id '$storeId' doesn't match the dataset id pattern — substitution skipped.");
      safeStoreId = 'store_seattle';
    }

    String transform(String text) {
      var result = text;
      if (result.contains('store_seattle') && safeStoreId != 'store_seattle') {
        result = result.replaceAll('store_seattle', safeStoreId);
      }
      if (entry.isMutating) {
        result = result.replaceAll('bench-', 'bench-$runId-');
      }
      return result;
    }

    if (entry.isMutating) {
      notes.add('Synthetic bench ids got the per-run suffix $runId, so repeat runs can’t conflict — even if a previous run left residue on the mesh.');
    }

    final post = _buildPostQueries(entry, transform, notes);

    if (entry.query.contains('store_seattle') && safeStoreId != 'store_seattle') {
      notes.add('The benchmark literal store_seattle was substituted with your selected store ($storeId) — visible in the query text below.');
    }

    return PreparedBenchmark(
      name: name,
      category: entry.category,
      isMutating: entry.isMutating,
      preQueries: (entry.preQueries ?? const []).map(transform).toList(),
      query: transform(entry.query),
      postQueries: post,
      substitutions: notes,
    );
  }

  static List<String> _buildPostQueries(
    BenchmarkEntry entry,
    String Function(String) transform,
    List<String> notes,
  ) {
    var post = (entry.postQueries ?? const <String>[]).map(transform).toList();
    if (entry.isMutating) {
      final hadEvict = entry.postQueries?.any((q) => q.startsWith('EVICT ')) ?? false;
      // EVICT is local-only: on a synced device the synthetic doc would stay
      // on Big Peer and re-sync everywhere, breaking repeat runs. Swap the
      // leading keyword for a propagating DELETE.
      post = post.map((q) => q.startsWith('EVICT ') ? 'DELETE ${q.substring(6)}' : q).toList();
      if (hadEvict) {
        notes.add('Cleanup ran as DELETE instead of the benchmark’s EVICT — EVICT is local-only and the synthetic doc would otherwise stay on Big Peer and re-sync to every device.');
      }
      if (entry.category == 'EVICT') {
        final cleanup = evictCleanup(entry, transform);
        if (cleanup != null) {
          post = [...post, cleanup];
          notes.add('Added a propagating DELETE after the EVICT — otherwise the doc stays on the server and re-syncs.');
        } else {
          notes.add('WARNING: could not derive a cleanup DELETE for this EVICT — the synthetic doc may stay on Big Peer and re-sync to other devices.');
        }
      }
    }
    return post;
  }

  /// EVICT benchmarks carry no cleanup of their own; derive a propagating
  /// DELETE from the EVICT's `_id = …` predicate (scalar or composite).
  static String? evictCleanup(BenchmarkEntry entry, String Function(String) transform) {
    if (entry.category != 'EVICT') return null;
    final idMatch = RegExp(r"_id\s*=\s*(\{[^}]+\}|'[^']+')").firstMatch(entry.query);
    if (idMatch == null) return null;
    final collectionMatch = RegExp(r'EVICT\s+FROM\s+\w+', caseSensitive: false).firstMatch(entry.query);
    if (collectionMatch == null) return null;
    final collection = collectionMatch.group(0)!.replaceAll(RegExp(r'EVICT\s+FROM\s+', caseSensitive: false), '').trim();
    if (collection.isEmpty) return null;
    final predicate = transform(idMatch.group(0)!);
    return 'DELETE FROM $collection WHERE $predicate';
  }
}

/// SDK-decoupled benchmark orchestration (unit tests drive it with a fake
/// executor): preQueries run once → timed iterations (break on first error) →
/// postQueries ALWAYS run. Iteration error outranks cleanup error.
class BenchmarkRunner {
  static Future<BenchmarkRunResult> runOrchestrated(
    PreparedBenchmark prepared,
    int iterations,
    Future<int> Function(String) execute,
  ) async {
    for (final query in prepared.preQueries) {
      await execute(query);
    }
    final durationsMs = <double>[];
    var rowCount = 0;
    Object? iterationError;
    for (var i = 0; i < iterations; i++) {
      final start = DateTime.now();
      try {
        rowCount = await execute(prepared.query);
      } catch (e) {
        iterationError = e;
        break;
      }
      durationsMs.add(DateTime.now().difference(start).inMicroseconds / 1000.0);
    }
    // Cleanup runs even when the CALLING task was abandoned mid-run (the user
    // navigated away from a mutating benchmark): [runZonedGuarded]-style
    // detachment isn't needed in Dart — async functions don't auto-cancel on
    // widget disposal the way coroutines do; the zone continues. (The Flutter
    // port of this contract is deliberately identical in observable behavior.)
    Object? cleanupError;
    for (final query in prepared.postQueries) {
      try {
        await execute(query);
      } catch (e) {
        cleanupError = e;
      }
    }
    if (iterationError != null) throw iterationError;
    if (cleanupError != null) throw cleanupError;
    return BenchmarkRunResult(
      iterations: durationsMs.length,
      stats: BenchmarkStats.of(durationsMs),
      resultCount: rowCount,
    );
  }
}
