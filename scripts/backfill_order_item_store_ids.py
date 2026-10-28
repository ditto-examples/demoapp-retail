#!/usr/bin/env python3
"""Backfill ``order_items.store_id`` on an already-loaded Big Peer.

The original normalized bundle intentionally omitted this denormalized field.
The current apps use it to scope the per-store order-items subscription, so an
older Big Peer needs the field added without replacing every document or
requiring devices to reinstall.  This command derives the authoritative
order-id -> store-id mapping from the committed bundle, then issues only
id-scoped DQL UPDATE statements against ``order_items``.

Dry-run is the default.  A real write requires ``--apply`` and the usual
DITTO_API_KEY / DITTO_HTTP_API_URL entries in the root .env file.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from collections import defaultdict
from pathlib import Path

from load_data import BigPeerClient, execute_endpoint, iter_ndjson, load_config


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATASET_DIR = REPO_ROOT / "shared" / "data"
DEFAULT_BATCH_SIZE = 1_000
SAFE_ID = re.compile(r"^[a-z0-9_]+$")


class SystemCurlClient:
    """HTTP client using the operating system's TLS trust store.

    The normal ``BigPeerClient`` is preferred. This fallback is for developer
    environments where Python's CA bundle misses an enterprise TLS root while
    the system curl trust store includes it.
    """

    def __init__(self, host: str, path: str, api_key: str, max_attempts: int = 6):
        self.url = f"https://{host}{path}"
        self.api_key = api_key
        self.max_attempts = max_attempts

    def execute(self, statement: str, args: dict | None = None) -> dict:
        payload = json.dumps({"statement": statement, "args": args or {}})
        last_error = "unknown error"
        for attempt in range(1, self.max_attempts + 1):
            response = subprocess.run(
                [
                    "curl", "--silent", "--show-error", "--fail-with-body",
                    "--header", f"Authorization: Bearer {self.api_key}",
                    "--header", "Content-Type: application/json",
                    "--data", payload, self.url,
                ],
                capture_output=True,
                text=True,
            )
            if response.returncode == 0:
                try:
                    decoded = json.loads(response.stdout)
                except json.JSONDecodeError:
                    last_error = f"non-JSON response: {response.stdout[:200]!r}"
                else:
                    error = decoded.get("error", {})
                    if not error:
                        return decoded
                    raise RuntimeError(error.get("description", str(error)))
            else:
                last_error = (response.stderr + response.stdout).strip()[:400]
            if attempt < self.max_attempts:
                time.sleep(min(30.0, 0.5 * 2 ** attempt))
        raise RuntimeError(f"curl request failed after {self.max_attempts} attempts: {last_error}")


def order_item_store_ids(dataset_dir: Path) -> dict[str, list[str]]:
    """Return deterministic store -> item-id groups, validating bundle joins."""
    order_stores: dict[str, str] = {}
    for order, _ in iter_ndjson(dataset_dir / "orders.ndjson.gz"):
        order_id, store_id = order.get("_id"), order.get("store_id")
        if not isinstance(order_id, str) or not isinstance(store_id, str):
            raise ValueError(f"invalid order identity in bundle: {order!r}")
        order_stores[order_id] = store_id

    grouped: dict[str, list[str]] = defaultdict(list)
    for item, _ in iter_ndjson(dataset_dir / "order_items.ndjson.gz"):
        item_id, order_id = item.get("_id"), item.get("order_id")
        if not isinstance(item_id, str) or not isinstance(order_id, str):
            raise ValueError(f"invalid order-item identity in bundle: {item!r}")
        store_id = order_stores.get(order_id)
        if store_id is None:
            raise ValueError(f"item {item_id} refers to absent order {order_id}")
        bundled_store_id = item.get("store_id")
        if bundled_store_id is not None and bundled_store_id != store_id:
            raise ValueError(
                f"item {item_id} has store_id {bundled_store_id!r}, expected {store_id!r}"
            )
        if not SAFE_ID.fullmatch(item_id) or not SAFE_ID.fullmatch(store_id):
            raise ValueError(f"unsafe bundle id: item={item_id!r}, store={store_id!r}")
        grouped[store_id].append(item_id)

    if not grouped:
        raise ValueError(f"no order items found in {dataset_dir}")
    return dict(sorted(grouped.items()))


def batches(ids: list[str], size: int):
    for start in range(0, len(ids), size):
        yield ids[start:start + size]


def update_statement(store_id: str, item_ids: list[str]) -> str:
    """A bounded, id-scoped DQL UPDATE; values come only from validated bundle ids."""
    if not item_ids:
        raise ValueError("cannot make an empty UPDATE batch")
    if not SAFE_ID.fullmatch(store_id) or any(not SAFE_ID.fullmatch(item_id) for item_id in item_ids):
        raise ValueError("UPDATE ids must use the bundle's safe slug format")
    ids = ", ".join(f"'{item_id}'" for item_id in item_ids)
    return f"UPDATE order_items SET store_id = '{store_id}' WHERE _id IN ({ids})"


def count_from(response: dict) -> int:
    items = response.get("items", [])
    if not items:
        return 0
    count = items[0].get("count", 0)
    if not isinstance(count, int):
        raise ValueError(f"unexpected count response: {response!r}")
    return count


def verify(client, expected: dict[str, list[str]]) -> bool:
    ok = True
    for store_id, item_ids in expected.items():
        response = client.execute(
            "SELECT COUNT(*) AS count FROM order_items "
            f"WHERE store_id = '{store_id}' AND deleted = false"
        )
        actual = count_from(response)
        status = "OK" if actual == len(item_ids) else "MISMATCH"
        print(f"{store_id}: {actual}/{len(item_ids)} {status}")
        ok = ok and actual == len(item_ids)
    return ok


def make_client(system_curl: bool = False):
    cfg = load_config()
    missing = [key for key in ("DITTO_API_KEY", "DITTO_HTTP_API_URL") if not cfg.get(key)]
    if missing:
        raise SystemExit("missing root .env value(s): " + ", ".join(missing))
    host, path = execute_endpoint(cfg["DITTO_HTTP_API_URL"])
    if system_curl:
        return SystemCurlClient(host, path, cfg["DITTO_API_KEY"])
    return BigPeerClient(host, path, cfg["DITTO_API_KEY"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--apply", action="store_true", help="execute the DQL UPDATE batches")
    parser.add_argument("--verify-only", action="store_true", help="only check current Big Peer counts")
    parser.add_argument(
        "--system-curl",
        action="store_true",
        help="use the operating system TLS trust store instead of Python's",
    )
    args = parser.parse_args()

    if args.batch_size < 1 or args.batch_size > 5_000:
        parser.error("--batch-size must be between 1 and 5000")
    if args.apply and args.verify_only:
        parser.error("--apply and --verify-only cannot be combined")

    expected = order_item_store_ids(args.dataset_dir)
    total = sum(map(len, expected.values()))
    statement_count = sum((len(ids) + args.batch_size - 1) // args.batch_size
                          for ids in expected.values())
    print(f"prepared {total} order_items across {len(expected)} stores ({statement_count} UPDATE batches)")

    if not args.apply and not args.verify_only:
        print("dry run only; rerun with --apply to write, or --verify-only to inspect Big Peer")
        return

    client = make_client(system_curl=args.system_curl)
    if args.verify_only:
        raise SystemExit(0 if verify(client, expected) else 1)

    mutated = 0
    completed = 0
    for store_id, item_ids in expected.items():
        for item_batch in batches(item_ids, args.batch_size):
            result = client.execute(update_statement(store_id, item_batch))
            mutated += len(result.get("mutatedDocumentIds", []))
            completed += 1
            print(f"{completed}/{statement_count}: {store_id} ({len(item_batch)} items)")
    print(f"backfill complete: server reported {mutated} mutated document ids")
    if not verify(client, expected):
        raise SystemExit("post-backfill verification failed")


if __name__ == "__main__":
    main()
