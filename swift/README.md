# Zava Retail — SwiftUI (iOS/iPadOS 26 + macOS 26)

The reference implementation of the Zava Retail demo app (see
[../PLAN.md](../PLAN.md)). Swift 6 language mode, strict concurrency,
SwiftUI, one target for iPhone/iPad and Mac.

## Stack

- **Ditto**: `DittoSwift` 5.1.0 + `DittoSwiftTools` 10.0.0 (Tools tab)
- **Design system**: [Anvil](../vendor/anvil/swift/Anvil) (vendored SPM
  package; fonts registered at launch via `FontRegistration`)
- **Architecture**: `actor DittoManager` (the only Ditto access point) +
  `@MainActor @Observable` AppState + per-screen `@Observable` state classes.
  DQL strings live at the call site — these apps teach the SDK.
- **Env**: root `.env` → `buildEnv.sh` build phase → `Generated/Env.swift`
  (gitignored).

## Setup & run

```sh
make setup      # buildEnv.sh + xcodegen (required after checkout)
open ZavaRetail.xcodeproj   # pick a simulator/device; macOS "My Mac" works too
```

Prereqs: Xcode 26+, XcodeGen (`brew install xcodegen`), and the repository
root `.env` (see `../.env.template`). Seed Big Peer first:
`python3 ../scripts/load_data.py --size 10k` (or `100k`).

Regenerate the project whenever files are added/removed (no synchronized
groups): `xcodegen`.

## Tests

```sh
# unit tests (catalog decode, query preparation, stats, fonts)
xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ZavaRetailTests test

# UI tests (live: picker → store → dashboard sync; Query Runner executes
# orders__select__by_id against the synced store)
xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ZavaRetailUITests test
```

UI tests need Big Peer seeded and use launch arguments:
`-resetStoreSelection` (force the picker) or `-selectedStoreId store_seattle`
(skip it).

## Where things live

- `Data/DittoManager.swift` — open/auth/subscriptions/store-switch (EVICT +
  re-register), observer + execute helpers, the benchmark runner. All
  Swift 6-strict: `@Sendable` callbacks capture values only; decoded Sendable
  models hop to the main actor.
- `State/AppState.swift` — boot flow, store selection (UserDefaults),
  error surface.
- `Views/` — Dashboard / Orders / Products / Customers / Ditto (Query Runner,
  sync status, indexes, DittoAllToolsMenu, switch store).
- `Models/BenchmarkCatalog.swift` — the bundled 72-query catalog + the
  substitution rules for running benchmarks on a synced device (store
  literal, per-run bench ids, EVICT→DELETE cleanup).
