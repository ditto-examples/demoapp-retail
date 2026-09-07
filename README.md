# Zava Retail — Ditto demo apps

Demo apps running on **Microsoft's actual shipped Zava DIY dataset**
(the Postgres backup from Microsoft's
[ai-tour-26-zava-diy-dataset-plus-mcp](https://github.com/microsoft/ai-tour-26-zava-diy-dataset-plus-mcp)
repo), transformed into the **normalized, JOIN-shaped** document form (Ditto
SDK 5.1+) of the `retail-joins` benchmark catalog: orders carry no embedded
customer/store names, order items carry no store/product copies, and every
cross-collection display query is a DQL `INNER JOIN` running on-device.

The data: 8 stores, 9 categories, 89 product types, 424 products with real
Microsoft catalog names and SKUs ("Professional Claw Hammer 16oz" /
`HTHM001600`), 50,000 customers, 3,392 inventory rows, **197,665 orders**,
**414,241 order items** — 665,828 documents, loaded wholesale (no size
slicing).

Four apps, one shared blueprint — see [PLAN.md](PLAN.md) for the full design:

| App | Stack |
|---|---|
| [`swift/`](swift/) | SwiftUI, Swift 6 language mode, modern Xcode |
| [`android/`](android/) | Kotlin 2.4, Jetpack Compose, AGP 9 |
| [`flutter/`](flutter/) | Flutter 3.41+ |
| [`rn-expo/`](rn-expo/) | React Native + Expo SDK 57 |

## Quickstart

1. **Credentials** — copy `.env.template` to `.env` and fill in the values
   from the [Ditto portal](https://portal.ditto.live/). The loader needs the
   two `HTTP API` keys (API key + Cloud URL endpoint); the apps need the
   three SDK keys.
2. **Load data** — push the whole transformed Microsoft dataset into your
   Big Peer (~36 s on a free M0):

   ```sh
   python3 scripts/load_data.py
   # dry run first if you like:  python3 scripts/load_data.py --dry-run
   # reset the server:           python3 scripts/load_data.py --clear
   ```

   The loader reads the **committed gzipped bundle** in `shared/data/`
   (~17 MB, no Git LFS needed) and is idempotent (`ON ID CONFLICT DO UPDATE`).
   It stamps the store with the fewest orders — Kirkland, 2,975 — as
   `"demo_default": true`, per `shared/data/manifest.json`.

   **Verification** — after loading, the script `COUNT`s each collection on
   the server and compares against the manifest
   (`python3 scripts/load_data.py --verify-only` re-runs the check alone).
3. **Run an app** — see each app's README. First launch skips the store
   picker: the app selects the flagged store automatically (a small store so
   the first sync is quick even though Big Peer holds everything). Switching
   stores is in the Dashboard header menu or Ditto tab → Switch store. The
   device subscribes to the shared catalog
   (stores/categories/product_types/products/customers/order_items) plus that
   store's orders and inventory; per-store item filtering happens through
   JOINs because sync subscriptions can't join.

## Repo layout

```
scripts/   load_data.py (Big Peer loader) + prepare_data.py (MS backup →
           shared/data bundle) + restore_ms_backup.sh (scratch Postgres
           restore) + catalog_overrides.py + Anvil vendoring + catalog sync
shared/    benchmarks.json (the 96-query retail-JOINs catalog, literals
           patched to real MS rows via catalog_overrides.json) +
           data/*.ndjson.gz (the committed bundle + manifest.json)
vendor/    Anvil design system, pinned source snapshot (committed on purpose)
swift/ android/ flutter/ rn-expo/
```

## Data provenance

- **Everything**: Microsoft's shipped `zava_retail_2025_07_21_postgres_rls.
  backup` (restored locally via `scripts/restore_ms_backup.sh`, transformed by
  `scripts/prepare_data.py`): real names, prices, quantities, discounts. The
  pgvector embedding tables are skipped (the apps don't use them).
- **Derived from those real rows** (arithmetic inputs are all Microsoft
  data): order `subtotal` = Σ line totals, `item_count` = # line rows,
  `total` = subtotal × 1.095 (WA-style sales tax; mirrors the benchmark's
  total/subtotal relationship).
- **Documented synthetic additions** (Microsoft's schema simply has no such
  columns; deterministic per-row hash so reloads are stable, each flagged in
  `shared/data/manifest.json → synthesized_fields`): order `status` (60%
  completed / 26% pending / 10% restocked / 4% cancelled), store `location`
  (real WA city/state/zip per named store, street line fabricated),
  inventory `location` (aisle/shelf/bin) and `last_counted`.
- **Identifiers**: integer PKs become document slugs — `store_seattle`…
  (MS's store set: Seattle, Bellevue, Tacoma, Spokane, Everett, Redmond,
  Kirkland, Online), `customer_40000`, `order_197663`, `prod_1`,
  `ptype_hammers_1`, `cat_hand_tools`. Category `seasonal_multipliers` come
  from Microsoft's own `product_data.json`. `order_items.store_id` is dropped
  — items reach a store through their order (the apps' headline JOIN).
- **Catalog literals**: the suite's literal queries referenced the benchmark's
  own generated rows; `scripts/sync_benchmarks.sh` applies
  `shared/catalog_overrides.json`, pointing them at real Microsoft rows
  (order `order_197663` — Seattle, 2024-12-30, 5 items; customer
  `customer_40000`; customer `customer_23`; SKU `HTHM001600`) and restating
  those entries' expected counts. Everything else in the 96-query catalog is
  byte-identical to the suite.

Regenerate after a Microsoft backup rev:
`scripts/restore_ms_backup.sh && python3 scripts/prepare_data.py && scripts/sync_benchmarks.sh`
and commit the result (`shared/benchmarks.json`, `shared/data/`).

Design system: [Anvil](../anvil), vendored from source because the packages
are not yet published. Re-vendor with `scripts/vendor_anvil.sh`; the pinned
upstream commit is recorded in `vendor/anvil/COMMIT`.

## Load performance

Measured against a free Small Free Tier (M0) Big Peer with the defaults
(`500` docs/batch, 4 concurrent keep-alive connections, local Wi-Fi, full
665,828-doc dataset): **~36 s end-to-end (~18 K docs/s)**. Big Peer
survives monolithic `DOCUMENTS` batches well past 500 docs (10K-doc batches
transferred fine in the earlier sizing experiments), but smaller batches
parallelize far better across connections — see `PLAN.md §3.3`. Sweeps:
`--batch-docs/--batch-bytes/--concurrency`; Ditto Community Slack ditto-help
item M-01 is open if batching ever breaks.
