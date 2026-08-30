import CoreText
import Foundation

/// Registers the vendored Anvil fonts (Inter + IBM Plex Mono) at runtime.
/// UIAppFonts in Info.plist covers iOS; macOS has no UIAppFonts, so this
/// CoreText registration is the single code path that works on both.
enum FontRegistration {
    static func registerAnvilFonts() {
        let names = [
            "inter_regular",
            "ibm_plex_mono_regular",
            "ibm_plex_mono_bold",
            "ibm_plex_mono_italic",
        ]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let description = error?.takeUnretainedValue().localizedDescription ?? "unknown"
                print("FontRegistration: \(name) not registered: \(description)")
            }
        }
    }
}
