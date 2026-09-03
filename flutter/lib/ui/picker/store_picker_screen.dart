import 'package:anvil/anvil.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import '../components.dart';

/// The showcase flow: pick one of the 8 Zava stores (synced over the
/// always-on shared `SELECT * FROM stores` subscription). Persisted via
/// shared_preferences; re-picking switches subscriptions.
class StorePickerScreen extends ConsumerWidget {
  const StorePickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.dittoColors;
    final stores = ref.watch(appStoresProvider);
    final appState = ref.read(appStateProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Choose your store',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: colors.foregroundNormal),
          ),
        ),
        Divider(height: 1, color: colors.borderNormal),
        Expanded(
          child: stores.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text('Waiting for the store catalog to sync…', style: TextStyle(color: colors.foregroundSubtle)),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          'No data yet? Run scripts/load_data.py to seed Big Peer.',
                          style: TextStyle(color: colors.foregroundSubtle, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: stores.length,
                  separatorBuilder: (_, _) => Divider(height: 0.5, color: colors.borderNormal),
                  itemBuilder: (context, index) {
                    final store = stores[index];
                    return InkWell(
                      onTap: () => appState.selectStore(store.store_id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  store.store_name,
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.foregroundNormal),
                                ),
                                Text(
                                  '${store.location.city}, ${store.location.state}',
                                  style: TextStyle(fontSize: 14, color: colors.foregroundSubtle),
                                ),
                              ],
                            ),
                            const Spacer(),
                            if (store.is_online) ...[
                              const DittoBadge('online', status: BadgeStatus.promo),
                              const SizedBox(width: 8),
                            ],
                            Icon(Icons.chevron_right, color: colors.foregroundSubtle),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
