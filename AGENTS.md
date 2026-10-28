# AGENTS.md — Ditto Retail demo apps

Multi-platform demo monorepo for Ditto + Microsoft's Zava DIY retail dataset.
(The dataset keeps the *Zava* name; the apps present as **Ditto Retail**.)
Read [PLAN.md](PLAN.md) before making architectural decisions; it records the
locked decisions and the adversarial-review findings this repo's design
answers. Human-facing docs: [README.md](README.md) + the per-platform
READMEs (`swift/`, `android/`, `flutter/`).

## Conventions

- **Nearest-file rule**: platform subdirectories carry their own AGENTS.md
  (`android/AGENTS.md`, …); the closest one wins.
- **Never commit credentials**. `.env` is gitignored; `.env.template` is the
  template. The apps read the *root* `.env`, each via its own mechanism
  (see "How a build works" below).
- **`vendor/` is committed** (Anvil is unpublished). Refresh with
  `scripts/vendor_anvil.sh`; never hand-edit vendored files.
- **Ditto integration stays visible**: one thin access point per app
  (DittoManager/Provider/Service), DQL strings at the call site, no
  repository-protocol towers. These apps teach the SDK.
- **Fix verification**: a finding needs two independent confirmations before
  it's called fixed; "it compiles" is not verification.
- **Subscriptions go through one funnel** per app (store selection →
  register/cancel). The dataset is the normalized retail-joins shape with one
  deliberate denormalization: sync subscriptions reject JOINs **and
  subqueries** (validated 2026-09-08 in ditto-core + on-device), so
  `order_items.store_id` is denormalized from the parent order and the
  per-store subscriptions are `inventory`/`orders`/`order_items` by
  `:storeId` (the shared tier is catalog + customers). Per-store JOIN
  filtering in screens stays as the canonical teaching shape.
- **Data bundle is committed**: `shared/data/*.ndjson.gz` (~17 MB, no LFS) —
  regenerate with `scripts/prepare_data.py` (needs the restored MS backup,
  `scripts/restore_ms_backup.sh`); never hand-edit.

## How a build works (setup end to end)

**1. One root `.env`** (gitignored; template `.env.template`) with five keys:
SDK — `DITTO_DATABASE_ID`, `DITTO_DEVELOPMENT_TOKEN`, `DITTO_SERVER_URL`;
loader — `DITTO_API_KEY`, `DITTO_HTTP_API_URL`. Each platform injects it
differently:

| Platform | Mechanism | Re-read when |
|---|---|---|
| Android | `app/build.gradle.kts` reads `../.env` → `BuildConfig` | rebuild |
| Swift | `swift/buildEnv.sh ../.env Generated` → `Generated/Env.swift` (gitignored) | `make setup` |
| Flutter | `--dart-define-from-file=../.env` (`String.fromEnvironment`) | every build/run |

**2. Seed data**: `python3 scripts/load_data.py` pushes the committed bundle
to your Big Peer. Apps then sync; without a seeded Big Peer they sit at
"waiting for the store catalog" — expected, not a bug.

**3. Generated artifacts — never hand-edit, regenerate:**

| Artifact | Regenerate with |
|---|---|
| `swift/ZavaRetail.xcodeproj/project.pbxproj` | `cd swift && xcodegen` (or `make setup`) |
| `swift/Generated/Env.swift` | `cd swift && ./buildEnv.sh ../.env Generated` |
| `flutter/pubspec.lock`, `flutter/ios/Podfile.lock` | `pub get` / `pod update DittoFlutter --repo-update` |
| `flutter/assets/benchmarks.json` (symlink → `shared/`) | `scripts/sync_benchmarks.sh` |
| `shared/data/*.ndjson.gz` | `scripts/prepare_data.py` (needs `restore_ms_backup.sh`) |
| `vendor/anvil/**` | `scripts/vendor_anvil.sh` |

