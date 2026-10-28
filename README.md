# Ditto Retail — cross-platform Ditto demo apps

**Ditto Retail** shows what a real [Ditto](https://ditto.live/) app looks like:
one store-associate retail app, built three ways (SwiftUI, Jetpack Compose,
Flutter), all syncing the same dataset through Ditto.

The headline feature on display is **DQL `INNER JOIN`s running on-device**.
The data is stored normalized — orders carry customer *ids*, order items carry
product *ids* — and every screen that shows a name, SKU, or price gets it from
a live join query instead of a denormalized copy. If you're evaluating Ditto
for an app with relational-shaped data, this repo is the reference.

## Where the data comes from

The dataset is Microsoft's real, shipped **Zava DIY retail sample** — the
Postgres backup from Microsoft's
[ai-tour-26-zava-diy-dataset-plus-mcp](https://github.com/microsoft/ai-tour-26-zava-diy-dataset-plus-mcp)
repo — transformed into Ditto documents. No synthetic filler: real product
names and SKUs ("Professional Claw Hammer 16oz" / `HTHM001600`), real prices,
real quantities.

You're a store associate at **Zava**, a fictional Pacific-Northwest DIY
hardware chain. The app opens on one of 8 stores and syncs only what that
store needs — the shared catalog plus that store's orders, inventory, and
order items — demonstrating Ditto's partial replication on a dataset with
real-world shape:

- **8 stores** (Seattle, Bellevue, Tacoma, Spokane, Everett, Redmond,
  Kirkland, Online)
- **424 products** across 9 categories and 89 product types
- **50,000 customers**
- **197,665 orders** with **414,241 order items** and 3,392 inventory rows
  — 665,828 documents total

The handful of fields Microsoft's schema doesn't have (order status, aisle
locations) are derived deterministically and documented in
`shared/data/manifest.json`. Full provenance details are at the bottom of
this file.

## The apps

Same blueprint, same screens, same queries — pick your stack:

| App | Stack | Build guide |
|---|---|---|
| [`swift/`](swift/) | SwiftUI, Swift 6 language mode, iOS/iPadOS/macOS | [swift/README.md](swift/README.md) |
| [`android/`](android/) | Kotlin 2.4, Jetpack Compose, AGP 9 | [android/README.md](android/README.md) |
| [`flutter/`](flutter/) | Flutter 3.41+ (fvm-pinned) | [flutter/README.md](flutter/README.md) |

Each app keeps its Ditto integration visible and teachable: one thin access
point, DQL strings at the call site, and info sheets in the UI that explain
the query running under every screen.

## Quickstart

### 1. Get a Ditto account and a database

You need a Ditto Portal account and a database (the portal calls them
*apps*; a Database ID is the tenant your data lives in):

1. **Create an account** — [Creating a Ditto Account](https://docs.ditto.live/cloud/portal/creating-a-ditto-account)
   (email + password, or Google SSO; optional MFA). Sign in at
   [portal.ditto.live](https://portal.ditto.live/).
2. **Create a database** — [Creating a New Database](https://docs.ditto.live/cloud/portal/creating-a-new-app):
   create an organization, then "Let's Create a Database!" → name + slug →
   visibility → **Create Database**. Free tiers have a fixed cap on the
   number of databases.
3. **Copy your connection details** — [Getting SDK Connection Details](https://docs.ditto.live/cloud/portal/getting-sdk-connection-details):
   select the database, open the **Connect** tab, and you'll see the
   **Database ID**, **Auth URL** and **Websocket URL** under *Big peer
   connection information*, plus the **Online Playground Authentication
   Token** under *Authentication Mode* (fine for demos — it lets you explore
   Ditto without wiring up your own auth).

### 2. Create your `.env`

The apps and the data loader read a single `.env` at the **repository root**
(gitignored — never commit it). Copy the template:

```sh
cp .env.template .env
```

Then fill in five values from the database you just created:

| Key | Where to find it | Used by |
|---|---|---|
| `DITTO_DATABASE_ID` | Portal → your database → **Connect** → Database ID | Apps (SDK) |
| `DITTO_DEVELOPMENT_TOKEN` | Portal → your database → **Connect** → Online Playground Authentication Token | Apps (SDK) |
| `DITTO_SERVER_URL` | Portal → your database → **Connect** → Websocket URL | Apps (SDK) |
| `DITTO_API_KEY` | Portal → your database → **Auth** → New API key (read+write) | Data loader |
| `DITTO_HTTP_API_URL` | Portal → your database → **Connecting via HTTP** → Cloud URL Endpoint | Data loader |

Only the first three are needed to *build and run* an app — but without data
to sync, the apps will sit at "waiting for the store catalog". Seed your Big
Peer in step 3.

### 3. Load the data

Push the full transformed Microsoft dataset into your Big Peer (~36 s on a
free M0):

```sh
python3 scripts/load_data.py
# dry run first if you like:  python3 scripts/load_data.py --dry-run
# replace an older bundle:    python3 scripts/load_data.py --replace
# wipe without loading:       python3 scripts/load_data.py --clear
```

The loader reads the **committed gzipped bundle** in `shared/data/` (~17 MB,
no Git LFS needed), is idempotent (`ON ID CONFLICT DO UPDATE`), and refuses to
merge into a mismatched dataset (use `--replace` for that). Afterwards it
`COUNT`s each collection on the server and verifies against the manifest
(`--verify-only` re-runs just the check).

### 4. Run an app

Follow the build guide for your platform (table above). First launch skips
the store picker: the app auto-selects Kirkland (the smallest store, 2,975
orders — flagged `"demo_default": true` in the data) so the first sync is
quick even though Big Peer holds everything. Switch stores from the Dashboard
header menu or Ditto tab → Switch store; the device subscribes to the shared
catalog (stores/categories/product types/products/customers) plus the
selected store's orders, inventory, and order items.

## Repo layout

```
scripts/   load_data.py (Big Peer loader) + prepare_data.py (MS backup →
           shared/data bundle) + restore_ms_backup.sh (scratch Postgres
           restore) + catalog_overrides + Anvil vendoring + catalog sync
shared/    benchmarks.json (the 96-query retail-JOINs catalog shipped in
           each app, literals patched to real MS rows) + data/*.ndjson.gz
           (the committed bundle + manifest.json)
vendor/    Anvil design system, pinned source snapshot (committed on purpose)
swift/ android/ flutter/
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
  from Microsoft's own `product_data.json`. `order_items.store_id` is joined
  back from the parent order — the one deliberate denormalization, because
  sync subscriptions reject JOINs (and subqueries), so per-store item
  sync/evict needs the store key on the item row itself.
- **Catalog literals**: the bundled 96-query benchmark suite's literal
  queries referenced the benchmark's own generated rows;
  `scripts/sync_benchmarks.sh` applies `shared/catalog_overrides.json`,
  pointing them at real Microsoft rows (order `order_197663` — Seattle,
  2024-12-30, 5 items; customer `customer_40000`; customer `customer_23`;
  SKU `HTHM001600`) and restating those entries' expected counts. Everything
  else in the catalog is byte-identical to the suite.

Regenerate after a Microsoft backup rev:
`scripts/restore_ms_backup.sh && python3 scripts/prepare_data.py && scripts/sync_benchmarks.sh`
and commit the result (`shared/benchmarks.json`, `shared/data/`).

Design system: [Anvil](vendor/anvil), vendored from source because the
packages are not yet published. Re-vendor with `scripts/vendor_anvil.sh`; the
pinned upstream commit is recorded in `vendor/anvil/COMMIT`.

## Load performance

Measured against a free Small Free Tier (M0) Big Peer with the defaults
(`500` docs/batch, 4 concurrent keep-alive connections, local Wi-Fi, full
665,828-doc dataset): **~36 s end-to-end (~18 K docs/s)**. Big Peer
survives monolithic `DOCUMENTS` batches well past 500 docs (10K-doc batches
transferred fine in the earlier sizing experiments), but smaller batches
parallelize far better across connections — see `PLAN.md §3.3`. Sweeps:
`--batch-docs/--batch-bytes/--concurrency`; Ditto Community Slack ditto-help
item M-01 is open if batching ever breaks.
