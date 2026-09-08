import 'package:anvil/anvil.dart';
import 'package:ditto_flutter_tools/ditto_flutter_tools.dart';
import 'package:ditto_live/ditto_live.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ditto_manager.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../components.dart';
import '../queries/query_catalog_screen.dart';

/// The Ditto system tab: Query Runner, live system:* viewers, the official
/// tools menu, and Switch Store.
class DittoTabScreen extends ConsumerWidget {
  const DittoTabScreen({super.key});

  static const syncStatusQuery = 'SELECT * FROM system:data_sync_info';
  static const explanation =
      'System & tools for the synced store. Query Runner browses and times the 96-query retail-JOINs benchmark catalog against the live synced store (JOINs run on-device, SDK 5.1+). Sync status and Indexes are live views over Ditto\'s system:data_sync_info and system:indexes virtual collections (the query above). Ditto tools is the official diagnostic viewer. Switch store shows the picker: picking a new store cancels the per-store subscriptions and EVICTs its local orders/inventory/order items (EVICT is local-only — the difference from DELETE is a teaching moment); items are evictable per store because store_id is denormalized onto each one (sync subscriptions reject JOINs, so the item\'s own row carries the filter key).';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.dittoColors;
    final ditto = ref.watch(appDittoProvider);
    final appState = ref.read(appStateProvider.notifier);

    Widget row(String title, VoidCallback onTap) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Text(title, style: TextStyle(fontSize: 16, color: colors.foregroundNormal)),
              const Spacer(),
              Icon(Icons.chevron_right, color: colors.foregroundSubtle),
            ]),
          ),
        );

    Widget footer(String text) => Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
          child: Text(text, style: TextStyle(fontSize: 12, color: colors.foregroundSubtle)),
        );

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Ditto'),
        actions: [QueryInfoButton(query: syncStatusQuery, explanation: explanation, tooltip: 'About this screen')],
      ),
      body: ListView(children: [
        row('Query Runner', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QueryCatalogScreen()))),
        footer('Browse and run the 96-query retail-JOINs benchmark catalog against the synced store, with timing.'),
        row('Sync status', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncStatusScreen()))),
        row('Indexes', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IndexesScreen()))),
        footer("Live views over Ditto's system:data_sync_info and system:indexes virtual collections."),
        if (ditto != null) ...[
          row('Ditto tools', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ToolsScreen(ditto: ditto)))),
          footer('The official Ditto tools viewer (ditto_flutter_tools).'),
        ],
        TextButton(
          onPressed: appState.switchStore,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Switch store', style: TextStyle(color: colors.fillCritical, fontSize: 16)),
          ),
        ),
        footer('Shows the store picker. The current store keeps syncing until you pick a new one — picking it cancels its per-store subscriptions and evicts its local orders/inventory/order items (EVICT — local only). Items are per-store because store_id is denormalized onto each one: sync subscriptions reject JOINs, so the item\'s own row carries the filter key.'),
      ]),
    );
  }
}

// MARK: - Sync status (system:data_sync_info)

class SyncStatusScreen extends ConsumerStatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  ConsumerState<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends ConsumerState<SyncStatusScreen> {
  var _rows = <SyncStatusInfo>[];
  String? _error;
  StoreObserver? _observer;

  static const query = 'SELECT * FROM system:data_sync_info';
  static const explanation =
      'Live rows from Ditto\'s system:data_sync_info virtual collection — one per sync session (Big Peer plus any mesh peers), each with its session status and synced commit id. Watch it during a store switch: the old subscription drains and the new store\'s slice starts filling in.';

