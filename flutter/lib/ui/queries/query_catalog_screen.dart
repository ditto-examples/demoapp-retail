import 'package:anvil/anvil.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ditto_manager.dart';
import '../../models/benchmark_catalog.dart';
import '../../state/app_state.dart';
import '../components.dart';

BadgeStatus _categoryStatus(String category) => switch (category) {
      'SELECT' => BadgeStatus.info,
      'INDEX_SELECT' => BadgeStatus.promo,
      'AGGREGATION' => BadgeStatus.success,
      'INSERT' => BadgeStatus.warning,
      'UPDATE' || 'DELETE' || 'EVICT' => BadgeStatus.critical,
      _ => BadgeStatus.info,
    };

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge(this.category);
  final String category;
  @override
  Widget build(BuildContext context) => DittoBadge(category, status: _categoryStatus(category));
}

/// The Query Runner catalog: the bundled 72-benchmark DQL catalog, grouped by
/// collection with category badges.
class QueryCatalogScreen extends ConsumerStatefulWidget {
  const QueryCatalogScreen({super.key});

  @override
  ConsumerState<QueryCatalogScreen> createState() => _QueryCatalogScreenState();
}

class _QueryCatalogScreenState extends ConsumerState<QueryCatalogScreen> {
  BenchmarkCatalog? _catalog;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString('assets/benchmarks.json');
      setState(() => _catalog = BenchmarkCatalog.parse(text));
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(backgroundColor: colors.surface, title: const Text('Query Runner')),
      body: _catalog == null && _error == null
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading benchmark catalog…')]))
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Catalog unavailable', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                    Text(_error!, style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
                  ]),
                )
              : ListView.builder(
                  itemCount: _catalog!.groups.fold<int>(0, (sum, g) => sum + 1 + g.entries.length),
                  itemBuilder: (context, index) {
                    var offset = 0;
                    for (final group in _catalog!.groups) {
                      if (index == offset) {
                        return Container(
                          color: colors.background,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text('${group.collection} (${group.entries.length})', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.foregroundSubtle)),
                        );
                      }
                      offset++;
                      if (index < offset + group.entries.length) {
                        final entry = group.entries[index - offset];
                        return InkWell(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => BenchmarkDetailScreen(name: entry.key, entry: entry.value)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(entry.key, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundNormal)),
                              const SizedBox(height: 4),
                              _CategoryBadge(entry.value.category),
                            ]),
                          ),
                        );
                      }
                      offset += group.entries.length;
                    }
                    return const SizedBox.shrink();
                  },
                ),
    );
  }
}

/// Benchmark detail: the exact DQL (substituted for a synced device), the
/// substitutions notes, and the run toolbar with timing stats.
class BenchmarkDetailScreen extends ConsumerStatefulWidget {
  const BenchmarkDetailScreen({super.key, required this.name, required this.entry});
  final String name;
  final BenchmarkEntry entry;

  @override
  ConsumerState<BenchmarkDetailScreen> createState() => _BenchmarkDetailScreenState();
}

class _BenchmarkDetailScreenState extends ConsumerState<BenchmarkDetailScreen> {
  var _iterations = 10;
  var _isRunning = false;
  BenchmarkRunResult? _result;
  String? _error;
  var _runId = DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(8, '0').substring(0, 8);

  String _freshRunId() => DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(8, '0').substring(0, 8);

