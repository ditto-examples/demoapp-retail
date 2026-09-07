import 'dart:developer' as developer;

import 'package:ditto_live/ditto_live.dart' show Ditto, StoreObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/database_config.dart';
import '../data/ditto_manager.dart';
import '../models/models.dart';

/// App-level state (1:1 port of the Swift reference's AppState). All
/// mutations happen on the Dart event loop (single-threaded UI thread).

enum BootPhase { loading, missingConfig, ready, failed }

class AppBootState {
  const AppBootState({
    this.phase = BootPhase.loading,
    this.failureMessage,
  });
  final BootPhase phase;
  final String? failureMessage;
}

class AppState extends Notifier<AppBootState> {
  static const keySelectedStore = 'selectedStoreId';

  List<Store> stores = [];
  String? selectedStoreId;
  String? lastError;
  Ditto? ditto; // handed to the tools viewer on the Ditto tab

  /// Drives the root when no store is selected: the picker appears only for
  /// an explicit "Switch store" or when the store catalog hasn't synced yet
  /// — first launch auto-selects the smallest-order store instead
  /// (`Store.demo_default`, stamped by the loader).
  bool showStorePicker = false;

  StoreObserver? _storesObserver;
  SharedPreferences? _prefs;
  bool _booting = false;
  /// Once per launch: the auto-default selection happens exactly once, so it
  /// can never override a deliberate user pick later in the session.
  bool _didAutoSelectDefaultStore = false;

  @override
  AppBootState build() {
    _loadPersisted();
    return const AppBootState();
  }

  Future<void> _loadPersisted() async {
    _prefs = await SharedPreferences.getInstance();
    selectedStoreId = _prefs?.getString(keySelectedStore);
  }

  void _persistSelection(String? storeId) {
    if (storeId != null) {
      _prefs?.setString(keySelectedStore, storeId);
    } else {
      _prefs?.remove(keySelectedStore);
    }
  }

  /// Boot is retryable: a transient failure (network, auth) must not brick
  /// the app. The Failed screen's Retry button calls this.
  void retryBoot() {
    if (state.phase != BootPhase.failed) return;
    state = const AppBootState();
    bootApp();
  }

  Future<void> bootApp() async {
    if (state.phase != BootPhase.loading || _booting) return;
    _booting = true;
    try {
      final config = DatabaseConfig.load();
      if (config == null) {
        state = const AppBootState(phase: BootPhase.missingConfig);
        return;
      }

      final instance = await DittoManager.instance.open(
        config,
        onError: (message) {
          lastError = message;
          _notify();
        },
      );
      ditto = instance;
      developer.log('Ditto open; sync started', name: 'AppState');

      // The dashboard header and the (on-demand) store picker observe the
      // shared (unfiltered) stores collection.
      _storesObserver ??= DittoManager.instance.observe<Store>(
        'SELECT * FROM stores',
        Store.fromJson,
        onChange: (stores) {
          developer.log('stores observer fired: ${stores.length} stores', name: 'AppState');
          this.stores = stores..sort((a, b) => a.store_name.compareTo(b.store_name));
          _autoSelectDefaultStoreIfNeeded();
          _notify();
        },
      );

      final persisted = selectedStoreId;
      if (persisted != null) {
        if (DittoManager.isValidStoreId(persisted)) {
          developer.log('applying persisted store selection: $persisted', name: 'AppState');
          await DittoManager.instance.applyStoreSelection(persisted);
        } else {
          // Corrupt/stale pref — drop it and land on the picker, never on a
          // recovery-less Failed screen.
          developer.log("persisted store id '$persisted' is invalid — clearing", name: 'AppState');
          selectedStoreId = null;
          _persistSelection(null);
        }
      }
      state = const AppBootState(phase: BootPhase.ready);
    } catch (e) {
      developer.log('boot failed: $e', name: 'AppState', level: 1000);
      state = AppBootState(phase: BootPhase.failed, failureMessage: e.toString());
    } finally {
      _booting = false;
    }
  }

  /// First-launch default (no picker step): as soon as the store catalog has
  /// synced, select the store the loader flagged `demo_default` — the one
  /// with the fewest orders in the loaded slice, i.e. the smallest first
  /// sync. Fallback for unflagged catalogs (older loads): the first physical
  /// store by name, then any store. Runs once per launch and never overrides
  /// a user pick.
  void _autoSelectDefaultStoreIfNeeded() {
    if (selectedStoreId != null || _didAutoSelectDefaultStore || stores.isEmpty) return;
    final defaultStore = stores.where((s) => s.demo_default == true).firstOrNull ??
        stores.where((s) => !s.is_online).firstOrNull ??
        stores.first;
    _didAutoSelectDefaultStore = true;
    developer.log('auto-selecting default store: ${defaultStore.store_id}', name: 'AppState');
    selectStore(defaultStore.store_id);
  }

  /// Store switch showcase (PLAN §4.1): re-points subscriptions and evicts
  /// the old store's data. On failure the UI rolls back to whatever store the
  /// manager actually serves, and the error surfaces in the banner.
  void selectStore(String storeId) {
    showStorePicker = false;
    selectedStoreId = storeId;
    _persistSelection(storeId);
    _notify();
    DittoManager.instance.applyStoreSelection(storeId).catchError((Object e) {
      lastError = 'Store switch failed: $e';
      selectedStoreId = DittoManager.instance.currentStoreId;
      _persistSelection(selectedStoreId);
      if (selectedStoreId == null) showStorePicker = true;
      _notify();
    });
  }

  /// "Switch store" — shows the on-demand picker; the per-store
  /// subscriptions for the current store stay live until a new selection
  /// replaces them.
  void switchStore() {
    showStorePicker = true;
    selectedStoreId = null;
    _persistSelection(null);
    _notify();
  }

  void dismissError() {
    lastError = null;
    _notify();
  }

  /// Riverpod's Notifier exposes state as an immutable snapshot; the mutable
  /// side channels (stores/selectedStoreId/lastError) are read by widgets via
  /// [watchAppState] below — any change calls _notify() which nudges [state]
  /// to a new equal-by-identity instance so dependents rebuild.
  void _notify() {
    state = AppBootState(phase: state.phase, failureMessage: state.failureMessage);
  }
}

/// The app-level provider.
final appStateProvider = NotifierProvider<AppState, AppBootState>(AppState.new);

/// Convenience selector providers for the mutable side channels — widgets
/// watch these so mutations through [AppState._notify] rebuild them.
final appStoresProvider = Provider<List<Store>>((ref) {
  ref.watch(appStateProvider);
  return ref.read(appStateProvider.notifier).stores;
});
final appSelectedStoreIdProvider = Provider<String?>((ref) {
  ref.watch(appStateProvider);
  return ref.read(appStateProvider.notifier).selectedStoreId;
});
final appShowStorePickerProvider = Provider<bool>((ref) {
  ref.watch(appStateProvider);
  return ref.read(appStateProvider.notifier).showStorePicker;
});
final appLastErrorProvider = Provider<String?>((ref) {
  ref.watch(appStateProvider);
  return ref.read(appStateProvider.notifier).lastError;
});
final appDittoProvider = Provider<Ditto?>((ref) {
  ref.watch(appStateProvider);
  return ref.read(appStateProvider.notifier).ditto;
});
