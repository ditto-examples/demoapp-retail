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
    """Normalize the Cloud URL Endpoint -> (host, path) for an HTTPS POST.

    Accepts the portal value with or without scheme (any case), with or
    without a trailing slash, and with or without the /api/... path. Scheme is
    always forced to https (BigPeerClient only speaks HTTPS).
    """
    url = re.sub(r"^https?://", "", raw_url.strip(), flags=re.IGNORECASE).rstrip("/")
    parts = urlsplit("https://" + url)
    path = parts.path if "/api/v" in parts.path else parts.path + "/api/v5/store/execute"
    return parts.netloc, path


# --------------------------------------------------------------------------- #
# Anchor extraction (PLAN §3.2): docs that benchmark query literals reference
# --------------------------------------------------------------------------- #

def extract_anchor_literals(benchmarks_path: Path) -> tuple[set, set, set]:
    """Return (anchor_order_ids, uuid_literals, anchor_emails).

    UUID literals are returned UNRESOLVED: they may be customer ids, order_item
    ids, or phantoms (e.g. stores.rls_user_id literals, which name no document
    we load). plan_slices resolves them by existence-probing the collections.
    """
    data = json.loads(benchmarks_path.read_text())
    literals: set[str] = set()
    for entry in data.values():
        texts = [entry.get("query", "")]
        texts += entry.get("preQueries", []) + entry.get("postQueries", [])
        for text in texts:
            literals.update(STRING_LITERAL_RE.findall(text))

    order_ids, uuids, emails = set(), set(), set()
    for lit in literals:
        if ORDER_ID_RE.match(lit):
            order_ids.add(lit)
        elif UUID_RE.match(lit):
            uuids.add(lit)
        elif "@" in lit:
            emails.add(lit)
    return order_ids, uuids, emails


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
                full_catalog: bool, total_orders: int = TOTAL_ORDERS) -> dict:
    """Pass 1: decide exactly which docs load. Returns per-collection plan.

    orders:     stride pick — line i loads iff floor(i*N/TOTAL) != floor((i-1)*N/TOTAL)
                (exactly N evenly spaced picks spanning the full timeline),
                PLUS anchor orders and orders by anchor customers.
    order_items: rows whose order is in the slice, PLUS anchor items (with
                their parent orders pulled into the slice so an anchored item
                never dangles).
    customers:  union of sliced orders' customer_ids + anchor customers
                (all 25,000 at 100k or with --full-catalog).
    """
    anchor_orders, uuid_literals, anchor_emails = extract_anchor_literals(benchmarks_path)

    # One customers scan resolves email literals AND customer-id UUID literals.
    anchor_customers: set[str] = set()
    for doc, _ in iter_ndjson(dataset_dir / COLLECTION_FILES["customers"]):
        if doc["_id"] in uuid_literals or doc.get("email") in anchor_emails:
            anchor_customers.add(doc["_id"])
    unresolved = uuid_literals - anchor_customers

    # Remaining UUID literals may be order_item ids (e.g. order_items__select__by_id).
    # Existence-probe items and pull their parent orders into the anchor set.
    anchor_items: set[str] = set()
    if unresolved:
        for doc, _ in iter_ndjson(dataset_dir / COLLECTION_FILES["order_items"]):
            if doc["_id"] in unresolved:
                anchor_items.add(doc["_id"])
                anchor_orders.add(doc["order_id"])
        unresolved -= anchor_items
    phantoms = unresolved  # e.g. stores.rls_user_id literals — expected, not loaded

    order_ids: set[str] = set()
    customer_ids: set[str] = set(anchor_customers)
    prev_bucket = -1
    anchors_hit_orders: set[str] = set()
    for i, (doc, _) in enumerate(iter_ndjson(dataset_dir / COLLECTION_FILES["orders"])):
        bucket = (i * size_orders) // total_orders
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
        "item_ids": anchor_items,
        "all_customers": full_catalog or size_orders >= total_orders,
        "anchors": {
            "order_literals": len(anchor_orders),
            "customer_literals": len(anchor_customers),
            "item_literals": len(anchor_items),
            "phantom_literals": len(phantoms),
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
        wanted_orders = plan["order_ids"]
        wanted_items = plan.get("item_ids", set())
        for doc, n in iter_ndjson(path):
            if doc["order_id"] in wanted_orders or doc["_id"] in wanted_items:
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
    """Minimal /api/v5/store/execute client.

    conn_factory and sleep are injectable for tests. Retry matrix:
    - retry: 408/425/429, any 5xx, network/timeout errors, 200-with-non-JSON
      (proxy blips), and anything else unknown (bounded by max_attempts)
    - fail fast: 400/401/403/404/413/422 (the request itself is wrong)
    """

    FATAL_STATUSES = {400, 401, 403, 404, 413, 422}
    RETRYABLE_STATUSES = {408, 425, 429}

    def __init__(self, host: str, path: str, api_key: str, max_attempts: int = MAX_ATTEMPTS,
                 conn_factory=None, sleep=time.sleep):
        self.host, self.path, self.api_key = host, path, api_key
        self.max_attempts = max_attempts
        self._conn_factory = conn_factory
        self._sleep = sleep
        self._local = threading.local()

    def _conn(self):
        conn = getattr(self._local, "conn", None)
        if conn is None:
            if self._conn_factory is not None:
                conn = self._conn_factory()
            else:
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
            except (OSError, http.client.HTTPException) as exc:
                last_err = exc
            else:
                if resp.status == 200:
                    try:
                        return json.loads(payload)
                    except json.JSONDecodeError:
                        last_err = RetryableApiError(resp.status,
                                                     f"non-JSON 200 body: {payload[:200]!r}")
                elif resp.status in self.FATAL_STATUSES:
                    raise FatalApiError(resp.status, payload.decode(errors="replace"))
                else:
                    # RETRYABLE_STATUSES, 5xx, 3xx, and anything unexpected —
                    # bounded by max_attempts.
                    last_err = RetryableApiError(resp.status, payload.decode(errors="replace"))
            # retryable path: drop the connection, back off with jitter
            self._local.conn = None
            if attempt < self.max_attempts:
                self._sleep(min(30.0, 0.5 * 2 ** attempt) + random.uniform(0, 0.5))
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
    """Yield (batch, approx_bytes) staying UNDER both caps, except that a
    single doc larger than max_bytes ships alone (caps are self-imposed —
    Ditto publishes no JSON body limit). raw_len counts NDJSON characters;
    that equals bytes for this pure-ASCII dataset and excludes the JSON
    envelope, so the true body has modest headroom under the cap."""
    batch, size = [], 0
    for doc, raw_len in docs_iter:
        if batch and (len(batch) >= max_docs or size + raw_len > max_bytes):
            yield batch, size
            batch, size = [], 0
        batch.append(doc)
        size += raw_len
    if batch:
        yield batch, size


def load_collection(client: BigPeerClient, name: str, dataset_dir: Path, plan: dict,
                    args) -> int:
    total = plan.get("expected", {}).get(name)
    statement = f"INSERT INTO {name} DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE"
    sent = 0
    pool = ThreadPoolExecutor(max_workers=args.concurrency)
    pending: dict = {}
    try:
        for batch, _size in batched(collection_docs(name, dataset_dir, plan),
                                    args.batch_docs, args.batch_bytes):
            pending[pool.submit(client.execute, statement, {"docs": batch})] = len(batch)
            if len(pending) >= args.concurrency * 4:
                sent += _collect(pending)  # frees slots, raises on failure
                _progress(name, sent, total)
        while pending:
            sent += _collect(pending)
            _progress(name, sent, total)
        pool.shutdown(wait=True)
    except BaseException:
        # A failed batch (or Ctrl-C) must not freeze the run behind a pool of
        # retrying futures: cancel everything queued, then wait only for what
        # is already in flight (bounded by the 120 s request timeout).
        print(f"\n  [{name}] aborting — cancelling {len(pending)} queued batch(es); "
              f"in-flight ones unwind within one request timeout", file=sys.stderr)
        pool.shutdown(wait=False, cancel_futures=True)
        pool.shutdown(wait=True)
        raise
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

def positive_int(value: str) -> int:
    iv = int(value)
    if iv < 1:
        raise argparse.ArgumentTypeError(f"must be a positive integer, got {value!r}")
    return iv


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size", choices=SIZES,
                    help="order count to load (plus a few benchmark anchor docs)")
    ap.add_argument("--full-catalog", action="store_true",
                    help="load all 25,000 customers regardless of size")
    ap.add_argument("--only", help="comma-separated collections to load/clear")
    ap.add_argument("--clear", action="store_true", help="delete all docs from all 7 collections")
    ap.add_argument("--verify-only", action="store_true",
                    help="skip load, just run COUNT verification (with --size: against the plan's expected counts)")
    ap.add_argument("--dry-run", action="store_true", help="compute the plan and print it; no HTTP")
    ap.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    ap.add_argument("--benchmarks", type=Path, default=DEFAULT_BENCHMARKS)
    ap.add_argument("--batch-docs", type=positive_int, default=MAX_BATCH_DOCS)
    ap.add_argument("--batch-bytes", type=positive_int, default=MAX_BATCH_BYTES)
    ap.add_argument("--concurrency", type=positive_int, default=4)
    ap.add_argument("--total-orders", type=positive_int, default=TOTAL_ORDERS,
                    help="lines in orders-full.ndjson — override if the dataset is regenerated")
    args = ap.parse_args()

    if not args.clear and not args.size and not args.verify_only:
        ap.error("one of --size, --clear, or --verify-only is required")
    if args.clear and (args.size or args.verify_only or args.dry_run):
        ap.error("--clear cannot be combined with --size/--verify-only/--dry-run")
    if args.dry_run and not args.size:
        ap.error("--dry-run requires --size")

    only = {c.strip() for c in args.only.split(",") if c.strip()} if args.only else set(LOAD_ORDER)
    unknown = only - set(LOAD_ORDER)
    if unknown:
        ap.error(f"unknown collections: {', '.join(sorted(unknown))}")

    # Files the run will actually touch: the --only collections, plus (when
    # planning) the three files plan_slices always scans.
    required = set(only)
    if args.size:
        required |= {"orders", "customers", "order_items"}
    if not args.benchmarks.exists() and args.size:
        ap.error(f"benchmarks catalog missing: {args.benchmarks} (run scripts/sync_benchmarks.sh)")
    for name in required:
        f = args.dataset_dir / COLLECTION_FILES[name]
        if not f.exists():
            ap.error(f"dataset file missing: {f}")

    # ---- plan (always computed; pure local work) ----
    plan = {}
    if args.size:
        print(f"Planning {args.size} slice from {args.dataset_dir} ...")
        plan = plan_slices(SIZES[args.size], args.dataset_dir, args.benchmarks,
                           args.full_catalog, total_orders=args.total_orders)
        expected = {}
        for name in LOAD_ORDER:
            if name not in only:
                continue
            # Count through the exact upload predicate. (Plan id sets can be a
            # superset of reality: anchor UUID literals include store
            # rls_user_ids that never appear in customers.ndjson, so
            # len(customer_ids) over-counts by the number of phantom anchors.)
            expected[name] = sum(1 for _ in collection_docs(name, args.dataset_dir, plan))
        plan["expected"] = expected
        a = plan["anchors"]
        print(f"  anchors: {a['order_literals']} order + {a['customer_literals']} customer + "
              f"{a['item_literals']} item literals resolved "
              f"({a['phantom_literals']} phantom UUIDs ignored, e.g. store rls_user_ids; "
              f"{a['anchor_orders_found']} anchor orders present in data)")

    if args.dry_run:
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
        # With --size, the planning pass already computed exact expected
        # counts — use them (a bare --verify-only reports counts without
        # expectations).
        return 0 if verify(client, plan.get("expected", {}), only) else 1

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
