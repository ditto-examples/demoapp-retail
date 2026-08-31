# Zava Retail — Ditto demo apps

Demo apps for the retail benchmark dataset used in
[dql-metrics-benchmark](../dql-metrics-benchmark/benchmarks/retail) (the Zava
DIY dataset), built to show how Ditto works on each mobile platform against a
realistically large dataset.

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
2. **Load data** — pick a dataset size (order count: `1k`, `5k`, `10k`,
   `30k`, `100k`) and push the benchmark dataset into your Big Peer:

   ```sh
   python3 scripts/load_data.py --size 10k
   # dry run first if you like:  python3 scripts/load_data.py --size 10k --dry-run
   # reset the server:           python3 scripts/load_data.py --clear
   ```

   The loader reads NDJSON from the benchmark repo (override with
   `--dataset-dir`), slices deterministically so all 8 stores are populated
   at every size, and is idempotent (`ON ID CONFLICT DO UPDATE`).
3. **Run an app** — see each app's README. Pick a store on first launch; the
   device subscribes to the shared catalog plus that store's orders, items,
   and inventory, exactly like the benchmark's `subscription__*` queries.

## Repo layout

```
scripts/   data loader + Anvil vendoring + benchmark catalog sync
shared/    benchmarks.json (the 72-query catalog bundled into every app)
vendor/    Anvil design system, pinned source snapshot (committed on purpose)
swift/ android/ flutter/ rn-expo/
```

Design system: [Anvil](../anvil), vendored from source because the packages
are not yet published. Re-vendor with `scripts/vendor_anvil.sh`; the pinned
upstream commit is recorded in `vendor/anvil/COMMIT`.