**4. Bumping the Ditto SDK** — all three floors are ≥ 5.2.0 (bumped
2026-10-27; companion tools unchanged: `ditto-tools-android` 6.0.0,
`DittoSwiftTools` 10.0.0, `ditto_flutter_tools` 3.0.0):

| Platform | Pin lives in | Gotcha |
|---|---|---|
| Android | `android/gradle/libs.versions.toml`: `ditto = { strictly = "5.2.0", require = "[5.2.0,6.0.0)", prefer = "5.2.0" }` | `prefer` alone loses to ditto-tools' hard request and silently resolves to the range floor — verify with `./gradlew :app:dependencyInsight --dependency ditto-kotlin --configuration debugRuntimeClasspath` |
| Swift | `swift/project.yml`: `DittoSwiftPackage: from: 5.2.0` | re-resolve and commit `Package.resolved` |
| Flutter | `flutter/pubspec.yaml`: `ditto_live: ^5.2.0` | `pub get` + `pod update DittoFlutter --repo-update` |

**5. App identity — don't rename the wrong things.** Display name is
"Ditto Retail" (Android `android:label`, iOS `PRODUCT_NAME: DittoRetail`,
Flutter `MaterialApp.title`). Identifiers stay: Swift module/target/scheme/
folders `ZavaRetail`, Android `applicationId`/iOS bundle id `live.ditto.zava`,
Flutter package `zava_retail`. In `swift/project.yml`, `PRODUCT_NAME`,
`PRODUCT_MODULE_NAME` (keeps `@testable import ZavaRetail` working) and the
test targets' `TEST_HOST` must change **together**.

**6. Local Big Peer over LAN**: Android blocks cleartext, so the host in
`.env` must be listed in `android/app/src/main/res/xml/network_security_config.xml`
(no CIDR support — hosts are listed individually; iOS/macOS need no change).

## Commands

| Task | Command |
|---|---|
| Load data (full MS dataset) | `python3 scripts/load_data.py` (dry-run: `--dry-run`) |
| Replace Big Peer data with the committed bundle | `python3 scripts/load_data.py --replace` (wipe only: `--clear`) |
| Restore MS backup (scratch container) | `scripts/restore_ms_backup.sh` |
| Rebuild data bundle | `python3 scripts/prepare_data.py` (then re-run sync_benchmarks.sh) |
| Re-vendor Anvil | `scripts/vendor_anvil.sh` |
| Re-sync benchmark catalog | `scripts/sync_benchmarks.sh` |
| Run tests | `python3 -m unittest discover -s tests -v` |
| Android build | `cd android && ./gradlew :app:assembleDebug` |
| Swift project regen | `cd swift && make setup` (buildEnv.sh + xcodegen) |
| Swift build (iOS sim) | `cd swift && xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` |
| Swift tests | same + `-only-testing:ZavaRetailTests test` / `-only-testing:ZavaRetailUITests test` |
| Flutter (fvm-pinned 3.47.0) | `cd flutter && fvm flutter analyze` / `fvm flutter test` / `fvm flutter run -d <device> --dart-define-from-file=../.env` |

## Dataset (details in PLAN.md §1.2)

Microsoft's shipped Zava DIY dataset (665,828 docs: 8 stores, 424 products,
50,000 customers, 197,665 orders, 414,241 order items) transformed by
`scripts/prepare_data.py` into the normalized `retail-joins` shape. Every
non-cosmetic derivation is flagged in `shared/data/manifest.json →
synthesized_fields` (order `status`, order totals, store/inventory
`location`); `order_items.store_id` is denormalized on purpose (sync
subscriptions reject JOINs/subqueries). Ids become slugs (`store_seattle`,
`customer_40000`, `order_197663`…). The bundled catalog stays the 96-query
`retail-joins` suite except that `shared/catalog_overrides.json` +
`scripts/sync_benchmarks.sh` point its four *literals* at real MS rows and
restate those expected counts. Never hand-edit `shared/benchmarks.json` or
`shared/data/`. The loader stamps the fewest-orders store (Kirkland, 2,975)
with `"demo_default": true` — the apps' first-launch default (no picker).
