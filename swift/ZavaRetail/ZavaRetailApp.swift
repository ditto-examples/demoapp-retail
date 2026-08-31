import Anvil
import SwiftUI

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
                #if os(macOS)
                    // Content-driven minimum window: keeps the dashboard cards
                    // and paged lists legible when the window shrinks.
                    .frame(minWidth: 720, minHeight: 520)
                #endif
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }
}
