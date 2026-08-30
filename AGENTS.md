# AGENTS.md — Zava Retail demo apps

Multi-platform demo monorepo for Ditto + the retail benchmark dataset.
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
- **Subscriptions go through one funnel** per app (store picker →
  register/cancel); the four per-store subscription queries mirror the
  benchmark's `subscription__*` queries verbatim with `:storeId` args.

## Commands

| Task | Command |
|---|---|
| Load data | `python3 scripts/load_data.py --size 10k` (dry-run: `--dry-run`) |
| Reset Big Peer data | `python3 scripts/load_data.py --clear` |
| Re-vendor Anvil | `scripts/vendor_anvil.sh` |
| Re-sync benchmark catalog | `scripts/sync_benchmarks.sh` |
| Run tests | `python3 -m unittest discover -s tests -v` |
| Android build | `cd android && ./gradlew :app:assembleDebug` |

## Dataset

Source of truth: `../dql-metrics-benchmark/benchmarks/retail` (NDJSON +
`benchmarks.json`). The loader slices the *full-variant* files by order-count
stride (1k/5k/10k/30k/100k) so all 8 stores are populated at every size, and
always includes the anchor documents that benchmark query literals reference.
Do not hand-edit `shared/benchmarks.json` — regenerate via
`scripts/sync_benchmarks.sh`.
