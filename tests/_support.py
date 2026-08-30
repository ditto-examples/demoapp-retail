"""Shared fixtures for the Zava Retail demo-repo test suite.

Importing this module puts <repo>/scripts on sys.path so tests can
`import load_data`. The synthetic dataset mirrors the real retail schema
(see benchmarks/retail/README.md in dql-metrics-benchmark) at toy scale:
100 orders over 3 stores, 40 customers, 10 products, 2 items per order.
"""
import json
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

N_ORDERS = 100
N_CUSTOMERS = 40
N_PRODUCTS = 10
STORE_IDS = ["store_a", "store_b", "store_c"]


def customer_id(i: int) -> str:
    return f"c0000000-0000-4000-8000-{i:012d}"


def item_id(n: int) -> str:
    return f"11111111-1111-4111-8111-{n:012d}"


def order_id(i: int) -> str:
    """The _id the builder gives order i (dates spread across 2022–2025)."""
    year = 2022 + (i // 12) % 4
    month = i % 12 + 1
    return f"order_{year}{month:02d}01_{i:04d}"


def write_ndjson(path: Path, docs: list[dict]):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for doc in docs:
            fh.write(json.dumps(doc) + "\n")


def make_synthetic_dataset(root: Path) -> Path:
    """Build the synthetic dataset under `root` (a tmp dir). Returns root."""
    stores = [{
        "_id": sid, "store_id": sid, "store_name": f"Zava {sid}",
        "rls_user_id": f"8d7e9536-74a1-4101-967d-{i:012d}",
        "is_online": False, "location": {"city": "Seattle"}, "deleted": False,
    } for i, sid in enumerate(STORE_IDS)]
    write_ndjson(root / "stores.ndjson", stores)

    write_ndjson(root / "categories.ndjson", [
        {"_id": f"cat_{c}", "category_id": f"cat_{c}", "category_name": c,
         "seasonal_multipliers": {"jan": 1.0}, "deleted": False}
        for c in ("tools", "paint")
    ])

    products = [{
        "_id": f"prod_{p:04d}", "product_id": f"prod_{p:04d}", "sku": f"SKU-{p:04d}",
        "product_name": f"Item {p}", "category_id": "cat_tools",
        "cost": 10.0 + p, "base_price": 20.0 + p, "gross_margin_percent": 50.0,
        "specifications": {"weight_lbs": 1.0}, "deleted": False,
    } for p in range(N_PRODUCTS)]
    write_ndjson(root / "products.ndjson", products)

    customers = [{
        "_id": customer_id(i), "customer_id": customer_id(i),
        "first_name": f"First{i}", "last_name": f"Last{i}",
        "email": f"user{i}@example.com", "phone": "555-0100",
        "primary_store_id": STORE_IDS[i % len(STORE_IDS)],
        "created_at": "2023-01-01T00:00:00Z", "deleted": False,
    } for i in range(N_CUSTOMERS)]
    write_ndjson(root / "customers.ndjson", customers)

    inventory = [{
        "_id": {"store_id": sid, "product_id": f"prod_{p:04d}"},
        "store_id": sid, "product_id": f"prod_{p:04d}",
        "stock_level": (p * 7) % 50, "location": {"aisle": "3", "shelf": "A", "bin": "1"},
        "last_counted": "2025-01-01T00:00:00Z", "notes": "", "deleted": False,
    } for sid in STORE_IDS for p in range(N_PRODUCTS)]
    write_ndjson(root / "inventory-full.ndjson", inventory)

    orders, items = [], []
    for i in range(N_ORDERS):
        oid = order_id(i)
        year = 2022 + (i // 12) % 4
        month = i % 12 + 1
        cid = customer_id(i % N_CUSTOMERS)
        sid = STORE_IDS[i % len(STORE_IDS)]
        orders.append({
            "_id": oid, "order_id": oid, "customer_id": cid, "store_id": sid,
            "order_date": f"{year}-{month:02d}-01T12:00:00Z",
            "customer_name": f"First{i % N_CUSTOMERS} Last{i % N_CUSTOMERS}",
            "customer_email": f"user{i % N_CUSTOMERS}@example.com",
            "store_name": f"Zava {sid}", "item_count": 2,
            "subtotal": 40.0, "total": 44.0, "status": "completed", "deleted": False,
        })
        for k in range(2):
            items.append({
                "_id": item_id(i * 10 + k), "order_id": oid, "store_id": sid,
                "product_id": f"prod_{(i + k) % N_PRODUCTS:04d}",
                "sku": f"SKU-{(i + k) % N_PRODUCTS:04d}", "product_name": "Item",
                "quantity": 1, "unit_price": 20.0, "discount_percent": 0,
                "line_total": 20.0, "deleted": False,
            })
    write_ndjson(root / "orders-full.ndjson", orders)
    write_ndjson(root / "order_items-full.ndjson", items)
    return root


# Anchor layout used by the synthetic benchmarks catalog (all OFF-stride for a
# stride of 10-from-100, whose picks are lines {0, 10, ..., 90}):
ANCHOR_ORDER = order_id(97)                     # by-id literal
ANCHOR_ITEM = item_id(960)                      # belongs to order 96
ANCHOR_ITEM_PARENT = order_id(96)               # order 96 is off-stride
ANCHOR_CUSTOMER_UUID = customer_id(9)           # by-customer literal
ANCHOR_EMAIL = "user7@example.com"              # by-email literal
ANCHOR_EMAIL_CUSTOMER = customer_id(7)
PHANTOM_UUID = "ffffffff-ffff-4fff-8fff-ffffffffffff"  # store rls literal: loads nothing


def make_synthetic_benchmarks(root: Path) -> Path:
    """Synthetic benchmarks.json exercising every anchor literal class."""
    catalog = {
        "orders__select__by_id": {
            "query": f"SELECT * FROM orders WHERE _id = '{ANCHOR_ORDER}'",
            "category": "SELECT",
        },
        "orders__select__by_customer_indexed": {
            "preQueries": ["DROP INDEX IF EXISTS orders_cust ON orders",
                           "CREATE INDEX orders_cust ON orders (customer_id)"],
            "query": f"SELECT * FROM orders WHERE customer_id = '{ANCHOR_CUSTOMER_UUID}' AND deleted = false",
            "postQueries": ["DROP INDEX IF EXISTS orders_cust ON orders"],
            "category": "INDEX_SELECT",
        },
        "customers__select__by_email_no_index": {
            "query": f"SELECT * FROM customers WHERE email = '{ANCHOR_EMAIL}'",
            "category": "SELECT",
        },
        "order_items__select__by_id": {
            "query": f"SELECT * FROM order_items WHERE _id = '{ANCHOR_ITEM}'",
            "category": "SELECT",
        },
        "stores__select__by_rls_user_id_indexed": {
            "query": f"SELECT * FROM stores WHERE rls_user_id = '{PHANTOM_UUID}'",
            "category": "SELECT",
        },
    }
    path = root / "benchmarks.json"
    path.write_text(json.dumps(catalog, indent=1))
    return path


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
