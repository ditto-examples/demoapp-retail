import Anvil
import SwiftUI

/// Boot gate: loading → missing-config / failure / store picker → main tabs.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dittoColors) private var colors

    var body: some View {
        Group {
            switch appState.boot {
            case .loading:
                ProgressView("Starting Ditto…")
                    .task { await appState.bootApp() }
            case .missingConfig:
                MissingConfigView()
            case let .failed(message):
                // Boot failures are transient as often as not — offer retry
                // (DittoManager.open() was built to retry cleanly; the UI
                // should take advantage of it).
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Ditto failed to start",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    AnvilButton("Retry") {
                        appState.retryBoot()
                    }
                    .accessibilityIdentifier("boot.retry")
                }
            case .ready:
                if appState.selectedStoreId != nil {
                    MainTabView()
                } else if appState.showStorePicker {
                    // Explicit "Switch store".
                    StorePickerView()
                } else if appState.stores.isEmpty {
                    // First launch, catalog still syncing: wait here instead
                    // of flashing a picker the user must never complete
                    // manually (PLAN §4.1). Same hint the picker's empty
                    // state used to double as.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for the store catalog to sync…")
                            .foregroundStyle(colors.foregroundSubtle)
                        Text("No data yet? Run scripts/load_data.py to seed Big Peer.")
                            .font(.callout)
                            .foregroundStyle(colors.foregroundSubtle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    // First launch: the catalog synced and the loader-flagged
                    // smallest store is being selected automatically — no
                    // picker step (PLAN §4.1).
                    ProgressView("Preparing your store…")
                        .accessibilityIdentifier("autoSelect.store")
                }
            }
        }
        .background(colors.background)
        // The one global error surface — lastError is always readable by the
        // user (auth failures, store-switch failures, observer decode drift).
        .safeAreaInset(edge: .top) {
            if let message = appState.lastError {
                ErrorBanner(message: message) {
                    appState.lastError = nil
                }
                .padding()
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.dittoColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colors.fillCritical)
            Text(message)
                .font(.callout)
                .foregroundStyle(colors.foregroundNormal)
                .lineLimit(3)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(colors.foregroundSubtle)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(colors.fillCriticalSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Missing .env is a UI state, never a crash (repo convention).
struct MissingConfigView: View {
    var body: some View {
        ContentUnavailableView(
            "Ditto credentials missing",
            systemImage: "key.slash",
            description: Text(
                "Copy .env.template to .env at the repository root and fill in "
                    + "DITTO_DATABASE_ID, DITTO_DEVELOPMENT_TOKEN, and DITTO_SERVER_URL "
                    + "from the Ditto portal, then rebuild."
            )
        )
    }
}

/// The five tabs (PLAN §4.2): Dashboard / Orders / Products / Customers / Ditto.
struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                DashboardView()
            }
            Tab("Orders", systemImage: "receipt") {
                OrdersView()
            }
            Tab("Products", systemImage: "hammer") {
                ProductsView()
            }
            Tab("Customers", systemImage: "person.2") {
                CustomersView()
            }
            // The brand mark as the tab icon (asset has light/dark variants;
            // the tab bar tints it as a template image).
            Tab("Ditto", image: "DittoMark") {
                DittoTabView()
            }
        }
    }
}

#Preview {
    DittoTheme {
        MissingConfigView()
    }
}