  @override
  void initState() {
    super.initState();
    try {
      _observer = DittoManager.instance.observeRaw(
        query,
        onChange: (rows) => setState(() => _rows = [
          for (final row in rows)
            if (SyncStatusInfo.from(row) != null) SyncStatusInfo.from(row)!,
        ]),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _observer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Sync status'),
        actions: [QueryInfoButton(query: query, explanation: explanation, tooltip: 'About this screen')],
      ),
      body: _rows.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_error != null)
                  DittoBadge(_error!, status: BadgeStatus.critical)
                else ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text('No sync sessions yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                  Text('Status appears once sync sessions establish.', style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
                ],
              ]),
            )
          : ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
              itemBuilder: (context, index) {
                final row = _rows[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(row.id, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundNormal), maxLines: 2),
                    const SizedBox(height: 6),
                    Row(children: [
                      DittoBadge(row.isDittoServer ? 'Big Peer' : 'peer', status: row.isDittoServer ? BadgeStatus.promo : BadgeStatus.info),
                      const SizedBox(width: 8),
                      DittoBadge(row.syncSessionStatus, status: row.syncSessionStatus == 'Connected' ? BadgeStatus.success : BadgeStatus.warning),
                      if (row.syncedUpToLocalCommitId != null) ...[
                        const SizedBox(width: 8),
                        Text('commit ${row.syncedUpToLocalCommitId}', style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundSubtle)),
                      ],
                    ]),
                  ]),
                );
              },
            ),
    );
  }
}

// MARK: - Indexes (system:indexes)

class IndexesScreen extends ConsumerStatefulWidget {
  const IndexesScreen({super.key});

  @override
  ConsumerState<IndexesScreen> createState() => _IndexesScreenState();
}

class _IndexesScreenState extends ConsumerState<IndexesScreen> {
  var _rows = <IndexInfo>[];
  String? _error;
  StoreObserver? _observer;

  static const query = 'SELECT * FROM system:indexes';
  static const explanation =
      'Live rows from Ditto\'s system:indexes virtual collection — every index on the local store. Note the app\'s zava_* indexes (created at startup to back the per-store subscriptions; app-namespaced so the Query Runner\'s benchmark cleanup can\'t drop them) alongside any indexes a benchmark created and dropped during a run.';

  @override
  void initState() {
    super.initState();
    try {
      _observer = DittoManager.instance.observeRaw(
        query,
        onChange: (rows) => setState(() {
          _rows = [
            for (final row in rows)
              if (IndexInfo.from(row) != null) IndexInfo.from(row)!,
          ]..sort((a, b) => a.id.compareTo(b.id));
        }),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _observer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        title: const Text('Indexes'),
        actions: [QueryInfoButton(query: query, explanation: explanation, tooltip: 'About this screen')],
      ),
      body: _rows.isEmpty && _error == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('No indexes yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
                Text('Indexes appear once the store is open.', style: TextStyle(fontSize: 14, color: colors.foregroundSubtle)),
              ]),
            )
          : ListView.separated(
              itemCount: _rows.length + (_error != null ? 1 : 0),
              separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
              itemBuilder: (context, index) {
                if (_error != null && index == 0) {
                  return Padding(padding: const EdgeInsets.all(16), child: DittoBadge(_error!, status: BadgeStatus.critical));
                }
                final row = _rows[_error != null ? index - 1 : index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(row.id, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 12, color: colors.foregroundNormal)),
                    if (row.definition.isNotEmpty)
                      Text(row.definition, style: TextStyle(fontFamily: 'packages/anvil/IBMPlexMono', fontSize: 11, color: colors.foregroundSubtle)),
                  ]),
                );
              },
            ),
    );
  }
}

// MARK: - Official Ditto tools viewer

/// ditto_flutter_tools ships standalone views (no umbrella menu): the tools
/// screen lists them, each pushed as a sub-screen.
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key, required this.ditto});
  final Ditto ditto;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    Widget row(String title, Widget destination) => InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => destination)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Text(title, style: TextStyle(fontSize: 16, color: colors.foregroundNormal)),
              const Spacer(),
              Icon(Icons.chevron_right, color: colors.foregroundSubtle),
            ]),
          ),
        );
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(backgroundColor: colors.surface, title: const Text('Ditto tools')),
      body: ListView(children: [
        row('Peers', PeerListView(ditto: ditto)),
        row('Peer sync status', PeerSyncStatusView(ditto: ditto)),
        row('Disk usage', DiskUsageView(ditto: ditto)),
        row('System settings', SystemSettingsView(ditto: ditto)),
        row('Query editor', QueryEditorView(ditto: ditto)),
        row('Permissions health', const PermissionsHealthView()),
      ]),
    );
  }
}
