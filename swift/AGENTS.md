# AGENTS.md — swift/ (Zava Retail SwiftUI app)

Nearest-file rule: this file wins over the root AGENTS.md for work in `swift/`.

## Quality bar (enforced)

- **SwiftLint is a fatal build phase** — zero violations baseline, including
  `--strict` (warnings ARE the gate; the codebase is new). Config:
  `.swiftlint.yml`. Two custom choke-point rules are load-bearing:
  `sync_start_choke_point` (sync.start only via `DittoManager.startSyncNow`)
  and `ditto_open_choke_point` (Ditto.open only in DittoManager). Each has
  exactly one inline-disable at the legitimate call site — any new site must
  justify its own inline disable in review.
- **SwiftFormat is the formatting authority** — `.swiftformat`; run
  `make format` before committing. Conflicting SwiftLint rules are disabled
  with documented reasons in the config.
- **Coverage gate: 85%** line coverage on the ZavaRetail target via
  `make coverage` (unit + UI tests in one result bundle; currently ~91%).
  `swift/scripts/check_coverage.py` prints the lowest-coverage files on
  failure.
- **Periphery** (`make periphery`) for dead-code sweeps — informational, not
  a gate. Expected noise: `Models.swift` "assign-only property" warnings are
  deliberate (models mirror the Ditto document shape field-for-field, even
  fields the UI doesn't render); vendored Anvil palette warnings are not ours.

## Commands

| Task | Command |
|---|---|
| Setup / regen project | `make setup` (buildEnv.sh + xcodegen — rerun after adding/removing files) |
| Lint | `make lint` / `make lint-strict` |
| Format | `make format` (check: `make format-check`) |
| Unit tests | `make test` |
| UI tests (live Big Peer) | `make test-ui` |
| Coverage gate | `make coverage` |
| Dead code | `make periphery` |
| Regenerate app icon | `make icon` (scripts/make_icon.swift — citrus field + neutral950 bag, self-checking render) |

## Conventions

- Swift 6 language mode + strict concurrency (complete). Zero-warning builds.
- `actor DittoManager` is the only Ditto access point. `@Sendable` callbacks
  capture values only; decoded Sendable models cross to `@MainActor` state;
  observer emissions coalesce latest-wins at 100 ms via `ResultCoalescer`.
- Store switches carry `selectionEpoch`; any code that suspends mid-switch
  must re-check the epoch before mutating subscription state.
- `open()` shares one in-flight task — never call `Ditto.open` twice.
- Store ids must match `^[a-z0-9_\-]+$` (`DittoManager.isValidStoreId`) before
  flowing into DQL strings or subscription args.
- os_log (`Logger.sync` / `Logger.ui`) instead of print; errors surface to
  `AppState.lastError` (the banner in RootView) — never write errors to
  nowhere.
- **Aggregate rows decode as optionals**: DQL omits group keys/aggregates on
  an empty match set (a degenerate `{"orders": 0}` row arrives); filter those
  rows, never render fake zeros.
- **Screens never render another store's data**: on selection change, clear
  rows and show `SkeletonRows`/`SkeletonCard` ghosts until the first emission
  for the new store. Dashboard cards are live observers (values climb as sync
  delivers), not one-shot fetches.
