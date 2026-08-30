#!/usr/bin/env bash
# Copy the retail benchmark query catalog into shared/ for bundling into the
# apps, per PLAN.md §1.2. Never hand-edit shared/benchmarks.json.
#
#   scripts/sync_benchmarks.sh [BENCHMARK_REPO_DIR]  (default: ../../dql-metrics-benchmark)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="${1:-${BENCHMARK_DIR:-$REPO_ROOT/../dql-metrics-benchmark}}"
SRC="$BENCH_DIR/benchmarks/retail/benchmarks.json"
DEST_DIR="$REPO_ROOT/shared"

if [[ ! -f "$SRC" ]]; then
  echo "error: benchmark catalog not found at $SRC" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/benchmarks.json"
{
  echo "source: $SRC"
  echo "commit: $(git -C "$BENCH_DIR" rev-parse HEAD 2>/dev/null || echo 'unknown')"
  echo "synced_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST_DIR/COMMIT"

python3 -c "
import json
d = json.load(open('$DEST_DIR/benchmarks.json'))
print(f'shared/benchmarks.json: {len(d)} benchmarks synced')
"
