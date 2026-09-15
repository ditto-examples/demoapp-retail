"""Unit tests for scripts/catalog_overrides.py (synthetic fixtures, no network)."""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import _support as S
import catalog_overrides as co


def make_catalog() -> dict:
    return {
        "orders__select__by_id": {
            "query": "SELECT * FROM orders WHERE _id = 'order_20221209_0001'",
            "sql_equivalent": "SELECT * FROM orders WHERE order_id = 'order_20221209_0001'",
            "expected_count": 1,
            "expected_first_rows_hash": "sha256:deadbeef",
            "category": "SELECT",
        },
        "items__join__products": {
            "query": "SELECT i._id FROM order_items AS i INNER JOIN products AS p "
                     "ON i.product_id = p._id WHERE i.order_id = 'order_20221209_0001'",
            "expected_count": 9,
            "expected_first_rows_hash": "sha256:cafe",
            "category": "JOIN_INNER",
        },
        "customer__join__orders": {
            "query": "SELECT o._id FROM customers AS c INNER JOIN orders AS o "
                     "ON o.customer_id = c._id WHERE c._id = 'd30977d3-aaaa' AND o.deleted = false",
            "expected_count": 13,
            "category": "JOIN_INNER",
        },
        "products__select__by_sku_indexed": {
            "query": "SELECT * FROM products WHERE sku = 'HND-0042'",
            "expected_count": 1,
            "expected_first_rows_hash": "sha256:beef",
            "category": "INDEX_SELECT",
        },
        "orders__select__by_store_indexed": {
            "query": "SELECT * FROM orders WHERE store_id = 'store_seattle' AND deleted = false",
            "expected_count": 25033,
            "expected_first_rows_hash": "sha256:aaaa",
            "category": "INDEX_SELECT",
        },
    }


OVERRIDES = {
    "literals": {
        "order_20221209_0001": "order_6",      # exists in the synthetic bundle
        "d30977d3-aaaa": "customer_2",
        "HND-0042": "HTHM000001",
    }
}


class ApplyOverrides(unittest.TestCase):
    def test_substitutes_query_and_reports_touched(self):
        catalog = make_catalog()
        touched = co.apply_overrides(catalog, OVERRIDES)
        self.assertIn("orders__select__by_id", touched)
        self.assertIn("items__join__products", touched)
        self.assertIn("customer__join__orders", touched)
        self.assertIn("products__select__by_sku_indexed", touched)
        self.assertNotIn("orders__select__by_store_indexed", touched)
        self.assertIn("order_6", catalog["orders__select__by_id"]["query"])
        # sql_equivalent stays byte-identical: it describes the upstream PG
        # schema (integer ids) — slug substitution would corrupt it.
        self.assertEqual(catalog["orders__select__by_id"]["sql_equivalent"],
                         make_catalog()["orders__select__by_id"]["sql_equivalent"])
        self.assertIn("HTHM000001", catalog["products__select__by_sku_indexed"]["query"])
        # untouched entries stay byte-identical
        self.assertIn("store_seattle", catalog["orders__select__by_store_indexed"]["query"])


class RecomputeExpected(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dataset = S.make_synthetic_bundle(Path(self._tmp.name) / "data")

    def tearDown(self):
        self._tmp.cleanup()

    def test_counts_recomputed_against_bundle(self):
        catalog = make_catalog()
        co.apply_overrides(catalog, OVERRIDES)
        skipped = co.recompute_expected(catalog, OVERRIDES, self.dataset)
        self.assertEqual(skipped, [])
        self.assertEqual(catalog["orders__select__by_id"]["expected_count"], 1)
        # synthetic order_6 has 2 line items
        self.assertEqual(catalog["items__join__products"]["expected_count"], 2)
        # customer_2 owns the odd orders (oid % 5 + 1): oids 6 -> customer 2? compute honestly
        expected_orders = sum(1 for i in range(1, 7) if i % 5 + 1 == 2)
        self.assertEqual(catalog["customer__join__orders"]["expected_count"], expected_orders)
        self.assertEqual(catalog["products__select__by_sku_indexed"]["expected_count"], 1)
        # hashes are dropped everywhere we patched
        self.assertNotIn("expected_first_rows_hash", catalog["orders__select__by_id"])
        self.assertNotIn("expected_first_rows_hash", catalog["items__join__products"])
        # unpatched entries keep their suite stamps
        self.assertEqual(catalog["orders__select__by_store_indexed"]["expected_count"], 25033)
        self.assertIn("expected_first_rows_hash", catalog["orders__select__by_store_indexed"])

    def test_missing_bundle_drops_counts_and_warns(self):
        catalog = make_catalog()
        co.apply_overrides(catalog, OVERRIDES)
        skipped = co.recompute_expected(catalog, OVERRIDES, Path(self._tmp.name) / "nope")
        self.assertIn("orders__select__by_id", skipped)
        self.assertNotIn("expected_count", catalog["orders__select__by_id"])
        self.assertNotIn("expected_first_rows_hash", catalog["orders__select__by_id"])


class CliSmoke(unittest.TestCase):
    def test_main_roundtrip(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            catalog_path = root / "benchmarks.json"
            overrides_path = root / "catalog_overrides.json"
            catalog_path.write_text(json.dumps(make_catalog()))
            overrides_path.write_text(json.dumps(OVERRIDES))
            out = io.StringIO()
            import sys
            with mock_argv("catalog_overrides.py", str(catalog_path), str(overrides_path),
                           str(S.make_synthetic_bundle(root / "data"))), \
                 contextlib.redirect_stdout(out):
                rc = co.main()
            self.assertEqual(rc, 0)
            saved = json.loads(catalog_path.read_text())
            self.assertIn("order_6", saved["orders__select__by_id"]["query"])
            self.assertEqual(saved["orders__select__by_id"]["expected_count"], 1)


def mock_argv(*argv):
    from unittest import mock
    return mock.patch("sys.argv", list(argv))


if __name__ == "__main__":
    unittest.main()
