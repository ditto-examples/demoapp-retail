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

## Tests & quality gates

```sh
make test        # unit tests (models, query preparation, stats, orchestration)
make test-ui     # UI tests against live Big Peer (seed it first)
make lint        # SwiftLint (fatal build phase; zero-violations baseline)
make format      # SwiftFormat
make coverage    # 85% line-coverage gate (unit + UI in one bundle; ~91% now)
make periphery   # dead-code sweep (informational)
```

UI tests need Big Peer seeded and use launch arguments:
`-resetStoreSelection` (force the picker) or `-selectedStoreId store_seattle`
(skip it).

## Device builds (signing)

`DEVELOPMENT_TEAM` is intentionally empty in `project.yml` (per-developer).
Open the project in Xcode and select your team under Signing & Capabilities,
or export a local override — note that `make setup` (xcodegen) regenerates
`ZavaRetail.xcodeproj` from `project.yml`, so keep team selection in Xcode's
local settings or a fork-local `project.yml` edit rather than editing the
generated project (both the `.xcodeproj` and `project.yml` are committed;
regenerate-then-commit to avoid drift).

## macOS

The same scheme builds "My Mac" (macOS 26). Fonts register via CoreText at
launch on macOS (iOS uses the Info.plist `UIAppFonts` key).

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
