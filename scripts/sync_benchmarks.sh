#!/usr/bin/env bash
# Copy the retail-joins benchmark query catalog (DQL JOIN shape, Ditto SDK
# 5.1+) into shared/ for bundling into the apps, per PLAN.md §1.2. Never
# hand-edit shared/benchmarks.json.
#
#   scripts/sync_benchmarks.sh [BENCHMARK_REPO_DIR]  (default: ../../dql-metrics-benchmark)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="${1:-${BENCHMARK_DIR:-$REPO_ROOT/../dql-metrics-benchmark}}"
SRC="$BENCH_DIR/benchmarks/retail-joins/benchmarks.json"
DEST_DIR="$REPO_ROOT/shared"

if [[ ! -f "$SRC" ]]; then
  echo "error: benchmark catalog not found at $SRC" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/benchmarks.json"

# Point the suite's literal queries at REAL Microsoft data (our apps load the
# shipped Zava backup, not the benchmark's generated rows) and restate
# expected counts for the patched entries. See shared/catalog_overrides.json.
if [[ -f "$DEST_DIR/catalog_overrides.json" ]]; then
  python3 "$REPO_ROOT/scripts/catalog_overrides.py" \
    "$DEST_DIR/benchmarks.json" "$DEST_DIR/catalog_overrides.json" "$DEST_DIR/data"
fi

{
  echo "source: $SRC"
  echo "commit: $(git -C "$BENCH_DIR" rev-parse HEAD 2>/dev/null || echo 'unknown')"
  echo "synced_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST_DIR/COMMIT"

BENCH_OUT="$DEST_DIR/benchmarks.json" python3 - <<'PYEOF'
import json, os, sys
path = os.environ["BENCH_OUT"]
d = json.load(open(path))
if not isinstance(d, dict) or not d:
    sys.exit(f"error: {path} is not a non-empty benchmark catalog")
print(f"shared/benchmarks.json: {len(d)} benchmarks synced")
PYEOF
