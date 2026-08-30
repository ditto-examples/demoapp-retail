# Zava Retail Demo Apps — Plan

Demo apps for the **retail benchmark dataset** used in `dql-metrics-benchmark`,
built to show how Ditto works on each mobile platform against a realistically
large dataset. Four apps, one shared blueprint:

| App | Stack | UI framework |
|---|---|---|
| `swift/` | SwiftUI, **Swift 6 language mode only**, modern Xcode (16+, verified on latest) | Anvil SwiftUI package (vendored) |
| `android/` | Kotlin 2.4.x, Jetpack Compose, AGP 9.x, compileSdk 37 | Anvil Material3 modules (vendored) |
| `flutter/` | Flutter **3.41**+ / modern Dart | Anvil Flutter package (vendored) |
| `rn-expo/` | React Native + Expo **SDK 57** | Anvil RN package (vendored) |

**Modern platform versions only** — no legacy language modes, no legacy SDK
majors. Where a version below differs from what `mflix-mongodb-connector` pins,
we target the newer one.

The product concept: a **Zava Retail store-associate app**. The user picks one
of the 8 Zava stores; the device registers the same subscription shapes the
benchmark measures (shared catalog + per-store data); every screen is powered
by queries taken from (or derived from) the 72-benchmark DQL catalog.

Locked decisions (2026-08-29):

- **Dataset sizing** — deterministic slices of the `full`-variant files so all
  8 stores are populated at every size (1k/5k/10k/30k/100k orders).
- **Query showcase** — interactive in-app runner: the 72 benchmark queries ship
  bundled in each app, browsable and executable with timing.
- **Reference platform** — SwiftUI first; its UX/screen patterns are then ported
  to Android, Flutter, RN.
- **Loader** — Python 3, standard library only.
- **SwiftUI app** — Swift 6 language mode (strict concurrency, `@Observable`),
  modern Xcode only. No Swift 5 compatibility mode.
- **Modern platform versions only** — Swift 6 / latest Xcode, Flutter 3.41+,
  AGP 9.x + Kotlin 2.4.x + compileSdk 37, Expo SDK 57. No legacy versions.

---

## 1. Source material

### 1.1 The dataset

