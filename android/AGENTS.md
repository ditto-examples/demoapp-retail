# AGENTS.md — android/ (Zava Retail Compose app)

Nearest-file rule: this file wins over the root AGENTS.md for work in `android/`.

M2 port of the SwiftUI reference app (swift/) — deliberate 1:1 UX translation,
not a redesign. When the SwiftUI app changes, port the change here in the same
shape (DQL strings verbatim, same copy, same states).

## Commands

| Task | Command |
|---|---|
| Build | `./gradlew :app:assembleDebug` |
| Unit tests | `./gradlew :app:testDebugUnitTest` (23 tests: paging, runner transforms/stats/orchestration, catalog, sanitizers) |
| Install + run | `adb install -r app/build/outputs/apk/debug/app-debug.apk` then `am start -n live.ditto.zava/.MainActivity` |
| UI-test store-reset hook | launch extra `-e resetStoreSelection true` clears the persisted store |

## Conventions

- **Ditto access**: `object DittoManager` (data/) is the ONLY access point —
  a plain singleton, *not* Koin. This deviates deliberately from PLAN §4.3's
  "Koin singleton" wording: the repo-wide rule is "no DI frameworks, one thin
  access point", and the Swift reference (`actor DittoManager.shared`) ports
  1:1. DQL strings stay at the call site.
- **Observer pipeline**: `registerObserver` callback → decode via
  `item.jsonString()` + kotlinx-serialization → `item.dematerialize()` →
  `ResultCoalescer` (100 ms latest-wins) → main-thread state. Screens hold
  state in plain classes with `mutableStateOf` fields + a Main.immediate
  scope; observers close in `DisposableEffect`'s onDispose.
- **Compose gotcha (caught on-device)**: every field read during composition
  must be `mutableStateOf` — a plain `var` read in an `if` branch that shows
  skeletons never invalidates, so the screen sticks. (The dashboard's
  `loadedFor` is the reference fix.)
- **Screen state fields**: store-switch = clear rows → skeletons until the
  first emission for the new store (never render another store's data).
  Orders search: dedicated `searchJob` (never the restart job), store id read
  AFTER the 500 ms debounce, matches cleared + re-run on store switch.
- **Env**: gradle reads the ROOT `../.env` into `BuildConfig` fields
  (DITTO_DATABASE_ID / DITTO_DEVELOPMENT_TOKEN / DITTO_SERVER_URL) in
  app/build.gradle.kts. Missing config is a UI state, never a crash.
- **benchmarks.json**: bundled as an asset via `assets.srcDir("../../shared")`
  (module-relative path — do not "fix" to ../shared).
- **Theme**: Anvil `DittoTheme` + `DittoColors.current` semantic colors
  (vendored module is theme-only; `ui/components/Anvil.kt` holds the shared
  card/badge/button/search-field/skeleton wrappers). Fonts come bundled with
  the Anvil module.
- **Nav**: Navigation 3 backstack + `NavigationSuiteScaffold` (bottom bar on
  phones, rail on wide/foldable screens — verified on a Galaxy Z Fold).
- **App icon**: adaptive icon — citrus #E7EE00 background + neutral950 Ditto
  mark as a VECTOR foreground (`res/drawable/ic_launcher_foreground.xml`,
  geometry from `assets/ditto_mark-dark.svg`, scaled to the 66/108 safe
  zone); brand parity with iOS/macOS (`swift/scripts/make_icon.swift`).
- **Multicast (beta)**: Ditto tab → "Multicast (beta)" → MulticastScreen
  toggles the reliable UDP multicast transport (`peerToPeer.multicastBeta`,
  Android-only private beta). Pattern lifted from the pubsec-edgesync
  sidecar: settings persist in SharedPreferences and re-apply after every
  `DittoManager.open`; `updateTransportConfig` applies live (no sync
  restart); an app-level `WifiManager.MulticastLock` is held while enabled
  (SDK holds its own too). Validation: group must be IPv4 class-D, port
  1..65535 (0 rejected — SDK reads it as "any port", breaking rendezvous).
  Multicast connections show as `Multicast` in the tools Peers view.
- **Brand assets**: `assets/` (repo root) holds the Ditto mark/logotype SVGs
  (dark + white). Android uses vector drawables tinted with the Anvil
  foreground token (`ditto_mark.xml` intrinsic size MUST stay 24dp — a
  painter with a large intrinsic size renders unbounded in `Icon`; caught
  on-device). iOS uses asset-catalog imagesets with Any/Dark variants — the
  tab-icon SVG needs explicit small `width`/`height` attributes or the
  tab-bar layout breaks (hit points go off-screen).
