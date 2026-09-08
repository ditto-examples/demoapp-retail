"""Contract tests for the committed Microsoft-data bundle in shared/data/
(built by scripts/prepare_data.py from Microsoft's shipped Zava backup) and
for the literal-patched benchmark catalog. Skipped when the bundle is absent;
purely local reads (no network).

These encode what the DEMOS rely on, with Microsoft's actual data:
exact collection counts, the per-store default, the derived-field math,
the synthetic status spread tolerances, and the patched anchor literals.
"""
import gzip
import json
import re
import unittest
from pathlib import Path

import _support as S

DATASET = S.REPO_ROOT / "shared" / "data"
CATALOG = S.REPO_ROOT / "shared" / "benchmarks.json"
OVERRIDES = S.REPO_ROOT / "shared" / "catalog_overrides.json"

EXPECTED_DOCS = {
    "stores": 8,
    "categories": 9,
    "product_types": 89,
    "products": 424,
    "customers": 50_000,
    "inventory": 3_392,
    "orders": 197_665,
    "order_items": 414_241,
}

# From the transform (scripts/prepare_data.py) — chosen REAL Microsoft rows.
ANCHOR_ORDER = "order_197663"        # Seattle, 2024-12-30, 5 items
ANCHOR_ORDER_ITEMS = 5
ANCHOR_CUSTOMER = "customer_40000"   # Jasmine Johnston
ANCHOR_JOIN_CUSTOMER = "customer_23"  # Elizabeth Monroe, 12 orders
ANCHOR_JOIN_CUSTOMER_ORDERS = 12
ANCHOR_SKU = "HTHM001600"            # Professional Claw Hammer 16oz


def read_collection(name):
    with gzip.open(DATASET / f"{name}.ndjson.gz", "rt", encoding="utf-8") as fh:
        for line in fh:
            yield json.loads(line)


