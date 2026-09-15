#!/usr/bin/env bash
# Restore Microsoft's shipped Zava dataset into a scratch Postgres container
# for scripts/prepare_data.py. Idempotent: safe to re-run.
#
#   scripts/restore_ms_backup.sh [MS_REPO_DIR] [CONTAINER_NAME]
#
# Defaults: ../ai-tour-26-zava-diy-dataset-plus-mcp and zava-restore.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MS_REPO="${1:-${MS_DATASET_DIR:-$REPO_ROOT/../ai-tour-26-zava-diy-dataset-plus-mcp}}"
CONTAINER="${2:-zava-restore}"
BACKUP="$MS_REPO/data/zava_retail_2025_07_21_postgres_rls.backup"

if [[ ! -f "$BACKUP" ]]; then
  echo "error: Microsoft backup not found at $BACKUP" >&2
  exit 1
fi

ENGINE="$(command -v podman || command -v docker || true)"
if [[ -z "$ENGINE" ]]; then
  echo "error: need podman or docker" >&2
  exit 1
fi

# podman machines may be stopped between sessions.
if [[ "$(basename "$ENGINE")" == "podman" ]]; then
  "$ENGINE" machine start >/dev/null 2>&1 || true
fi

if ! "$ENGINE" inspect "$CONTAINER" >/dev/null 2>&1; then
  "$ENGINE" run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=dev \
    pgvector/pgvector:pg17 >/dev/null
fi
if [[ "$("$ENGINE" inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]]; then
  "$ENGINE" start "$CONTAINER" >/dev/null
fi

"$ENGINE" cp "$BACKUP" "$CONTAINER:/tmp/zava.backup"
"$ENGINE" exec "$CONTAINER" psql -U postgres -c "DROP DATABASE IF EXISTS zava" >/dev/null
"$ENGINE" exec "$CONTAINER" psql -U postgres -c "CREATE DATABASE zava" >/dev/null
"$ENGINE" exec "$CONTAINER" pg_restore -U postgres -d zava --no-owner --no-privileges /tmp/zava.backup

"$ENGINE" exec "$CONTAINER" psql -U postgres -d zava -c \
  "SELECT 'stores' t, COUNT(*) FROM retail.stores
   UNION ALL SELECT 'products', COUNT(*) FROM retail.products
   UNION ALL SELECT 'customers', COUNT(*) FROM retail.customers
   UNION ALL SELECT 'orders', COUNT(*) FROM retail.orders
   UNION ALL SELECT 'order_items', COUNT(*) FROM retail.order_items ORDER BY 1"
echo "restored: $BACKUP → container '$CONTAINER', database zava"
