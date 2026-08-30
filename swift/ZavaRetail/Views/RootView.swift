import SwiftUI
import Anvil

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
            case .failed(let message):
                ContentUnavailableView(
                    "Ditto failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .ready:
                if appState.selectedStoreId == nil {
                    StorePickerView()
                } else {
                    MainTabView()
                }
            }
        }
        .background(colors.background)
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
            Tab("Ditto", systemImage: "circle.hexagongrid") {
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
