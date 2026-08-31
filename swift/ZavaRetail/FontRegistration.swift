import CoreText
import Foundation
import OSLog

/// Registers the vendored Anvil fonts (Inter + IBM Plex Mono).
/// iOS registers them via the Info.plist `UIAppFonts` key; macOS has no
/// UIAppFonts, so the CoreText runtime registration runs there only (running
/// it on iOS too would double-register and log misleading errors).
enum FontRegistration {
    static func registerAnvilFonts() {
        #if os(macOS)
        let names = [
            "inter_regular",
            "ibm_plex_mono_regular",
            "ibm_plex_mono_bold",
            "ibm_plex_mono_italic"
        ]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let description = error?.takeUnretainedValue().localizedDescription ?? "unknown"
                Logger.ui.error("FontRegistration: \(name) not registered: \(description)")
            }
        }
        #endif
    }
}
