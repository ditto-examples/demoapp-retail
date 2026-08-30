#!/usr/bin/env python3
"""Load the retail benchmark dataset into Ditto Server (Big Peer) via the HTTP API.

Reads the full-variant NDJSON files from the dql-metrics-benchmark repo, slices
them deterministically by order count (stride slicing, so all 8 stores and the
full timeline are represented at every size), and batch-inserts them with
INSERT ... DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE against
POST {DITTO_HTTP_API_URL}/api/v5/store/execute (Bearer DITTO_API_KEY).

Python 3 standard library only.

Usage:
  python3 scripts/load_data.py --size 10k            # load ~10k orders
  python3 scripts/load_data.py --size 100k           # full variant verbatim
  python3 scripts/load_data.py --size 1k --dry-run   # show the plan, no HTTP
  python3 scripts/load_data.py --clear               # wipe all 7 collections
  python3 scripts/load_data.py --size 10k --only orders,order_items

See PLAN.md §3 for the design (including why stride slicing and anchor docs).
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import random
import re
import ssl
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATASET_DIR = REPO_ROOT.parent / "dql-metrics-benchmark" / "benchmarks" / "retail"
DEFAULT_BENCHMARKS = REPO_ROOT / "shared" / "benchmarks.json"

SIZES = {"1k": 1_000, "5k": 5_000, "10k": 10_000, "30k": 30_000, "100k": 100_000}
TOTAL_ORDERS = 100_000  # lines in orders-full.ndjson (see data-stats.txt)

# collection -> source file (always the full-variant files; see PLAN §3.2)
COLLECTION_FILES = {
    "stores": "stores.ndjson",
    "categories": "categories.ndjson",
    "products": "products.ndjson",
    "customers": "customers.ndjson",
    "inventory": "inventory-full.ndjson",
    "orders": "orders-full.ndjson",
    "order_items": "order_items-full.ndjson",
}
# Upload order (cosmetic; Big Peer has no FK constraints).
LOAD_ORDER = ["stores", "categories", "products", "customers", "inventory", "orders", "order_items"]
CLEAR_ORDER = ["order_items", "orders", "inventory", "customers", "products", "categories", "stores"]

ORDER_ID_RE = re.compile(r"^order_\d{8}_\d{4}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
STRING_LITERAL_RE = re.compile(r"'([^']*)'")

MAX_BATCH_DOCS = 500
MAX_BATCH_BYTES = 900_000  # self-imposed; Ditto publishes no JSON limit (PLAN §3.3)
MAX_ATTEMPTS = 6


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #

def load_config() -> dict:
    """Repo-root .env, overridden by real environment variables."""
    cfg = {}
    env_file = REPO_ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    for key in ("DITTO_API_KEY", "DITTO_HTTP_API_URL"):
        if os.environ.get(key):
            cfg[key] = os.environ[key]
    return cfg


def execute_endpoint(raw_url: str) -> tuple[str, str]:
    """Normalize the Cloud URL Endpoint -> (host, path) for HTTPS POST."""
    url = raw_url.strip().rstrip("/")
    if not url.startswith(("https://", "http://")):
        url = "https://" + url
    parts = urlsplit(url)
    path = parts.path if "/api/" in parts.path else parts.path + "/api/v5/store/execute"
    return parts.netloc, path


# --------------------------------------------------------------------------- #
# Anchor extraction (PLAN §3.2): docs that benchmark query literals reference
# --------------------------------------------------------------------------- #

def extract_anchor_literals(benchmarks_path: Path) -> tuple[set, set, set]:
    """Return (anchor_order_ids, anchor_customer_ids, anchor_emails)."""
    data = json.loads(benchmarks_path.read_text())
    literals: set[str] = set()
    for entry in data.values():
        texts = [entry.get("query", "")]
        texts += entry.get("preQueries", []) + entry.get("postQueries", [])
        for text in texts:
            literals.update(STRING_LITERAL_RE.findall(text))

    order_ids, customer_ids, emails = set(), set(), set()
    for lit in literals:
        if ORDER_ID_RE.match(lit):
            order_ids.add(lit)
        elif UUID_RE.match(lit):
            customer_ids.add(lit)  # rls_user_id UUIDs too — harmless (stores load in full)
        elif "@" in lit:
            emails.add(lit)
    return order_ids, customer_ids, emails


# --------------------------------------------------------------------------- #
# Slicing
# --------------------------------------------------------------------------- #

def iter_ndjson(path: Path):
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line), len(line)


def plan_slices(size_orders: int, dataset_dir: Path, benchmarks_path: Path,
                full_catalog: bool) -> dict:
    """Pass 1: decide exactly which docs load. Returns per-collection plan.

    orders:     stride pick — line i loads iff floor(i*N/TOTAL) != floor((i-1)*N/TOTAL)
                (exactly N evenly spaced picks spanning the full timeline),
                PLUS anchor orders and orders by anchor customers.
    customers:  union of sliced orders' customer_ids + anchor customers
                (all 25,000 at 100k or with --full-catalog).
    """
    anchor_orders, anchor_customers, anchor_emails = extract_anchor_literals(benchmarks_path)

    # Resolve email literals to customer ids (one cheap scan).
    if anchor_emails:
        for doc, _ in iter_ndjson(dataset_dir / COLLECTION_FILES["customers"]):
            if doc.get("email") in anchor_emails:
                anchor_customers.add(doc["_id"])
                anchor_emails.discard(doc.get("email"))

    order_ids: set[str] = set()
    customer_ids: set[str] = set(anchor_customers)
    prev_bucket = -1
    anchors_hit_orders: set[str] = set()
    for i, (doc, _) in enumerate(iter_ndjson(dataset_dir / COLLECTION_FILES["orders"])):
        bucket = (i * size_orders) // TOTAL_ORDERS
        on_stride = bucket != prev_bucket
        prev_bucket = bucket
        if on_stride or doc["_id"] in anchor_orders or doc.get("customer_id") in anchor_customers:
            order_ids.add(doc["_id"])
            customer_ids.add(doc["customer_id"])
            if doc["_id"] in anchor_orders:
                anchors_hit_orders.add(doc["_id"])

    plan = {
        "order_ids": order_ids,
        "customer_ids": customer_ids,
        "all_customers": full_catalog or size_orders == TOTAL_ORDERS,
        "anchors": {
            "order_literals": len(anchor_orders),
            "customer_literals": len(anchor_customers),
            "anchor_orders_found": len(anchors_hit_orders),
        },
    }
    return plan


def collection_docs(name: str, dataset_dir: Path, plan: dict):
    """Pass 2 generator: yield (doc, raw_len) for one collection per the plan."""
    path = dataset_dir / COLLECTION_FILES[name]
    if name == "orders":
        wanted = plan["order_ids"]
        for doc, n in iter_ndjson(path):
            if doc["_id"] in wanted:
                yield doc, n
    elif name == "order_items":
        wanted = plan["order_ids"]
        for doc, n in iter_ndjson(path):
            if doc["order_id"] in wanted:
                yield doc, n
    elif name == "customers":
        if plan["all_customers"]:
            yield from iter_ndjson(path)
        else:
            wanted = plan["customer_ids"]
            for doc, n in iter_ndjson(path):
                if doc["_id"] in wanted:
                    yield doc, n
    else:  # stores, categories, products, inventory: always full
        yield from iter_ndjson(path)


# --------------------------------------------------------------------------- #
# HTTP client (per-thread keep-alive connection, retry with backoff + jitter)
# --------------------------------------------------------------------------- #

class BigPeerClient:
    def __init__(self, host: str, path: str, api_key: str, max_attempts: int = MAX_ATTEMPTS):
        self.host, self.path, self.api_key = host, path, api_key
        self.max_attempts = max_attempts
        self._local = threading.local()

    def _conn(self) -> http.client.HTTPSConnection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            ctx = ssl.create_default_context()
            conn = http.client.HTTPSConnection(self.host, timeout=120, context=ctx)
            self._local.conn = conn
        return conn

    def execute(self, statement: str, args: dict | None = None) -> dict:
        body = json.dumps({"statement": statement, "args": args or {}}).encode()
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        last_err: Exception | None = None
        for attempt in range(1, self.max_attempts + 1):
            try:
                conn = self._conn()
                conn.request("POST", self.path, body=body, headers=headers)
                resp = conn.getresponse()
                payload = resp.read()
                if resp.status == 200:
                    return json.loads(payload)
                if resp.status in (400, 401, 403, 404):
                    raise FatalApiError(resp.status, payload.decode(errors="replace"))
                last_err = RetryableApiError(resp.status, payload.decode(errors="replace"))
            except (OSError, http.client.HTTPException) as exc:
                last_err = exc
            # retryable: drop the connection, back off with jitter
            self._local.conn = None
            if attempt < self.max_attempts:
                time.sleep(min(30.0, 0.5 * 2 ** attempt) + random.uniform(0, 0.5))
        raise RuntimeError(f"request failed after {self.max_attempts} attempts: {last_err}")


class RetryableApiError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:400]}")


class FatalApiError(Exception):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:800]}")


# --------------------------------------------------------------------------- #
# Load / clear / verify
# --------------------------------------------------------------------------- #

def batched(docs_iter, max_docs: int, max_bytes: int):
    batch, size = [], 0
    for doc, raw_len in docs_iter:
        batch.append(doc)
        size += raw_len
        if len(batch) >= max_docs or size >= max_bytes:
            yield batch, size
            batch, size = [], 0
    if batch:
        yield batch, size


def load_collection(client: BigPeerClient, name: str, dataset_dir: Path, plan: dict,
                    args) -> int:
    total = plan.get("expected", {}).get(name)
    statement = f"INSERT INTO {name} DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE"
    sent = 0
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        pending: dict = {}
        for batch, _size in batched(collection_docs(name, dataset_dir, plan),
                                    args.batch_docs, args.batch_bytes):
            pending[pool.submit(client.execute, statement, {"docs": batch})] = len(batch)
            if len(pending) >= args.concurrency * 4:
                sent += _collect(pending)  # frees slots, raises on failure
                _progress(name, sent, total)
        while pending:
            sent += _collect(pending)
            _progress(name, sent, total)
    print()
    return sent


def _collect(pending: dict) -> int:
    """Wait for at least one finished batch, apply results, return docs loaded."""
    from concurrent.futures import wait, FIRST_COMPLETED
    done, _ = wait(set(pending), return_when=FIRST_COMPLETED)
    count = 0
    for fut in done:
        fut.result()  # raises on failure — aborts the whole load
        count += pending.pop(fut)
    return count


def _progress(name: str, sent: int, total: int | None):
    total_s = f"/{total}" if total is not None else ""
    print(f"\r  [{name}] {sent}{total_s} docs", end="", flush=True)


def verify(client: BigPeerClient, expected: dict[str, int], only: set[str]):
    print("\nVerification (server counts vs expected):")
    ok = True
    for name in LOAD_ORDER:
        if name not in only:
            continue
        res = client.execute(f"SELECT COUNT(*) AS count FROM {name}")
        items = res.get("items") or []
        actual = list(items[0].values())[0] if items else 0
        exp = expected.get(name)
        mark = "ok" if exp is None or actual == exp else "MISMATCH"
        if mark != "ok":
            ok = False
        print(f"  {name:<12} {actual:>8}  expected {exp if exp is not None else '?':>8}  {mark}")
    return ok


def clear(client: BigPeerClient, only: set[str]):
    for name in CLEAR_ORDER:
        if name not in only:
            continue
        total = 0
        while True:
            res = client.execute(f"DELETE FROM {name} LIMIT 30000")
            n = len(res.get("mutatedDocumentIds", []))
            total += n
            print(f"[clear] {name}: deleted {n} (total {total})")
            if n == 0:
                break


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", choices=SIZES, help="order count to load")
    ap.add_argument("--full-catalog", action="store_true",
                    help="load all 25,000 customers regardless of size")
    ap.add_argument("--only", help="comma-separated collections to load/clear")
    ap.add_argument("--clear", action="store_true", help="delete all docs from all 7 collections")
    ap.add_argument("--verify-only", action="store_true", help="skip load, just run COUNT verification")
    ap.add_argument("--dry-run", action="store_true", help="compute the plan and print it; no HTTP")
    ap.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    ap.add_argument("--benchmarks", type=Path, default=DEFAULT_BENCHMARKS)
    ap.add_argument("--batch-docs", type=int, default=MAX_BATCH_DOCS)
    ap.add_argument("--batch-bytes", type=int, default=MAX_BATCH_BYTES)
    ap.add_argument("--concurrency", type=int, default=4)
    args = ap.parse_args()

    if not args.clear and not args.size and not args.verify_only:
        ap.error("one of --size, --clear, or --verify-only is required")
    only = set(args.only.split(",")) if args.only else set(LOAD_ORDER)
    unknown = only - set(LOAD_ORDER)
    if unknown:
        ap.error(f"unknown collections: {', '.join(sorted(unknown))}")

    for name in only:
        f = args.dataset_dir / COLLECTION_FILES[name]
        if not f.exists():
            ap.error(f"dataset file missing: {f}")

    # ---- plan (always computed; pure local work) ----
    plan = {}
    if args.size:
        print(f"Planning {args.size} slice from {args.dataset_dir} ...")
        plan = plan_slices(SIZES[args.size], args.dataset_dir, args.benchmarks, args.full_catalog)
        expected = {}
        for name in LOAD_ORDER:
            if name not in only:
                continue
            if name == "orders":
                expected[name] = len(plan["order_ids"])
            elif name == "customers":
                expected[name] = None if plan["all_customers"] else len(plan["customer_ids"])
                if plan["all_customers"]:
                    expected[name] = sum(1 for _ in iter_ndjson(args.dataset_dir / COLLECTION_FILES["customers"]))
            elif name == "order_items":
                expected[name] = sum(1 for _ in collection_docs("order_items", args.dataset_dir, plan))
            else:
                expected[name] = sum(1 for _ in iter_ndjson(args.dataset_dir / COLLECTION_FILES[name]))
        plan["expected"] = expected
        a = plan["anchors"]
        print(f"  anchors: {a['order_literals']} order literals, {a['customer_literals']} customer "
              f"literals ({a['anchor_orders_found']} anchor orders present in data)")

    if args.dry_run:
        if not args.size:
            ap.error("--dry-run requires --size")
        print("\nDry run — would load:")
        total_docs = 0
        for name in LOAD_ORDER:
            if name not in only:
                continue
            n = plan["expected"][name]
            total_docs += n
            est_batches = (n + args.batch_docs - 1) // args.batch_docs
            print(f"  {name:<12} {n:>8} docs  (~{est_batches} batches)")
        print(f"  {'TOTAL':<12} {total_docs:>8} docs")
        return 0

    # ---- everything below needs credentials ----
    cfg = load_config()
    missing = [k for k in ("DITTO_API_KEY", "DITTO_HTTP_API_URL") if not cfg.get(k)]
    if missing:
        print(f"error: missing {', '.join(missing)} — add to {REPO_ROOT}/.env "
              f"(see .env.template)", file=sys.stderr)
        return 2
    host, path = execute_endpoint(cfg["DITTO_HTTP_API_URL"])
    client = BigPeerClient(host, path, cfg["DITTO_API_KEY"])
    print(f"Target: https://{host}{path}")

    if args.clear:
        clear(client, only)
        return 0

    if args.verify_only:
        return 0 if verify(client, {}, only) else 1

    started = time.time()
    for name in LOAD_ORDER:
        if name not in only:
            continue
        print(f"Loading {name} ...")
        load_collection(client, name, args.dataset_dir, plan, args)
    mins = (time.time() - started) / 60
    print(f"\nLoad complete in {mins:.1f} min.")

    return 0 if verify(client, plan["expected"], only) else 1


if __name__ == "__main__":
    sys.exit(main())
