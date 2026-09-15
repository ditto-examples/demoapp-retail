#!/usr/bin/env python3
"""Build the apps' committed data bundle in shared/data/ from Microsoft's
actual shipped Zava DIY dataset — not regenerated fixtures.

Source: `zava_retail_2025_07_21_postgres_rls.backup` (the pre-generated
database Microsoft ships in github.com/microsoft/ai-tour-26-zava-diy-dataset-plus-mcp),
restored into a scratch Postgres container (see scripts/restore_ms_backup.sh).
This script reads it via psql and rewrites it into the normalized document
shape our Ditto apps and the retail-joins benchmark catalog run against
(the Apps teach Ditto SDK 5.1+ JOINs):

  id slugging     stores → store_seattle…, categories → cat_hand_tools…,
                  product_types → ptype_hammers…, products/customers/orders/
                  items → prod_1 / customer_1 / order_1 / item_1
  derived-from-real-data
                  orders.subtotal = Σ line totals, item_count = # line rows,
                  total = round(subtotal × 1.095, 2)  (WA-style 9.5% sales tax —
                  mirrors the benchmark's total/subtotal relationship)
  synthesized (user-approved, documented, deterministic by hash)
                  orders.status — 60% completed / 26% pending / 10% restocked /
                  4% cancelled (Microsoft's dataset has no status column)
                  stores.location — real WA city/state/zip per named store
                  inventory.location (aisle/shelf/bin) + last_counted
  re-denormalized order_items.store_id — joined from the parent retail.orders
                  row. Sync subscriptions reject JOINs (validated against
                  ditto core: ditto-sync-docs compiles subscription DQL with
                  restrict_to_original_syntax, resolver requires SELECT * on a
                  single collection FROM), so per-store item sync needs the
                  field on the item. Screens still JOIN items ⨝ products for
                  display (SKU/name live on the product).
  kept real       products.sku / product_name / prices / description,
                  categories seasonal multipliers (from Microsoft's own
                  product_data.json), customers, quantities, discounts…

The two pgvector embedding tables are skipped (the apps don't use them).

Output: shared/data/<collection>.ndjson.gz (deterministic gzip, mtime=0) +
shared/data/manifest.json (counts, sha256, per-store order totals, the
patched catalog anchor ids). Order of operations when regenerating:
  python3 scripts/prepare_data.py && scripts/sync_benchmarks.sh

Python 3 standard library only.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "shared" / "data"
DEFAULT_MS_CATALOG = (REPO_ROOT.parent / "ai-tour-26-zava-diy-dataset-plus-mcp"
                      / "data" / "database" / "product_data.json")

COLLECTIONS = ["stores", "categories", "product_types", "products",
               "customers", "inventory", "orders", "order_items"]

# Real WA city/state/zip for each named Microsoft store (fabricated per the
# PLAN — Microsoft's stores table carries no location). Online matches the
# benchmark's convention (n/a address, Seattle ZIP).
STORE_LOCATIONS = {
    "seattle":  ("1200 Pine Street", "Seattle", "WA", "98101"),
    "bellevue": ("500 Bellevue Square", "Bellevue", "WA", "98004"),
    "tacoma":   ("1901 Commerce Street", "Tacoma", "WA", "98402"),
    "spokane":  ("707 W Main Avenue", "Spokane", "WA", "99201"),
    "everett":  ("1402 SE Everett Mall Way", "Everett", "WA", "98208"),
    "redmond":  ("15300 NE 24th Street", "Redmond", "WA", "98052"),
    "kirkland": ("8629 120th Avenue NE", "Kirkland", "WA", "98033"),
    "online":   ("n/a", "Seattle", "WA", "98101"),
}

MONTHS = ["jan", "feb", "mar", "apr", "may", "jun",
          "jul", "aug", "sep", "oct", "nov", "dec"]

# The literal anchors patched into the bundled catalog (see
# shared/catalog_overrides.json) — every value names a REAL Microsoft row,
# verified in the restored backup before choosing:
#   order_197663      — 2024-12-30, Seattle, 5 line items, $1,564.77 subtotal
#   customer_40000    — Jasmine Johnston <jasmine.johnston.40000@example.com>
#   customer_23       — Elizabeth Monroe, 12 orders (pairs with the median-
#                       selectivity join anchors of the suite)
#   HTHM001600        — "Professional Claw Hammer 16oz"
ANCHOR_ORDER = "order_197663"
ANCHOR_CUSTOMER = "customer_40000"
ANCHOR_JOIN_CUSTOMER = "customer_23"
ANCHOR_SKU = "HTHM001600"


def slug(text: str) -> str:
    """'PAINT & FINISHES' -> 'paint_and_finishes', 'HAND TOOLS' -> 'hand_tools'."""
    text = text.lower().replace("&", "and")
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]+", "_", text)).strip("_")


def store_slug(store_name: str) -> str:
    """'Zava Retail Seattle' -> 'store_seattle', 'Zava Retail Online' -> 'store_online'."""
    name = re.sub(r"^zava\s+(retail\s+)?", "", store_name.strip(), flags=re.IGNORECASE)
    return f"store_{slug(name)}"


def hash_bucket(key: str, modulo: int) -> int:
    return int(hashlib.md5(key.encode()).hexdigest()[:12], 16) % modulo


def status_for(order_id: str) -> str:
    """Deterministic status spread (user-specified): 60/26/10/4."""
    b = hash_bucket(f"status:{order_id}", 100)
    if b < 60:
        return "completed"
    if b < 86:
        return "pending"
    if b < 96:
        return "restocked"
    return "cancelled"


def bin_location(store_id: str, product_id: str) -> dict:
    """Deterministic fabricated shelf location (real dataset field absent)."""
    h = hash_bucket(f"loc:{store_id}:{product_id}", 1 << 20)
    return {"aisle": str(1 + h % 25), "shelf": chr(ord("A") + (h >> 6) % 5),
            "bin": str(1 + (h >> 12) % 30)}


def last_counted_for(key: str) -> str:
    base = date(2026, 6, 1) + timedelta(days=hash_bucket(f"counted:{key}", 90))
    return f"{base.isoformat()}T00:00:00Z"


class PsqlSource:
    """Run read-only queries against the restored Microsoft backup.

    Default transport: `podman exec <container> psql …` (or docker). Any other
    psql command line works via --psql, e.g. --psql "psql -d zava".
    """

    def __init__(self, psql_prefix: list[str]):
        self.prefix = psql_prefix

    @staticmethod
    def resolve(container: str, psql: str | None) -> "PsqlSource":
        if psql:
            return PsqlSource(shlex.split(psql))
        engine = shutil.which("podman") or shutil.which("docker")
        if not engine:
            raise SystemExit("error: neither podman nor docker found; pass --psql directly")
        return PsqlSource([engine, "exec", container,
                           "psql", "-U", "postgres", "-d", "zava", "-v", "ON_ERROR_STOP=1"])

    def query_json(self, sql: str):
        """Yield each result row as a dict (row_to_json per row, text mode)."""
        proc = subprocess.run(
            [*self.prefix, "-A", "-q", "-t", "-c", sql],
            capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise SystemExit(f"error: query failed:\n{sql}\n{proc.stderr.strip()}")
        for line in proc.stdout.splitlines():
            line = line.strip()
            if line:
                yield json.loads(line)


def iso_day(d: str) -> str:
    return f"{d}T00:00:00Z"


def transform(source: PsqlSource, ms_catalog: dict):
    """Yield (collection, doc) in LOAD order, one pass per collection."""
    store_ids: dict[int, str] = {}
    for r in source.query_json(
            "SELECT row_to_json(s) FROM (SELECT store_id, store_name, rls_user_id::text, is_online "
            "FROM retail.stores ORDER BY store_id) s"):
        sid = store_slug(r["store_name"])
        store_ids[r["store_id"]] = sid
        addr, city, state, zipc = STORE_LOCATIONS[slug(r["store_name"].removeprefix("Zava Retail ")
                                                           .removeprefix("Zava ").lower())]
        yield "stores", {
            "_id": sid, "store_id": sid, "store_name": r["store_name"],
            "rls_user_id": r["rls_user_id"], "is_online": r["is_online"],
            "location": {"address": addr, "city": city, "state": state, "zip": zipc},
            "deleted": False,
        }

    seasonal = ms_catalog.get("main_categories", {})
    category_ids: dict[int, str] = {}
    for r in source.query_json(
            "SELECT row_to_json(c) FROM (SELECT category_id, category_name "
            "FROM retail.categories ORDER BY category_id) c"):
        cid = f"cat_{slug(r['category_name'])}"
        category_ids[r["category_id"]] = cid
        multipliers = seasonal.get(r["category_name"], {}).get("washington_seasonal_multipliers")
        doc = {"_id": cid, "category_id": cid, "category_name": r["category_name"],
               "deleted": False}
        if multipliers:  # Microsoft's own real seasonal curve
            doc["seasonal_multipliers"] = dict(zip(MONTHS, multipliers))
        yield "categories", doc

    type_ids: dict[int, str] = {}
    for r in source.query_json(
            "SELECT row_to_json(t) FROM (SELECT type_id, category_id, type_name "
            "FROM retail.product_types ORDER BY type_id) t"):
        tid = f"ptype_{slug(r['type_name'])}_{r['type_id']}"
        type_ids[r["type_id"]] = tid
        yield "product_types", {
            "_id": tid, "type_id": tid,
            "category_id": category_ids[r["category_id"]],
            "type_name": r["type_name"], "deleted": False,
        }

    for r in source.query_json(
            "SELECT row_to_json(p) FROM (SELECT product_id, sku, product_name, category_id, type_id, "
            "cost::float8 AS cost, base_price::float8 AS base_price, "
            "gross_margin_percent::float8 AS gross_margin_percent, product_description "
            "FROM retail.products ORDER BY product_id) p"):
        pid = f"prod_{r['product_id']}"
        yield "products", {
            "_id": pid, "product_id": pid, "sku": r["sku"],
            "product_name": r["product_name"],
            "category_id": category_ids[r["category_id"]],
            "type_id": type_ids[r["type_id"]],
            "cost": round(r["cost"], 2), "base_price": round(r["base_price"], 2),
            "gross_margin_percent": round(r["gross_margin_percent"], 2),
            "description": r["product_description"], "deleted": False,
        }

    for r in source.query_json(
            "SELECT row_to_json(c) FROM (SELECT customer_id, first_name, last_name, email, phone, "
            "primary_store_id, created_at::text AS created_at "
            "FROM retail.customers ORDER BY customer_id) c"):
        cid_str = f"customer_{r['customer_id']}"
        yield "customers", {
            "_id": cid_str, "customer_id": cid_str,
            "first_name": r["first_name"], "last_name": r["last_name"],
            "email": r["email"], "phone": r["phone"],
            "primary_store_id": store_ids[r["primary_store_id"]],
            "created_at": r["created_at"].replace(" ", "T") + "Z",
            "deleted": False,
        }

    for r in source.query_json(
            "SELECT row_to_json(i) FROM (SELECT store_id, product_id, stock_level "
            "FROM retail.inventory ORDER BY store_id, product_id) i"):
        sid = store_ids[r["store_id"]]
        pid = f"prod_{r['product_id']}"
        yield "inventory", {
            "_id": {"store_id": sid, "product_id": pid},
            "store_id": sid, "product_id": pid,
            "stock_level": r["stock_level"],
            "location": bin_location(sid, pid),
            "last_counted": last_counted_for(f"{sid}:{pid}"),
            "notes": "", "deleted": False,
        }

    # Orders with per-order aggregates derived from the REAL line items.
    for r in source.query_json(
            "SELECT row_to_json(o) FROM ("
            "  SELECT o.order_id, o.customer_id, o.store_id, o.order_date::text AS order_date, "
            "  COALESCE(s.item_rows, 0) AS item_rows, COALESCE(s.subtotal, 0)::float8 AS subtotal "
            "  FROM retail.orders o LEFT JOIN LATERAL ("
            "    SELECT COUNT(*) AS item_rows, SUM(i.total_amount) AS subtotal "
            "    FROM retail.order_items i WHERE i.order_id = o.order_id) s ON true "
            "  ORDER BY o.order_id) o"):
        oid = f"order_{r['order_id']}"
        subtotal = round(r["subtotal"], 2)
        yield "orders", {
            "_id": oid, "order_id": oid, "customer_id": f"customer_{r['customer_id']}",
            "store_id": store_ids[r["store_id"]],
            "order_date": iso_day(r["order_date"]),
            "status": status_for(oid),
            "item_count": r["item_rows"],
            "subtotal": subtotal, "total": round(subtotal * 1.095, 2),
            "deleted": False,
        }

    for r in source.query_json(
            "SELECT row_to_json(i) FROM ("
            "  SELECT i.order_item_id, i.order_id, o.store_id, i.product_id, i.quantity, "
            "  i.unit_price::float8 AS unit_price, i.discount_percent, "
            "  i.discount_amount::float8 AS discount_amount, i.total_amount::float8 AS line_total "
            "  FROM retail.order_items i JOIN retail.orders o ON i.order_id = o.order_id "
            "  ORDER BY i.order_item_id) i"):
        iid = f"item_{r['order_item_id']}"
        yield "order_items", {
            "_id": iid, "order_item_id": iid,
            "order_id": f"order_{r['order_id']}",
            # Denormalized back ON PURPOSE from the parent order: sync
            # subscriptions reject JOINs, so per-store item sync needs the
            # field on the item itself (`WHERE store_id = :storeId`).
            "store_id": store_ids[r["store_id"]],
            "product_id": f"prod_{r['product_id']}",
            "quantity": r["quantity"], "unit_price": round(r["unit_price"], 2),
            "discount_percent": r["discount_percent"],
            "discount_amount": round(r["discount_amount"], 2),
            "line_total": round(r["line_total"], 2),
            "deleted": False,
        }


def write_gz(path: Path, docs) -> tuple[int, str]:
    lines = []
    for doc in docs:
        lines.append(json.dumps(doc, separators=(",", ":"), ensure_ascii=True))
    payload = ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8")
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as gz:
            gz.write(payload)
    return len(lines), hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--container", default="zava-restore",
                    help="podman/docker container with the restored MS backup")
    ap.add_argument("--psql", help='full psql command instead, e.g. "psql -d zava"')
    ap.add_argument("--ms-catalog", type=Path, default=DEFAULT_MS_CATALOG,
                    help="Microsoft product_data.json (seasonal multipliers source)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()
    if not args.ms_catalog.exists():
        ap.error(f"Microsoft catalog missing: {args.ms_catalog}")
    ms_catalog = json.loads(args.ms_catalog.read_text())

    source = PsqlSource.resolve(args.container, args.psql)
    args.out.mkdir(parents=True, exist_ok=True)

    # One pass per collection, transformed docs buffered per collection
    # (they're written once; orders drive the per-store counts).
    collected: dict[str, list[dict]] = {c: [] for c in COLLECTIONS}
    for coll, doc in transform(source, ms_catalog):
        collected[coll].append(doc)

    orders_per_store: dict[str, int] = {}
    for o in collected["orders"]:
        orders_per_store[o["store_id"]] = orders_per_store.get(o["store_id"], 0) + 1
    orders_per_store = dict(sorted(orders_per_store.items(), key=lambda kv: kv[1]))
    default_store = next(iter(orders_per_store))

    manifest: dict = {
        "source": "microsoft/ai-tour-26-zava-diy-dataset-plus-mcp zava_retail_2025_07_21 backup",
        "collections": {},
        "orders_per_store": orders_per_store,
        "default_store": default_store,
        "catalog_anchors": {
            "order": ANCHOR_ORDER, "customer": ANCHOR_CUSTOMER,
            "join_customer": ANCHOR_JOIN_CUSTOMER, "sku": ANCHOR_SKU,
        },
        "synthesized_fields": {
            "orders.status": "deterministic 60/26/10/4 spread (MS data has none)",
            "orders.total": "round(subtotal * 1.095, 2) — derived tax",
            "orders.subtotal/item_count": "aggregated from real line items",
            "stores.location": "real WA city/state/zip per named store (MS has no column)",
            "inventory.location/last_counted": "deterministic fabrication (MS has no columns)",
            "order_items.store_id": "denormalized from the parent retail.orders row "
                "(subscriptions reject JOINs — per-store item sync needs it on the item)",
        },
    }
    total = 0
    for coll in COLLECTIONS:
        n, sha = write_gz(args.out / f"{coll}.ndjson.gz", collected[coll])
        manifest["collections"][coll] = {"docs": n, "sha256_gz": sha, "file": f"{coll}.ndjson.gz"}
        total += n
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    print(f"wrote {total} docs to {args.out}")
    print(f"orders per store: {orders_per_store}")
    print(f"apps' default store (fewest orders): {default_store}")
    print("\nnext step: scripts/sync_benchmarks.sh  (applies the catalog literal overrides)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