  Future<void> _runNow(String storeId) async {
    setState(() {
      _isRunning = true;
      _result = null;
      _error = null;
    });
    final runIdForThisRun = _runId; // capture; preview and execution share it
    try {
      final prepared = QueryPreparation.prepare(
        widget.name,
        widget.entry,
        storeId: storeId,
        runId: runIdForThisRun,
      );
      final result = await DittoManager.instance.runBenchmark(prepared, _iterations);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    if (mounted) {
      setState(() {
        _runId = _freshRunId(); // fresh ids for the NEXT run
        _isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider) ?? 'store_seattle';
    final prepared = QueryPreparation.prepare(widget.name, widget.entry, storeId: selectedStoreId, runId: _runId);

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(backgroundColor: colors.surface, title: const Text('Benchmark')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 13, color: colors.foregroundNormal)),
                const SizedBox(height: 6),
                _CategoryBadge(widget.entry.category),
              ]),
              const SizedBox(height: 16),
              DittoCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _queryBlock('Query', prepared.query),
                  if (prepared.preQueries.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _queryBlock('Pre-queries (run once)', prepared.preQueries.join('\n')),
                  ],
                  if (prepared.postQueries.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _queryBlock('Post-queries (run once)', prepared.postQueries.join('\n')),
                  ],
                ]),
              ),
              if (prepared.substitutions.isNotEmpty) ...[
                const SizedBox(height: 16),
                DittoCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Substitutions for a synced device', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                    const SizedBox(height: 6),
                    for (final note in prepared.substitutions)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('• $note', style: TextStyle(fontSize: 12, color: colors.foregroundSubtle)),
                      ),
                  ]),
                ),
              ],
              if (_result != null || _error != null) ...[
                const SizedBox(height: 16),
                DittoCard(
                  child: Column(children: [
                    if (_result != null) ...[
                      _resultRow('Result count', '${formatInt(_result!.resultCount)} rows'),
                      _resultRow('Mean', '${_result!.stats.meanMs.toStringAsFixed(2)} ms'),
                      _resultRow('Median', '${_result!.stats.medianMs.toStringAsFixed(2)} ms'),
                      _resultRow('p95', '${_result!.stats.p95Ms.toStringAsFixed(2)} ms'),
                      _resultRow('Min / Max', '${_result!.stats.minMs.toStringAsFixed(2)} / ${_result!.stats.maxMs.toStringAsFixed(2)} ms'),
                      const SizedBox(height: 8),
                      Text(
                        '${_result!.iterations} timed iterations, execution only (no rendering). The benchmark harness uses pilot + warmup + 50 iterations; this screen keeps it simple.',
                        style: TextStyle(fontSize: 12, color: colors.foregroundSubtle),
                      ),
                    ],
                    if (_error != null) DittoBadge(_error!, status: BadgeStatus.critical),
                  ]),
                ),
              ],
            ],
          ),
          // Floating run toolbar.
          Positioned(
            left: 16,
            right: 16,
            bottom: 8,
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: colors.borderNormal),
                boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                IconButton(
                  key: const Key('IterationsMinus'),
                  onPressed: _isRunning ? null : () => setState(() => _iterations = _iterations > 10 ? _iterations - 10 : _iterations - 1 < 1 ? 1 : _iterations - 1),
                  icon: const Icon(Icons.remove),
                ),
                Text('×$_iterations', style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 14, color: colors.foregroundNormal)),
                IconButton(
                  key: const Key('IterationsPlus'),
                  onPressed: _isRunning ? null : () => setState(() => _iterations = _iterations >= 10 ? (_iterations + 10).clamp(1, 100) : _iterations + 1),
                  icon: const Icon(Icons.add),
                ),
                const Spacer(),
                if (_isRunning) ...[
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('Running…', style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
                ] else
                  DittoButton(
                    widget.entry.isMutating ? 'Run (writes data)' : 'Run benchmark',
                    testKey: const Key('RunBenchmarkButton'),
                    onPressed: () {
                      if (widget.entry.isMutating) {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Run a mutating benchmark?'),
                            content: Text(
                              'This ${widget.entry.category} benchmark writes a synthetic document. On a synced device that write replicates to Big Peer; the runner uses fresh per-run ids and cleans up with a propagating DELETE (not EVICT, which is local-only).',
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                              TextButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  _runNow(selectedStoreId);
                                },
                                child: Text('Run', style: TextStyle(color: context.dittoColors.fillCritical)),
                              ),
                            ],
                          ),
                        );
                      } else {
                        _runNow(selectedStoreId);
                      }
                    },
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queryBlock(String title, String text) {
    final colors = context.dittoColors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, color: colors.codeMuted)),
      const SizedBox(height: 6),
      CodeBlock(text),
    ]);
  }

  Widget _resultRow(String label, String value) {
    final colors = context.dittoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Text(label, style: TextStyle(color: colors.foregroundSubtle)),
        const Spacer(),
        Text(value, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 13, color: colors.foregroundNormal)),
      ]),
    );
  }
}
