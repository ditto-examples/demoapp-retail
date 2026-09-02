import 'package:anvil/anvil.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/app_state.dart';
import 'ui/components.dart';
import 'ui/customers/customers_screen.dart';
import 'ui/dashboard/dashboard_screen.dart';
import 'ui/ditto/ditto_tab_screen.dart';
import 'ui/orders/orders_screen.dart';
import 'ui/picker/store_picker_screen.dart';
import 'ui/products/products_screen.dart';

/// Zava Retail — Flutter port (PLAN M3). Riverpod for app-level state;
/// screens hold their own observer state (1:1 with the reference apps).
void main() {
  runApp(const ProviderScope(child: ZavaRetailApp()));
}

class ZavaRetailApp extends StatelessWidget {
  const ZavaRetailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zava Retail',
      debugShowCheckedModeBanner: false,
      home: DittoTheme(child: const AppRoot()),
    );
  }
}

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  @override
  void initState() {
    super.initState();
    // Boot once on first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(appStateProvider.notifier).bootApp();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    final boot = ref.watch(appStateProvider);
    final selectedStoreId = ref.watch(appSelectedStoreIdProvider);
    final lastError = ref.watch(appLastErrorProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          if (lastError != null) _ErrorBanner(lastError, onDismiss: () => ref.read(appStateProvider.notifier).dismissError()),
          Expanded(
            child: switch (boot.phase) {
              BootPhase.loading => Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text('Starting Ditto…', style: TextStyle(color: colors.foregroundSubtle)),
                  ]),
                ),
              BootPhase.missingConfig => const _MissingConfigScreen(),
              BootPhase.failed => _FailedScreen(boot.failureMessage ?? 'unknown error', onRetry: () => ref.read(appStateProvider.notifier).retryBoot()),
              BootPhase.ready => selectedStoreId == null ? const StorePickerScreen() : const MainTabs(),
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message, {required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return SafeArea(
      bottom: false,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.fillCriticalSecondary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(Icons.warning_amber, color: colors.fillCritical),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(fontSize: 14, color: colors.foregroundNormal), maxLines: 3)),
          IconButton(icon: Icon(Icons.close, color: colors.foregroundSubtle), tooltip: 'Dismiss', onPressed: onDismiss),
        ]),
      ),
    );
  }
}

class _MissingConfigScreen extends StatelessWidget {
  const _MissingConfigScreen();

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.key_off, size: 48, color: colors.foregroundSubtle),
          const SizedBox(height: 12),
          Text('Ditto credentials missing', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
          const SizedBox(height: 8),
          Text(
            'Copy .env.template to .env at the repository root and fill in DITTO_DATABASE_ID, DITTO_DEVELOPMENT_TOKEN, and DITTO_SERVER_URL from the Ditto portal, then rebuild.',
            style: TextStyle(fontSize: 14, color: colors.foregroundSubtle),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}

class _FailedScreen extends StatelessWidget {
  const _FailedScreen(this.message, {required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warning_amber, size: 48, color: colors.foregroundSubtle),
          const SizedBox(height: 12),
          Text('Ditto failed to start', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.foregroundNormal)),
          Text(message, style: TextStyle(fontSize: 14, color: colors.foregroundSubtle), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          DittoButton('Retry', onPressed: onRetry, testKey: const Key('boot.retry')),
        ]),
      ),
    );
  }
}

/// The five tabs with adaptive navigation: bottom NavigationBar on narrow
/// screens (phones, the Fold's cover display), side NavigationRail on wide
/// ones (tablets, the Fold's inner display) — switching live on fold/unfold.
class MainTabs extends StatefulWidget {
  const MainTabs({super.key});

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> {
  var _selectedIndex = 0;

  static const _tabs = [
    (label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home),
    (label: 'Orders', icon: Icons.receipt_long_outlined, selectedIcon: Icons.receipt_long),
    (label: 'Products', icon: Icons.handyman_outlined, selectedIcon: Icons.handyman),
    (label: 'Customers', icon: Icons.groups_outlined, selectedIcon: Icons.groups),
    (label: 'Ditto', icon: Icons.hub_outlined, selectedIcon: Icons.hub),
  ];

  static const _screens = [
    DashboardScreen(),
    OrdersScreen(),
    ProductsScreen(),
    CustomersScreen(),
    DittoTabScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.dittoColors;
    // Material's width breakpoint for compact layouts (600dp).
    final wide = MediaQuery.sizeOf(context).width >= 600;

    // IndexedStack keeps every tab alive (state + scroll + observers survive
    // tab switches — matching the SwiftUI TabView's behavior).
    final content = IndexedStack(index: _selectedIndex, children: _screens);

    if (wide) {
      return Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) => setState(() => _selectedIndex = index),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final tab in _tabs)
                NavigationRailDestination(
                  icon: Icon(tab.icon, size: 24),
                  selectedIcon: Icon(tab.selectedIcon, size: 24),
                  label: Text(tab.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
          VerticalDivider(width: 1, color: colors.borderNormal),
          Expanded(child: content),
        ],
      );
    }
    return Scaffold(
      backgroundColor: colors.background,
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(
              icon: Icon(tab.icon, size: 24),
              selectedIcon: Icon(tab.selectedIcon, size: 24),
              label: tab.label,
            ),
        ],
      ),
    );
  }
}
