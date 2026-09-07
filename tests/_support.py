"""Shared fixtures for the Zava Retail demo-repo test suite.

Importing this module puts <repo>/scripts on sys.path so tests can
`import load_data` / `import catalog_overrides`. The synthetic bundle mirrors
the transformed Microsoft Zava shape (see scripts/prepare_data.py) at toy
scale: 3 stores, 5 customers, 4 products, 6 orders, 12 items, gzip-compressed
with a manifest — exactly what scripts/load_data.py reads in production.
"""
import gzip
import json
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

STORE_IDS = ["store_a", "store_b", "store_c"]
# Per-store order counts for the fixture: store_a is the smallest (the apps'
# default-store logic keys off this).
STORE_ORDER_COUNTS = {"store_a": 1, "store_b": 2, "store_c": 3}
DEFAULT_STORE = "store_a"


def slug(text: str) -> str:
    import re
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]+", "_",
                                    text.lower().replace("&", "and"))).strip("_")


def write_gz_ndjson(path: Path, docs: list[dict]):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = "".join(json.dumps(d) + "\n" for d in docs).encode()
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            gz.write(payload)


def make_synthetic_bundle(root: Path) -> Path:
    """Build the toy transformed bundle under `root` (a tmp dir). Returns root."""
    write_gz_ndjson(root / "stores.ndjson.gz", [
        {"_id": sid, "store_id": sid, "store_name": f"Zava {sid}",
         "rls_user_id": f"8d7e9536-74a1-4101-967d-{i:012d}", "is_online": False,
         "location": {"address": "1 Zava Way", "city": "Seattle", "state": "WA", "zip": "98101"},
         "deleted": False}
        for i, sid in enumerate(STORE_IDS)])

    write_gz_ndjson(root / "categories.ndjson.gz", [
        {"_id": "cat_tools", "category_id": "cat_tools", "category_name": "HAND TOOLS",
         "seasonal_multipliers": {"jan": 1.0}, "deleted": False}])

    write_gz_ndjson(root / "product_types.ndjson.gz", [
        {"_id": "ptype_hammers_1", "type_id": "ptype_hammers_1",
         "category_id": "cat_tools", "type_name": "HAMMERS", "deleted": False}])

    write_gz_ndjson(root / "products.ndjson.gz", [
        {"_id": f"prod_{p}", "product_id": f"prod_{p}", "sku": f"HTHM{p:06d}",
         "product_name": f"Claw Hammer {p}oz", "category_id": "cat_tools",
         "type_id": "ptype_hammers_1", "cost": 10.0 + p, "base_price": 20.0 + p,
         "gross_margin_percent": 33.0, "description": "A hammer.",
         "deleted": False}
        for p in range(1, 5)])

    write_gz_ndjson(root / "customers.ndjson.gz", [
        {"_id": f"customer_{i}", "customer_id": f"customer_{i}",
         "first_name": f"First{i}", "last_name": f"Last{i}",
         "email": f"first.last{i}@example.com", "phone": "555-0100",
         "primary_store_id": STORE_IDS[i % len(STORE_IDS)],
         "created_at": "2025-01-01T00:00:00Z", "deleted": False}
        for i in range(1, 6)])

    write_gz_ndjson(root / "inventory.ndjson.gz", [
        {"_id": {"store_id": sid, "product_id": f"prod_{p}"},
         "store_id": sid, "product_id": f"prod_{p}",
         "stock_level": (p * 7) % 50,
         "location": {"aisle": "3", "shelf": "A", "bin": "1"},
         "last_counted": "2026-08-01T00:00:00Z", "notes": "", "deleted": False}
        for sid in STORE_IDS for p in range(1, 5)])

    orders, items = [], []
    oid = 0
    for sid, count in STORE_ORDER_COUNTS.items():
        for _ in range(count):
            oid += 1  # 2 items per order; totals derived like prepare_data.py
            for k in range(2):
                items.append({
                    "_id": f"item_{oid * 10 + k}", "order_item_id": f"item_{oid * 10 + k}",
                    "order_id": f"order_{oid}", "product_id": f"prod_{(oid + k) % 4 + 1}",
                    "quantity": 1, "unit_price": 10.0, "discount_percent": 0,
                    "discount_amount": 0.0, "line_total": 10.0, "deleted": False,
                })
            orders.append({
                "_id": f"order_{oid}", "order_id": f"order_{oid}",
                "customer_id": f"customer_{oid % 5 + 1}", "store_id": sid,
                "order_date": "2024-06-15T00:00:00Z",
                # approximate the deterministic spread; the synthetic set is
                # far too small for the real buckets to matter
                "status": "completed" if oid % 2 else "pending",
                "item_count": 2, "subtotal": 20.0, "total": 21.9, "deleted": False,
            })
    write_gz_ndjson(root / "orders.ndjson.gz", orders)
    write_gz_ndjson(root / "order_items.ndjson.gz", items)

    counts = {"stores": len(STORE_IDS), "categories": 1, "product_types": 1,
              "products": 4, "customers": 5, "inventory": len(STORE_IDS) * 4,
              "orders": sum(STORE_ORDER_COUNTS.values()), "order_items": len(items)}
    manifest = {
        "collections": {n: {"docs": c, "file": f"{n}.ndjson.gz"} for n, c in counts.items()},
        "orders_per_store": STORE_ORDER_COUNTS,
        "default_store": DEFAULT_STORE,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return root


class FakeResponse:
    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body


class FakeHTTP:
    """Scripted stand-in for HTTPSConnection, for BigPeerClient tests.

    script: list of (status, body_bytes) or Exception instances, consumed one
    per request. Records every request and every connection creation.
    """

    def __init__(self, script: list):
        self.script = list(script)
        self.requests: list[dict] = []
        self.connections = 0

    def factory(self):
        self.connections += 1
        return _FakeConn(self)


class _FakeConn:
    def __init__(self, owner: FakeHTTP):
        self.owner = owner
        self._next = None

    def request(self, method, path, body=None, headers=None):
        self.owner.requests.append({"method": method, "path": path, "body": body,
                                    "headers": headers})
        nxt = self.owner.script.pop(0)
        if isinstance(nxt, Exception):
            raise nxt
        self._next = nxt

    def getresponse(self):
        status, body = self._next
        return FakeResponse(status, body)


OK_BODY = b'{"transactionId": 1, "queryType": "insert", "items": [], "mutatedDocumentIds": [], "warnings": [], "totalWarningsCount": 0}'
