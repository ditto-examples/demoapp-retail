#!/usr/bin/env python3
"""Load the committed Microsoft Zava dataset bundle into Ditto Server (Big
Peer) via the HTTP API.

Reads the gzipped NDJSON bundle in shared/data/ (built by
scripts/prepare_data.py from Microsoft's shipped Zava backup, normalized for
Ditto SDK 5.1+ JOINs) and batch-inserts every document with
INSERT ... DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE against
POST {DITTO_HTTP_API_URL}/api/v5/store/execute (Bearer DITTO_API_KEY).

There is no size ladder: we load all of Microsoft's data (~666K docs). The
mobile apps only pull a per-store slice over sync (per-store orders +
inventory + order_items subscriptions — items carry a denormalized store_id
because sync subscriptions reject JOINs — plus the shared catalog and
customers). The store with the fewest orders (flagged in
shared/data/manifest.json) is stamped "demo_default": true on its store doc —
the apps auto-select it on first launch instead of showing the picker.

Python 3 standard library only.

Usage:
  python3 scripts/load_data.py                      # load everything
  python3 scripts/load_data.py --dry-run            # show the plan, no HTTP
  python3 scripts/load_data.py --clear              # wipe all 8 collections
  python3 scripts/load_data.py --only orders,order_items
  python3 scripts/load_data.py --verify-only        # COUNT check vs manifest

See PLAN.md §3 for the design.
"""

from __future__ import annotations

import argparse
import gzip
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
DEFAULT_DATASET_DIR = REPO_ROOT / "shared" / "data"

# collection -> candidate source files, first match wins. The committed
# bundle is gzipped (`<name>.ndjson.gz`); a plain-NDJSON directory keeps
# working via --dataset-dir.
COLLECTION_CANDIDATES = {c: [f"{c}.ndjson.gz", f"{c}.ndjson", f"{c}-full.ndjson"]
                         for c in ["stores", "categories", "product_types", "products",
                                   "customers", "inventory", "orders", "order_items"]}
# Upload order (cosmetic; Big Peer has no FK constraints).
LOAD_ORDER = ["stores", "categories", "product_types", "products",
              "customers", "inventory", "orders", "order_items"]
CLEAR_ORDER = ["order_items", "orders", "inventory", "customers", "products",
               "product_types", "categories", "stores"]

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
# Bundle reading
# --------------------------------------------------------------------------- #

def resolve_file(dataset_dir: Path, name: str) -> Path:
    """First existing candidate for a collection's source file."""
    for fname in COLLECTION_CANDIDATES[name]:
        f = dataset_dir / fname
        if f.exists():
            return f
    return dataset_dir / COLLECTION_CANDIDATES[name][0]  # for the error message


def iter_ndjson(path: Path):
    if path.suffix == ".gz":
        fh = gzip.open(path, "rt", encoding="utf-8")
    else:
        fh = path.open("r", encoding="utf-8")
    with fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line), len(line)


def read_manifest(dataset_dir: Path) -> dict:
    f = dataset_dir / "manifest.json"
    if not f.exists():
        return {}
    return json.loads(f.read_text())


def collection_docs(name: str, dataset_dir: Path, default_store: str | None):
    """Yield (doc, raw_len) for the whole collection, stamping the apps'
    first-launch default store marker onto store docs."""
    path = resolve_file(dataset_dir, name)
    if name == "stores":
        for doc, n in iter_ndjson(path):
            doc["demo_default"] = (doc["_id"] == default_store)
            yield doc, n
    else:
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


def load_collection(client: BigPeerClient, name: str, dataset_dir: Path,
                    default_store: str | None, expected: int | None, args) -> int:
    statement = f"INSERT INTO {name} DOCUMENTS (:docs) ON ID CONFLICT DO UPDATE"
    sent = 0
    pool = ThreadPoolExecutor(max_workers=args.concurrency)
    pending: dict = {}
    try:
        for batch, _size in batched(collection_docs(name, dataset_dir, default_store),
                                    args.batch_docs, args.batch_bytes):
            pending[pool.submit(client.execute, statement, {"docs": batch})] = len(batch)
            if len(pending) >= args.concurrency * 4:
                sent += _collect(pending)  # frees slots, raises on failure
                _progress(name, sent, expected)
        while pending:
            sent += _collect(pending)
            _progress(name, sent, expected)
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


def expected_counts(dataset_dir: Path, manifest: dict) -> dict[str, int]:
    """Expected doc counts: the manifest's, else a local line count."""
    out: dict[str, int] = {}
    for name in LOAD_ORDER:
        if name in manifest.get("collections", {}):
            out[name] = manifest["collections"][name]["docs"]
        else:
            out[name] = sum(1 for _ in iter_ndjson(resolve_file(dataset_dir, name)))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma-separated collections to load/clear")
    ap.add_argument("--clear", action="store_true", help="delete all docs from all 8 collections")
    ap.add_argument("--verify-only", action="store_true",
                    help="skip load, just run COUNT verification against the manifest")
    ap.add_argument("--dry-run", action="store_true", help="print the plan; no HTTP")
    ap.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    ap.add_argument("--batch-docs", type=positive_int, default=MAX_BATCH_DOCS)
    ap.add_argument("--batch-bytes", type=positive_int, default=MAX_BATCH_BYTES)
    ap.add_argument("--concurrency", type=positive_int, default=4)
    args = ap.parse_args()

    if args.clear and (args.verify_only or args.dry_run):
        ap.error("--clear cannot be combined with --verify-only/--dry-run")
    if args.dry_run and (args.verify_only or args.clear):
        ap.error("--dry-run stands alone")

    only = {c.strip() for c in args.only.split(",") if c.strip()} if args.only else set(LOAD_ORDER)
    unknown = only - set(LOAD_ORDER)
    if unknown:
        ap.error(f"unknown collections: {', '.join(sorted(unknown))}")

    manifest = read_manifest(args.dataset_dir)
    default_store = manifest.get("default_store")
    if not default_store and not args.clear:
        print(f"WARNING: {args.dataset_dir}/manifest.json has no default_store — "
              f"apps will fall back to the first physical store", file=sys.stderr)

    if not args.clear:
        for name in only:
            f = resolve_file(args.dataset_dir, name)
            if not f.exists():
                ap.error(f"dataset file missing for {name}: {f}")
        expected = {n: c for n, c in expected_counts(args.dataset_dir, manifest).items()
                    if n in only}
    else:
        expected = {}

    if args.dry_run:
        print("\nDry run — would load:")
        total_docs = 0
        for name in LOAD_ORDER:
            if name not in only:
                continue
            n = expected[name]
            total_docs += n
            est_batches = (n + args.batch_docs - 1) // args.batch_docs
            print(f"  {name:<12} {n:>8} docs  (~{est_batches} batches)")
        print(f"  {'TOTAL':<12} {total_docs:>8} docs")
        print(f"\napps' default store (fewest orders): {default_store or '?'} "
              f"({manifest.get('orders_per_store', {}).get(default_store, '?')} orders)")
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
        return 0 if verify(client, expected, only) else 1

    started = time.time()
    print(f"Apps' default store: {default_store or '(unflagged)'}")
    for name in LOAD_ORDER:
        if name not in only:
            continue
        print(f"Loading {name} ...")
        load_collection(client, name, args.dataset_dir, default_store, expected.get(name), args)
    mins = (time.time() - started) / 60
    print(f"\nLoad complete in {mins:.1f} min.")

    return 0 if verify(client, expected, only) else 1


if __name__ == "__main__":
    sys.exit(main())