`/Users/labeaaa/Developer/dql-metrics-benchmark/benchmarks/retail`
(origin: [microsoft/ai-tour-26-zava-diy-dataset-plus-mcp](https://github.com/microsoft/ai-tour-26-zava-diy-dataset-plus-mcp),
document-modeled for Ditto).

Seven collections, two tiers:

| Tier | Collection | Docs (full variant) | Subscription |
|---|---|---:|---|
| Shared catalog | `stores` | 8 | unfiltered |
| Shared catalog | `categories` | 9 | unfiltered |
| Shared catalog | `products` | 400 | unfiltered |
| Shared catalog | `customers` | 25,000 | unfiltered (walk-ins could be anyone) |
| Per-store | `inventory` | 3,167 | `WHERE _id.store_id = '<store>'` (composite `_id: {store_id, product_id}`) |
| Per-store | `orders` | 100,000 | `WHERE store_id = '<store>' AND deleted = false` |
| Per-store | `order_items` | 199,757 | `WHERE store_id = '<store>' AND deleted = false` (`store_id` denormalized because DQL has no JOINs in v5.0) |

Schema notes the apps should surface as teaching moments:

- Composite `_id` on `inventory` (subfield queries + composite-key indexing).
- MAP fields for CRDT-friendly independent updates (`categories.seasonal_multipliers`,
  `inventory.location` aisle/shelf/bin, `products.specifications`).
- Soft-delete `"deleted": false` on every doc.
- Denormalized display fields on `orders` (`customer_name`, `store_name`).
- ISO8601 timestamp strings (`order_date`, `created_at`) — sortable/indexable as strings.

### 1.2 The benchmark catalog

`benchmarks/retail/benchmarks.json` — 72 named DQL benchmarks
(`<collection>__<op>__<variant>`), categories: `SELECT`, `INDEX_SELECT`,
`INSERT`, `UPDATE`, `DELETE`, `EVICT`, `AGGREGATION`, plus 4 `subscription__*`
queries that are exactly what a Seattle device registers at cold start.
Each entry: `query`, optional `preQueries`/`postQueries` (index create/drop,
cleanup), `category`. 23 KB — small enough to bundle into every app.

### 1.3 Reference apps

Two reference codebases, used for different things:

**`/Users/labeaaa/Developer/ditto-edge-studio`** — the source of truth for
**modern Ditto integration under strict concurrency**, proven in production:

- Swift app: `SWIFT_VERSION = 6.0` + `SWIFT_STRICT_CONCURRENCY = complete` +
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`, DittoSwift **5.1.0**. Patterns we
  adopt verbatim (all from `SwiftUI/EdgeStudio/`):
  - `actor DittoManager` singleton owning the `Ditto` instance; config built
    by a `nonisolated static` pure function; `try await Ditto.open(config:)`.
  - Sync start/stop through `nonisolated static` funnels taking `Ditto` as a
    parameter, running the SDK call inside `Task.detached(priority: .utility)`
    (priority-inversion avoidance), publishing to a `@MainActor @Observable`
    runtime-state store after the call returns.
  - Store observers: `registerObserver(query, deliverOn: <serial utility
    queue>)` → build a **Sendable DTO** from the result cursors synchronously
    (`JSONSerialization`, never `item.jsonData()` which traps) →
    `item.dematerialize()` to release cursors → `Task { @MainActor }` hop →
    **100 ms coalescing flush** so SwiftUI recomposes once per burst.
  - Repositories as actors with `@escaping @MainActor @Sendable` update
    callbacks; writes capture `databaseId` and refuse stale sessions.
  - `DQLExecuting` protocol seam wrapping `store.execute(query:arguments:)`
    — this is how the non-Sendable `[String: Any?]` boundary is crossed
    cleanly in Swift 6, and it makes DQL fakeable in tests.
  - Auth expiration handler captures *values* (token, AppState), never the
    actor; errors hop to `@MainActor`.
  - `@unchecked Sendable` only with a written mutation contract (see the
    repo's `blog-article-swift-6-migration.md` — its audit-your-escape-hatches
    discipline is our convention too).
- Android app: AGP 9.2.1 / Kotlin 2.3.21 / Gradle 9.4.1 / compileSdk 37 /
  minSdk 28 / Compose BOM 2026.05.01 / Navigation 3 / Koin, Ditto
  `ditto-kotlin-android` **5.1.0**. Its `DittoManager` (plain class, Koin
  `single`, `DittoFactory.create(config, appScope)` on `Dispatchers.IO`,
  null-then-close ordering) and `StudioSession` (StateFlow state, observer
  handle maps, 100 ms coalescing under a lock, `DittoTeardownRegistry`
  guarding close/reopen file locks) are the Android templates.
- Conventions worth adopting repo-wide: nearest-file `AGENTS.md` rule,
  custom lint "choke point" rules (their `sync_start_choke_point` gates
  `sync.start()` to one funnel — we want the same), and the two-confirmation
  fix-verification rule (`docs/FIX_VERIFICATION_RULE.md`).
- Note: Edge Studio hand-rolls its tools UI and theming (Ditto RAL palette,
  M3 Expressive) — we deliberately differ there (official Ditto tools
  packages + Anvil), since the demo apps teach the *stock* SDK ecosystem.

**`/Users/labeaaa/Developer/mflix-mongodb-connector`** — the conventions we keep:

- Shared root `.env` (`DITTO_DATABASE_ID`, `DITTO_DEVELOPMENT_TOKEN`,
  `DITTO_SERVER_URL`), plumbed per platform (Swift: build-phase `buildEnv.sh`
  → `Generated/Env.swift`; Android: gradle → `BuildConfig`; Flutter:
  `--dart-define-from-file=../.env`; RN: `app.config.js` → `expo.extra.ditto`).
- Ditto SDK v5 init: `DittoConfig(databaseID, connect: .server(url))` →
  `Ditto.open` → auth expiration handler calling
  `auth.login(token, provider: development)` → register subscriptions →
  `sync.start()`.
- One thin access point per app (`DittoService` / `DittoRepository` /
  `DittoProvider`) — deliberately light abstraction so the SDK stays visible
  for teaching. No repository protocols, no DI frameworks.
- Store observers wired straight into the platform's native state layer
  (`@Observable`, Flows, `ChangeNotifier`, React hooks).
- Missing config is a UI state, never a crash.
- System tab observing `system:data_sync_info` + `system:indexes`, plus the
  official Ditto tools package per platform.

Ditto SDK baselines (match mflix, bump to latest stable 5.x at build time):
Swift `DittoSwift` 5.0.3 + `DittoSwiftTools` 10.0.0 · Android `ditto-kotlin`
5.1.0 + `ditto-tools-android` 6.0.0 · Flutter `ditto_live` ^5.0.3 +
`ditto_flutter_tools` ^3.0.0 · RN `@dittolive/ditto` ^5.0.3 +
`@dittolive/ditto-react-native-tools` ^2.0.0.

### 1.4 Anvil (design system)

`/Users/labeaaa/Developer/anvil` — the mobile ports are **not published to any
registry yet**, so we vendor a pinned source snapshot into this repo and
reference it by path. A refresh script re-vendors on demand; once the packages
are published we swap path refs for registry versions (tracked as a follow-up).

- **Brand identity**: citrus (lime-yellow-green) primary with **black content
  on brand fills**, violet promo tertiary, red critical; Inter for UI, IBM
  Plex Mono for code (the DQL viewer uses it), optional Kairos brand font hook.
- Semantic color API is identical on all four platforms (`background`,
  `surface`, `fillBrandPrimary`, `fill{Info,Success,Warning,Critical,Promo}`,
  `foreground*`, `border*`, `code*`…). Light/dark (+ high contrast where the
  platform exposes it).

## 2. Repo layout

```
demoapp-retail/
├── PLAN.md                     — this file
├── README.md                   — quickstart: env setup → load data → run apps
├── AGENTS.md                   — build/test commands + conventions per app
├── .env.template               — see §3.1
├── .gitignore
├── scripts/
│   ├── load_data.py            — NDJSON → Ditto Server HTTP API loader (§3)
│   ├── vendor_anvil.sh         — copies pinned Anvil ports into vendor/ (§5)
│   └── sync_benchmarks.sh      — copies benchmarks.json into shared/
├── shared/
│   └── benchmarks.json         — the 72-query catalog, bundled by every app
├── vendor/
│   └── anvil/                  — pinned snapshot (+ COMMIT file recording the
│                                 source commit hash of the anvil checkout)
├── swift/                      — SwiftUI reference app (built first)
├── android/                    — Kotlin/Compose port
├── flutter/                    — Flutter port
└── rn-expo/                    — React Native + Expo port
```

Git: `git init` at scaffold time; per branching rules, never work on `main` —
cut a feature branch before the first commit.

## 3. Data loader (`scripts/load_data.py`)

Python 3 standard library only (`urllib`, `json`, `argparse`, `concurrent.futures`),
streams NDJSON line-by-line (handles the 54 MB `order_items-full.ndjson` without
loading it into memory), zero third-party installs.

### 3.1 Configuration

Root `.env.template` gains two loader-only keys alongside the three SDK keys:

```dotenv
# Apps (SDK)
DITTO_DATABASE_ID=
DITTO_DEVELOPMENT_TOKEN=
DITTO_SERVER_URL=
# Loader (HTTP API) — portal: app → Auth → New API key (read+write);
# endpoint from "Connecting via HTTP" (may include a path segment)
DITTO_API_KEY=
DITTO_HTTP_API_URL=        # e.g. https://<host>.cloud.dittolive.app/<path>
```

The loader POSTs DQL to the Ditto Server HTTP API:

```
POST {DITTO_HTTP_API_URL}/api/v5/store/execute
Authorization: Bearer {DITTO_API_KEY}
Content-Type: application/json

{"statement": "INSERT INTO orders DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE",
 "args": {"docs": [ …batch… ]}}
```

(v5 API chosen deliberately: `DQL_STRICT_MODE=false`, nested objects behave as
MAPs — matching SDK 5.x defaults in the apps.)

### 3.2 Sizing model (decision: slice the full files)

`--size` selects an **order count**, matching the benchmark's scaling ladder:
`1k | 5k | 10k | 30k | 100k`. Slices are deterministic and keep all 8 stores
populated so the store picker always has data to sync.

> **Why stride-slicing, not front-slicing** (adversarial review M1): the
> orders file is roughly chronological (2022-12-09 → 2025-06-27), so "first N
> lines" is a *date prefix* — a 1k slice ends 2022-12-22. The benchmark's date
> literals anchor at the end of the timeline (`order_date > '2025-05-24'` → 0
> rows on every prefix slice below ~100k), and id literals like
> `order_20250115_0001` sit at line ~79,386. Prefix slices would make the Query
> Runner's headline result counts read 0 at exactly the sizes demos use.

| Collection | Slice rule |
|---|---|
| `orders` | **bucket stride**: line `i` loads iff `floor(i·N/100,000)` increments — exactly N evenly spaced picks spanning the full 2.5-year timeline at every size, all 8 stores mixed in, deterministic. (A naive "every ⌈100k/N⌉-th line" is wrong at 30k — that would pick 25,000.) Plus anchor docs: **N + a handful** of orders/customers/items that benchmark literals reference. |
| `order_items` | stream `order_items-full.ndjson`, keep rows whose `order_id` ∈ sliced order set |
| `customers` | union of `customer_id`s referenced by the sliced orders (referential integrity guaranteed; grows naturally with N) **plus the anchor customers below** |
| `stores`, `categories`, `products`, `inventory` | always in full (8 / 9 / 400 / 3,167 — small, and cross-store stock checks need every store's inventory) |

**Anchor documents are always included**, at every size: the customers, orders,
items (and emails) referenced by literals in `benchmarks.json` (e.g. the
`customers__select__by_email` customer, the `orders__select__by_id` order, the
`order_items__select__by_id` item — with its parent order pulled in so nothing
dangles). The loader derives the anchor set from `shared/benchmarks.json`,
resolving UUID literals by existence-probing the collections they actually
live in (store `rls_user_id` literals are phantoms and are reported, not
loaded), so the Query Runner's literal queries return non-zero,
comparable-ish results on every slice.

At `--size 100k` the customers union rule would silently drop the 458
customers who never order (review m7) — so **100k special-cases to the full
variant verbatim** (all 25,000 customers; ~328 K docs total).

`--full-catalog` flag: loads all 25,000 customers regardless of order count
(mirrors the real subscription design where devices hold the whole customer
directory). The Customers screen's "25 K-row directory" claim only holds with
`--full-catalog` or at 100k; smaller sizes show a proportionally growing
directory, which is the honest story.

### 3.3 Behavior

- Batched `INSERT … DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE` — idempotent
  re-runs (safe to resume after interruption). (Batch-by-array is explicitly
  supported: any `DOCUMENTS` parameter may be an array of docs, each element
  inserted separately — verified against the DQL INSERT docs.)
- Batch sized self-imposed (~1 MB body / 500 docs ceiling to start — note
  Ditto publishes no JSON statement size limit, only a 2 MB *binary* one, so
  this is our own conservative bound, tuned empirically at M0); small thread
  pool (default 4) with per-request retry and exponential backoff + jitter on
  `408`/`503`/connection errors (408/503 match the OpenAPI spec).
- Progress per collection (docs sent / total); final verification pass:
  `SELECT COUNT(*)` per collection vs expected counts, printed as a table.
- `--clear`: wipe all 7 collections via repeated `DELETE FROM <c> LIMIT 30000`
  until no mutations (portal-side reset without MongoDB).
- `--only orders,customers` etc. for targeted re-loads.
- Expect ~100 K docs to take a few minutes at these batch sizes; that's fine
  for a demo-prep script, and the throughput numbers are themselves a nice
  Big Peer data point.

### 3.4 Later, not now

- The 1 M-order `large` variant is generated on demand by
  `tools/gen-retail-data.py` in the benchmark repo; loader support can be added
  if we ever want a 1 M demo.

## 4. App blueprint (identical across all four platforms)

### 4.1 Ditto integration (mirrors mflix, retail-shaped)

1. Read the three SDK keys from the root `.env` via the platform's mechanism.
2. `DittoConfig(databaseID, connect: .server(url:))` → `Ditto.open` →
   auth expiration handler → `login(token, development)`.
3. If no store selected → **store picker** (8 stores from the `stores`
   collection, synced over an always-on shared subscription). Selection is
   persisted (UserDefaults / SharedPreferences / `shared_preferences` /
   AsyncStorage).
4. Register subscriptions — the four `subscription__*` queries from
   `benchmarks.json` **verbatim** (so the app's sync cost is literally the
   benchmark's cold-start measurement), with the store literal parameterized
   as `:storeId`, plus the remaining shared-catalog subscriptions. These
   strings stay visible at the call site (teaching-first, no query-builder
   wrappers):

```sql
-- shared catalog (registered once)
SELECT * FROM stores
SELECT * FROM categories
SELECT * FROM products
SELECT * FROM customers WHERE deleted = false          -- subscription__customers_all

-- per-store (re-registered when the store changes)
SELECT * FROM inventory   WHERE _id.store_id = :storeId AND deleted = false
SELECT * FROM orders      WHERE store_id = :storeId AND deleted = false
SELECT * FROM order_items WHERE store_id = :storeId AND deleted = false
```

5. Create the subscription-supporting indexes the benchmark prescribes
   (`CREATE INDEX IF NOT EXISTS … ON inventory (_id.store_id)`, on
   `orders (store_id, deleted)`, on `order_items (store_id, deleted)`) under
   **app-namespaced names** (`zava_*`) at startup — the mflix convention. The
   benchmark README is explicit that composite-`_id` subfield queries need an
   explicit index (the auto-`_id` index doesn't help), and without them every
   store switch re-scans 25K/50K local docs. App index names are disjoint from
   the benchmark's names so the Query Runner's `DROP INDEX` postQueries can
   never drop the app's own indexes (review m6).
6. `sync.start()`.

**Store switch flow** (a showcase interaction): cancel the three per-store
subscriptions → `EVICT … WHERE store_id != :newStore` on the per-store
collections (local-only removal — the EVICT vs DELETE distinction is a
teaching moment) → register subscriptions for the new store → sync status UI
shows the new slice arriving. Two documented caveats the screen must respect
(review m8): Ditto's sync guidance warns against changing subscriptions more
often than ~every 15 minutes (interrupts in-flight transfers) — the UI
nudges accordingly; and docs already in flight from the old subscription can
land after the EVICT, so the flow re-evicts once `system:data_sync_info`
shows the old subscription drained.

### 4.2 Screens

Tab grouping is finalized in the SwiftUI reference app and ported; the screen
inventory itself is fixed:

1. **Dashboard** — store header with live sync badge; KPI cards fed by the
   benchmark's aggregation queries: orders by status with `SUM(total)`,
   12-month revenue trend (`GROUP BY substr(order_date, 0, 7)`), low-stock
   count, top products by revenue.
2. **Orders** — list with status filter chips + "last 30 days" date-range
   filter **anchored to `max(order_date)` in the local store, not to the
   device clock** (the dataset ends 2025-06-27; a naive `now() - 30d` filter
   returns zero rows in 2026 — review Mn5); order detail = order doc + its
   items via the canonical two-query pattern (`orders` by `_id`, then
   `order_items` by `order_id`) with an inline callout that DQL v5.0 has no
   JOINs.
3. **Products (catalog)** — category chips, `base_price BETWEEN` range filter,
   SKU search; product detail shows **stock at all 8 stores**
   (`inventory WHERE _id.product_id = :id`) — the "check another location"
   story that justifies shared subscriptions.
4. **Inventory** — low-stock list (`stock_level < 5` compound with store),
   aisle lookup on the `location` MAP (`location.aisle = '3'` — the
   "find it on the shelf" pattern).
5. **Customers** — 25 K-row directory with email search (paired with the
   indexed/no-index benchmark variants as a talking point).
6. **Query Runner** — the differentiator. Bundled `shared/benchmarks.json`
   rendered as a browsable catalog (grouped by collection, `AnvilBadge` per
   category), DQL viewer in IBM Plex Mono, and **Run**: N iterations against
   the live synced store, reporting result count + mean/p95 — the benchmark's
   `preQueries`/`postQueries` (index create/drop) run once per execution
   (never per iteration), so indexed vs no-index pairs are demonstrable
   on-device. Three rules make this correct against a *live synced* store
   (adversarial review M2/M5):
   - **Store substitution**: 28 of 72 benchmarks hard-code `'store_seattle'`.
     The runner substitutes the currently selected store into `store_id` /
     `_id.store_id` literals, and the substitution is visible in the DQL
     viewer — the queries are otherwise verbatim.
   - **Mutating categories** (INSERT/UPDATE/DELETE/EVICT) are badged and sit
     behind a confirm step. The benchmark's cleanup uses `EVICT`, which is
     *local-only* — on a synced device the synthetic doc would replicate to
     Big Peer and every other demo device, and its plain-INSERT preQueries
     would then fail on repeat runs. So on synced runs the runner (a) gives
     synthetic `_id`s a per-run UUID suffix and (b) substitutes `DELETE` for
     the cleanup `EVICT` (tombstones propagate; the mesh ends clean). The UI
     copy explains both deviations — they are themselves the EVICT-vs-DELETE
     teaching moment. EVICT benchmarks keep their semantics explained, not
     executed against shared data.
   - **Result-count honesty**: with anchor documents included by the loader
     (§3.2), literal queries return non-zero at every size; counts still
     differ from published benchmark numbers on sliced datasets, which the
     screen states plainly.
7. **System & Tools** — `system:data_sync_info` sync status, `system:indexes`
   list, and the official Ditto tools package per platform; **Switch Store**
   lives here too.

### 4.3 Architecture per platform

Deliberately thin — the SDK is the star:

| | SwiftUI (reference) | Android | Flutter | RN/Expo |
|---|---|---|---|---|
| Ditto access | `actor DittoManager` + `@MainActor @Observable` app state (edge-studio pattern) | `DittoManager` Koin singleton + session object (edge-studio pattern) | `DittoProvider` (`ChangeNotifier`) | `DittoService` singleton + Context |
| State → UI | `@Environment` + `@Observable` app state | ViewModels collecting Flows (`stateIn`) | Provider + StreamBuilders | Hooks (`useOrders`, `useProducts`…) |
| Env plumbing | `buildEnv.sh` → `Generated/Env.swift` build phase | gradle reads `../.env` → `BuildConfig` | `--dart-define-from-file=../.env` | `app.config.js` → `expo.extra.ditto` |
| Tools | `DittoAllToolsMenu` | `DittoToolsViewer` | `ditto_flutter_tools` | `ditto-react-native-tools` |
| Navigation | `TabView` + `NavigationStack` | Navigation 3 + `NavigationSuiteScaffold` (rail on tablets) | `NavigationBar` + `PageView`/go_router | expo-router tabs |

### 4.4 Platform toolchains

- **Swift**: modern Xcode (16+, verified on the latest installed), **Swift 6
  language mode** (`SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`,
  `SWIFT_APPROACHABLE_CONCURRENCY = YES`), iOS 17+ deployment. SPM:
  `DittoSwift` 5.1.x, `DittoSwiftTools`, local `Anvil` package. **Swift 6 is a
  redesign, not a recompile** (review B2) — but the redesign is already proven:
  we adapt ditto-edge-studio's `DittoManager` patterns verbatim (actor
  singleton, `nonisolated` sync funnels with `Task.detached(.utility)`,
  `deliverOn:` utility queue → Sendable DTO → `dematerialize()` → MainActor
  hop → 100 ms coalescing, `DQLExecuting` seam for `[String: Any?]` args;
  see §1.3). M1's spike 3 shrinks accordingly: port those patterns into the
  retail skeleton and prove one observer + one parameterized `execute` compile
  clean before any screens are built. One open checkpoint: edge-studio does
  NOT use `DittoSwiftTools` — we do (Tools tab). If it trips strict
  concurrency, fall back to `@preconcurrency import DittoAllToolsMenu` (the
  blog's own escape valve for SDKs that predate annotations). Fonts: ship the
  **single Inter variable font** + the three real IBM Plex Mono TTFs (the
  Anvil repo's four `inter_*.ttf` are byte-identical copies of one variable
  font sharing PostScript name `Inter` — registering all four via `UIAppFonts`
  is pointless; M1 includes a visual check that medium/semibold/bold weights
  actually differentiate in SwiftUI).
- **Android**: modern toolchain — AGP 9.x, Kotlin 2.4.x, latest stable Compose
  BOM, Navigation 3, compileSdk 37, minSdk 26 (ditto-tools requirement),
  `anvil-material3` via composite build (fonts bundled by the module). Never
  mix `:anvil-cmp` and `:anvil-material3` in one app. Proven-compatible
  anchors: ditto-edge-studio ships Ditto `ditto-kotlin-android` 5.1.0 on AGP
  9.2.1 / Kotlin 2.3.21 / Gradle 9.4.1 / compileSdk 37, and mflix ships
  `ditto-kotlin` 5.1.0 on AGP 9.3.1 / Kotlin 2.4.10 — our pins sit inside that
  proven envelope. **Toolchain-skew risk** (review M1-platform): vendored
  Anvil pins AGP 8.13.2 / Kotlin 2.2.21 / CMP 1.9.3 but a composite build runs
  *one* Gradle runtime — the app's (~9.7). M0 spike 1 remains: hello-world
  Compose app consuming the trimmed vendor copy via `includeBuild`; decide
  there whether Anvil's pins ride as-is on the app's Gradle or get bumped in
  the vendored copy.
- **Flutter**: **Flutter 3.41+** (modern stable, with its bundled Dart — Anvil
  requires ≥ 3.32, so 3.41 satisfies it; Ditto's documented ceiling is
  "3.24 → 3.38+", so `ditto_live` 5.1.x + `ditto_flutter_tools` on 3.41 is an
  explicit M3 verification gate), `provider`, Anvil `path:` dep (fonts bundled
  by the package). Note: Flutter is not currently installed on this machine —
  root README prereq.
- **RN/Expo**: **Expo SDK 57** (with the RN/React versions SDK 57 bundles —
  do not pin mflix's SDK 54 / RN 0.81 / React 19; `ditto-react-native-tools`
  additionally needs its native peers `react-native-zip-archive` and
  `@dr.pogodin/react-native-fs` — mflix carries both), expo-router, Node ≥
  20.12 for `app.config.js` env loading, npm for reproducible lockfiles; Anvil
  via `file:` dep + Metro `watchFolders`/`nodeModulesPaths` tweak (documented
  in Anvil's RN example); fonts loaded with `expo-font` from the vendored
  TTFs (same single-Inter rule as Swift). Ditto-on-Expo-57 is an M4
  verification gate (upstream-validated examples top out at SDK 54-era).

## 5. Anvil vendoring (`scripts/vendor_anvil.sh`)

Copies from a local Anvil checkout (default `../../anvil`, overridable) into
`vendor/anvil/`, recording the source commit in `vendor/anvil/COMMIT`:

```
vendor/anvil/
├── swift/Anvil/            — SPM package as-is (local package ref from Xcode)
├── android/                — anvil-tokens + anvil-material3 PLUS the root
│                             build scaffolding (see below); consumed via
│                             includeBuild("../vendor/anvil/android")
├── flutter/anvil/          — pub package as-is (path: ../vendor/anvil/flutter/anvil)
├── react-native/anvil/     — npm package as-is (file: dep; ships raw TS, no build)
├── fonts/                  — Inter variable font (1 file) + IBM Plex Mono
│                             (Regular/Bold/Italic) TTFs for Swift/RN, from flutter/anvil/fonts
└── COMMIT                  — source commit hash of the anvil checkout
```

**Android vendoring must copy the root scaffolding, not just the two modules**
(review B1): the module build scripts resolve plugin/dependency aliases from
`gradle/libs.versions.toml`, need `android.useAndroidX=true` and
`android.suppressUnsupportedCompileSdk` from the root `gradle.properties`
(AGP reads that check before subproject files), and `includeBuild` dependency
substitution only works because the root `build.gradle.kts` sets
`allprojects { group = "live.ditto.anvil"; version = "0.1.0-SNAPSHOT" }`. So
the script copies `android/{build.gradle.kts,gradle.properties,settings.gradle.kts,
gradle/libs.versions.toml,anvil-tokens,anvil-material3}` with `settings.gradle.kts`
trimmed to drop `:catalog`, `:catalog-expressive`, and `:anvil-cmp` **but
keeping its `pluginManagement`/`dependencyResolutionManagement` blocks
verbatim**, and the app declares
`implementation("live.ditto.anvil:anvil-material3:0.1.0-SNAPSHOT")` so
substitution triggers. Exclusions: `local.properties` (machine-specific
`sdk.dir`, must never be committed), `**/build/`, `flutter/anvil/pubspec.lock`.

**`vendor/` is committed to git** (the packages are unpublished — the repo
must build standalone), while `.env` is gitignored with the mflix pattern
(`.env`, `.env.*`, `!.env.template`). No token regeneration is needed at
consume time (generated token files are checked in upstream); the script just
copies. When Anvil ships to pub.dev / npm / SPM registry / Maven, each app
swaps its path ref for the published version — one-line change per app,
tracked as a follow-up task.

## 6. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold + loader + **build spikes** | git init + branch, `.env.template`, Anvil vendored; **spike 1 ✅ (2026-08-30):** hello-world Compose app consumes vendored Anvil via `includeBuild` under Gradle 9.7 — required re-pinning vendored Anvil to AGP 9.3.1/Kotlin 2.4.10 (scripted in `vendor_anvil.sh`), runtime pixel-verified on emulator; **spike 2 ✅ (2026-08-30):** 500-doc batches accepted by Big Peer, zero retries; `--size 1k` end-to-end green (all counts exact), idempotent re-run confirmed, `--clear` wipes to zero, `--size 100k` soak = 328,341 docs verified in ~20 s of upload |
| M1 | **SwiftUI reference app** ✅ (2026-08-30) | Spike 3 passed (edge-studio patterns compile clean under Swift 6 strict, zero warnings, iOS **and** macOS 26); all screens + store switch + Query Runner; verified end-to-end by UI tests against the live 100k dataset (picker→Seattle→dashboard KPIs sync in; runner executes `orders__select__by_id` → exactly 1 row) + Anvil token pixel-verification in light and dark tiers + 9 unit tests. One real bug caught by testing: DQL GROUP BY projections must be group keys/aggregates only (dropped `product_name` from the top-products card — now verbatim benchmark) |
| M2 | Android port | Feature/UX parity with M1, composite-build Anvil, tablet rail/detail layouts |
| M3 | Flutter port | Feature/UX parity; **gate:** `ditto_live` 5.1.x + `ditto_flutter_tools` verified on Flutter 3.41+ (Ditto's documented ceiling is 3.38+) |
| M4 | RN/Expo port | Feature/UX parity, dev-client builds; **gate:** `@dittolive/ditto` 5.1.x + tools' native peers verified on Expo 57's RN/React |
| M5 | Polish | READMEs per app, root README quickstart (incl. Flutter/Xcode/Android Studio/Node prereqs), AGENTS.md, screenshots, `.env` docs, verify all four against one shared dataset |

**Platform plumbing checklist** — owned by every app milestone M1–M4 (review
M4): Info.plist / manifest privacy entries Ditto needs (`NSBluetoothAlwaysUsageDescription`,
`NSBluetoothPeripheralUsageDescription`, `NSLocalNetworkUsageDescription`,
`NSBonjourServices` — mflix's Info.plist is the reference; P2P transports are
on by default even in `.server` connect mode), font registration
(`UIAppFonts` / `expo-font`), signing & device-build provisioning, app
icon/splash, store-picker persistence acceptance criterion, offline/empty/
error states (first-run shows honest sync progress, not a spinner), and at
least smoke-level tests (mflix has test targets; we match that bar).

Each app gets its own README mirroring mflix's structure (prereqs, env,
run). Ports (M2–M4) are deliberate 1:1 UX translations of the SwiftUI
reference, not redesigns.

## 7. Risks & notes

- **Credentials**: the loader needs a portal API key (Auth → New API key,
  read+write — requires a portal role with "Access API keys") — separate from
  the development token the apps use. Both live in the gitignored root `.env`.
  API keys expire after max one year; `.env.template` says so, so a demo
  doesn't mysteriously 401 next year.
- **Cold-start sync cost**: at 100k, a Seattle device syncs **~101 K docs —
  ~30 MB raw NDJSON, more on-device** after CBOR/CRDT metadata and indexes
  (the benchmark README's "~93 K" is stale against its own data-stats; the
  app's unfiltered customers subscription adds the difference). That's the
  demo's headline moment (watch `system:data_sync_info` fill in) — but it
  also means first-run UX must show sync progress honestly rather than a
  spinner.
- **Query runner mutations**: mitigated by design (§4.2.6) — per-run UUID
  suffixes on synthetic `_id`s + `DELETE` substituted for the cleanup `EVICT`
  on synced runs + confirm gate. Without this, EVICT-only cleanup would leave
  synthetic docs on Big Peer that re-sync to every device and break repeat
  runs (plain-INSERT identifier conflicts).
- **Slice vs. benchmark fidelity**: stride slices keep every query non-zero at
  every size, but sliced result counts are not the published benchmark
  numbers — the runner says so on-screen. `--size 100k` is the faithful
  configuration.
- **No MongoDB**: unlike mflix there's no Atlas/connector setup — Big Peer is
  seeded purely through the HTTP API. Simpler story, fewer moving parts.
- **Anvil drift**: vendored snapshot can go stale; `vendor_anvil.sh` +
  `vendor/anvil/COMMIT` make refreshing a one-liner until packages publish.
- **iOS min version**: Anvil Swift's floor is iOS 16; we target **iOS 26**
  (user requirement: current-OS-only demo apps; also unlocks the modern `Tab`
  API). The SwiftUI app is iPhone + iPad (`TARGETED_DEVICE_FAMILY = 1,2`).
- **Verification gates carried in milestones** (cannot be settled without
  building): composite-build toolchain skew (M0 spike 1), HTTP batch
  acceptance (M0 spike 2), Swift 6 pattern port (M1 spike 3 — de-risked by
  ditto-edge-studio's proven `DittoManager` design) + `DittoSwiftTools` under
  Swift 6 (fallback: `@preconcurrency import`), Inter variable-font weight
  rendering on iOS (M1), ditto_live on Flutter 3.41 (M3), @dittolive/ditto on
  Expo 57's RN (M4).

---

*Plan adversarially reviewed 2026-08-29 (two independent reviewers, findings
verified against the benchmark data, Ditto docs, mflix sources, and Anvil
sources). All blocker/major findings are resolved inline above; minors are
noted where relevant. Subsequently cross-checked against ditto-edge-studio —
its production Swift 6 / Ditto 5.1.0 patterns are adopted as the Swift and
Android integration templates (§1.3), turning the riskiest unknown (B2) into
a port of proven code. M0 spike 1 (2026-08-30) **confirmed** the
composite-build skew as a hard failure — AGP 8.x cannot run on Gradle 9.6+
(`InternalProblems` removed) — and resolved it by re-pinning the vendored
Anvil Android modules to the app's AGP 9.3.1 / Kotlin 2.4.10 (the override is
owned by `vendor_anvil.sh`, never hand-edited); runtime-verified on an
emulator via exact Anvil token pixel values. Design note from that run:
Anvil's light-tier brand fill is `neutral950` (near-black); citrus is the
dark-tier brand fill. M0 code then passed a second adversarial review
(1 major — `--verify-only --size` discarded its expected counts; 7 minors —
all fixed inline) and gained a 44-test suite (`tests/`, stdlib unittest:
synthetic-fixture unit tests, real-dataset invariant tests that skip when the
benchmark repo is absent, hermetic shell-script tests).
