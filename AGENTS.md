# AGENTS.md — Zava Retail demo apps

Multi-platform demo monorepo for Ditto + Microsoft's Zava DIY retail dataset.
Read [PLAN.md](PLAN.md) before making architectural decisions; it records the
locked decisions and the adversarial-review findings this repo's design
answers.

## Conventions

- **Nearest-file rule**: platform subdirectories may carry their own
  AGENTS.md (`android/AGENTS.md`, …); the closest one wins.
- **Never commit credentials**. `.env` is gitignored; `.env.template` is the
  template. The four apps read the *root* `.env`, each via its own mechanism
  (see PLAN.md §1.3).
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

## Commands

| Task | Command |
|---|---|
| Load data (full MS dataset) | `python3 scripts/load_data.py` (dry-run: `--dry-run`) |
| Reset Big Peer data | `python3 scripts/load_data.py --clear` |
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

## Dataset

The transaction data is **Microsoft's actual shipped Zava DIY dataset**
(`zava_retail_2025_07_21_postgres_rls.backup` from Microsoft's
ai-tour-26 repo, sibling checkout `../ai-tour-26-zava-diy-dataset-plus-mcp`),
transformed by `scripts/prepare_data.py` into the normalized
`retail-joins` document shape (Ditto SDK 5.1+ JOINs teach-through): 8 stores,
9 categories, 89 product types, 424 products (real names/SKUs), 50,000
customers, 3,392 inventory rows, **197,665 orders**, **414,241 order items**
— 665,828 docs total, loaded wholesale (`--size` ladder removed).

Microsoft's rows are honestly thin in places the apps/catalog exercise, so
the transform flags every non-cosmetic derivation in
`shared/data/manifest.json.synthesized_fields`: order `status` (deterministic
60/26/10/4 spread — MS has no status), order totals (`subtotal`/`item_count`
aggregated from the real line items; `total = 1.095 × subtotal`), store
`location` (real WA geography per named store, fabricated address), inventory
`location`/`last_counted` (deterministic fabrication); `order_items.store_id`
is joined back from the parent order (denormalized on purpose — per-store
item sync/evict needs the key on the item row). Ids become slugs
(`store_seattle`, `customer_40000`, `order_197663`…).

The bundled catalog stays the 96-query `retail-joins` suite, EXCEPT that
`shared/catalog_overrides.json` + `scripts/sync_benchmarks.sh` point the four
suite *literals* at real MS rows (`order_197663`, `customer_40000`,
`customer_23`, sku `HTHM001600`) and restate those entries' expected counts
for our data (1 / 1 / 12 / 1; the anchor order has 5 line items). Do not
hand-edit `shared/benchmarks.json` or `shared/data/` — regenerate via
`scripts/prepare_data.py` then `scripts/sync_benchmarks.sh`. The loader
reads `manifest.json` and stamps the fewest-orders store (Kirkland, 2,975)
with `"demo_default": true` (the apps' first-launch default — no picker).
