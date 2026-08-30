import SwiftUI
import Anvil

@main
struct ZavaRetailApp: App {
    @State private var appState = AppState()

    init() {
        FontRegistration.registerAnvilFonts()
    }

    var body: some Scene {
        WindowGroup {
            DittoTheme {
                RootView()
                    .environment(appState)
            }
        }
    }
}