@unittest.skipUnless(DATASET.exists(), "shared/data bundle missing — run scripts/prepare_data.py")
class MsDataBundle(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((DATASET / "manifest.json").read_text())
        cls.stores = {d["_id"]: d for d in read_collection("stores")}
        cls.products = {d["_id"]: d for d in read_collection("products")}

    def test_counts_match_microsofts_dataset(self):
        for name, expected in EXPECTED_DOCS.items():
            self.assertEqual(self.manifest["collections"][name]["docs"], expected, name)
            path = DATASET / self.manifest["collections"][name]["file"]
            self.assertTrue(path.exists(), name)

    def test_bundle_matches_manifest_line_counts(self):
        for name, info in self.manifest["collections"].items():
            n = sum(1 for _ in gzip.open(DATASET / info["file"], "rt", encoding="utf-8"))
            self.assertEqual(n, info["docs"], name)

    def test_store_slugs_and_real_names(self):
        self.assertEqual(set(self.stores), {
            "store_seattle", "store_bellevue", "store_tacoma", "store_spokane",
            "store_everett", "store_redmond", "store_kirkland", "store_online"})
        self.assertEqual(self.stores["store_seattle"]["store_name"], "Zava Retail Seattle")
        self.assertTrue(self.stores["store_online"]["is_online"])
        # Fabricated-but-real geography: every store has a WA zip.
        for s in self.stores.values():
            self.assertEqual(s["location"]["state"], "WA")
            self.assertRegex(s["location"]["zip"], r"^9[89]\d{3}$")  # Washington range

    def test_default_store_is_kirkland_fewest_orders(self):
        counts = self.manifest["orders_per_store"]
        self.assertEqual(self.manifest["default_store"], "store_kirkland")
        self.assertEqual(counts["store_kirkland"], 2_975)
        self.assertEqual(next(iter(counts)), "store_kirkland")  # sorted ascending

    def test_products_are_microsofts_real_catalog(self):
        skus = {p["sku"] for p in self.products.values()}
        self.assertIn(ANCHOR_SKU, skus)
        self.assertEqual(len(skus), len(self.products), "SKUs are unique in Microsoft's data")
        for p in self.products.values():
            self.assertNotRegex(p["product_name"], r"\b[A-Z]{3} item \d{4}\b",
                                "generator-style names must not leak back in")
            self.assertIn("description", p)
        hammer = next(p for p in self.products.values() if p["sku"] == ANCHOR_SKU)
        self.assertEqual(hammer["product_name"], "Professional Claw Hammer 16oz")

    def test_normalized_join_shape(self):
        order = next(d for d in read_collection("orders"))
        for field in ("customer_name", "customer_email", "store_name"):
            self.assertNotIn(field, order)
        item = next(d for d in read_collection("order_items"))
        for field in ("store_id", "sku", "product_name"):
            self.assertNotIn(field, item)

    def test_derived_totals_math(self):
        # For the anchor order the aggregate is exact and cheap to verify.
        order = next(d for d in read_collection("orders") if d["_id"] == ANCHOR_ORDER)
        items = [d for d in read_collection("order_items") if d["order_id"] == ANCHOR_ORDER]
        self.assertEqual(len(items), ANCHOR_ORDER_ITEMS)
        self.assertEqual(order["item_count"], ANCHOR_ORDER_ITEMS)
        self.assertEqual(order["subtotal"], round(sum(i["line_total"] for i in items), 2))
        self.assertEqual(order["total"], round(order["subtotal"] * 1.095, 2))
        # Global invariants: totals always derive from subtotal; counts ≥ 1.
        checked = 0
        for d in read_collection("orders"):
            self.assertEqual(d["total"], round(d["subtotal"] * 1.095, 2), d["_id"])
            self.assertGreaterEqual(d["item_count"], 1)
            checked += 1
        self.assertEqual(checked, EXPECTED_DOCS["orders"])

    def test_status_spread_within_tolerance(self):
        from collections import Counter
        spread = Counter(d["status"] for d in read_collection("orders"))
        total = sum(spread.values())
        targets = {"completed": 0.60, "pending": 0.26, "restocked": 0.10, "cancelled": 0.04}
        for status, target in targets.items():
            share = spread[status] / total
            self.assertAlmostEqual(share, target, delta=0.02,
                                   msg=f"status spread drifted: {spread}")

    def test_anchor_rows_exist(self):
        self.assertIn(ANCHOR_ORDER, {d["_id"] for d in read_collection("orders")})
        customers = {d["_id"]: d for d in read_collection("customers")}
        self.assertEqual(customers[ANCHOR_CUSTOMER]["email"],
                         "jasmine.johnston.40000@example.com")
        join_orders = sum(1 for d in read_collection("orders")
                          if d["customer_id"] == ANCHOR_JOIN_CUSTOMER)
        self.assertEqual(join_orders, ANCHOR_JOIN_CUSTOMER_ORDERS)


@unittest.skipUnless(CATALOG.exists(), "shared/benchmarks.json missing — run scripts/sync_benchmarks.sh")
class PatchedCatalog(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.catalog = json.loads(CATALOG.read_text())

    def test_96_entries_ship(self):
        self.assertEqual(len(self.catalog), 96)

    def test_no_stale_benchmark_literals(self):
        # Scope: the fields the apps EXECUTE (DQL) or run on-device. The
        # upstream sql_equivalent keeps the suite's own PG literals by design
        # (catalog_overrides deliberately leaves it untouched — see its
        # docstring on integer-typed columns in MS's restored schema).
        stale = ("order_20221209_0001", "e652232a-95ab-4fcf-86b7-e40cea3d749d",
                 "d30977d3-fa5d-4e13-9175-f637bccc4c87", "HND-0042")
        for name, entry in self.catalog.items():
            blob = json.dumps({k: entry.get(k)
                               for k in ("query", "preQueries", "postQueries")})
            for lit in stale:
                self.assertNotIn(lit, blob, f"{name} still references {lit}")

    def test_patched_entries_have_ms_anchors_and_counts(self):
        expectations = {
            "orders__select__by_id": (ANCHOR_ORDER, 1),
            "orders__join__store_info": (ANCHOR_ORDER, 1),
            "orders__join__store_info_projection": (ANCHOR_ORDER, 1),
            "items__join__orders": (ANCHOR_ORDER, ANCHOR_ORDER_ITEMS),
            "items__join__products": (ANCHOR_ORDER, ANCHOR_ORDER_ITEMS),
            "order_items__select__by_order_indexed": (ANCHOR_ORDER, ANCHOR_ORDER_ITEMS),
            "customers__select__by_id": (ANCHOR_CUSTOMER, 1),
            "customer__join__orders": (ANCHOR_JOIN_CUSTOMER, ANCHOR_JOIN_CUSTOMER_ORDERS),
            "customer__join__orders_unfiltered": (ANCHOR_JOIN_CUSTOMER, ANCHOR_JOIN_CUSTOMER_ORDERS),
            "products__select__by_sku_indexed": (ANCHOR_SKU, 1),
        }
        for name, (literal, count) in expectations.items():
            entry = self.catalog[name]
            self.assertIn(literal, entry["query"], name)
            self.assertEqual(entry.get("expected_count"), count, name)
            self.assertNotIn("expected_first_rows_hash", entry,
                             f"{name}: stale oracle hash must be dropped when patched")

    def test_overrides_file_documents_the_anchors(self):
        overrides = json.loads(OVERRIDES.read_text()) if OVERRIDES.exists() else {}
        self.assertEqual(overrides.get("literals", {}).get("order_20221209_0001"), ANCHOR_ORDER)


if __name__ == "__main__":
    unittest.main()
