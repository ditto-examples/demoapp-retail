"""Integration tests for the loader's slicing against the REAL benchmark
dataset (../dql-metrics-benchmark). Skipped when the sibling repo is absent;
purely local reads (no network) — a full planning pass streams ~100 MB.
"""
import datetime
import unittest
from pathlib import Path

import _support as S
import load_data as ld

DATASET = S.REPO_ROOT.parent / "dql-metrics-benchmark" / "benchmarks" / "retail"
BENCHMARKS = S.REPO_ROOT / "shared" / "benchmarks.json"

# The literals the loader must anchor (from benchmarks.json):
ANCHOR_ORDER = "order_20250115_0001"                     # orders__select__by_id
ANCHOR_ITEM = "705d8eda-4606-4551-b505-5d230d38aa8a"     # order_items__select__by_id
ANCHOR_CUSTOMER = "e652232a-95ab-4fcf-86b7-e40cea3d749d"  # by_id / by_email (john21@example.net)


@unittest.skipUnless(DATASET.exists(), "benchmark dataset repo not checked out next to this repo")
@unittest.skipUnless(BENCHMARKS.exists(), "shared/benchmarks.json missing — run scripts/sync_benchmarks.sh")
class RealDatasetPlan(unittest.TestCase):
    """Invariants that make the demo work at every size (PLAN §3.2)."""

    @classmethod
    def setUpClass(cls):
        cls.plan = ld.plan_slices(1_000, DATASET, BENCHMARKS, full_catalog=False)
        cls.orders = {d["_id"]: d
                      for d, _ in ld.collection_docs("orders", DATASET, cls.plan)}

    def test_order_count_is_1k_plus_anchors(self):
        self.assertGreaterEqual(len(self.plan["order_ids"]), 1_000)
        self.assertLessEqual(len(self.plan["order_ids"]), 1_100)

    def test_all_8_stores_represented(self):
        stores = {d["store_id"] for d in self.orders.values()}
        self.assertEqual(len(stores), 8, f"stores: {sorted(stores)}")

    def test_stride_spans_full_timeline(self):
        dates = sorted(d["order_date"] for d in self.orders.values())
        first = datetime.date.fromisoformat(dates[0][:10])
        last = datetime.date.fromisoformat(dates[-1][:10])
        self.assertGreaterEqual((last - first).days, 700)  # ~2.5 years of data

    def test_anchor_documents_included(self):
        self.assertIn(ANCHOR_ORDER, self.plan["order_ids"])
        self.assertIn(ANCHOR_ITEM, self.plan["item_ids"])
        self.assertIn(ANCHOR_CUSTOMER, self.plan["customer_ids"])
        a = self.plan["anchors"]
        self.assertGreaterEqual(a["phantom_literals"], 1)  # store rls_user_id

    def test_referential_integrity(self):
        customers = {d["_id"] for d, _ in ld.collection_docs("customers", DATASET, self.plan)}
        for order in self.orders.values():
            self.assertIn(order["customer_id"], customers)
        items = 0
        for d, _ in ld.collection_docs("order_items", DATASET, self.plan):
            self.assertIn(d["order_id"], self.plan["order_ids"])
            items += 1
        self.assertGreater(items, 1_500)  # ~2 items/order at 1k

    def test_determinism(self):
        again = ld.plan_slices(1_000, DATASET, BENCHMARKS, full_catalog=False)
        self.assertEqual(self.plan["order_ids"], again["order_ids"])
        self.assertEqual(self.plan["customer_ids"], again["customer_ids"])

    def test_100k_is_full_variant_verbatim(self):
        plan = ld.plan_slices(100_000, DATASET, BENCHMARKS, full_catalog=False)
        self.assertTrue(plan["all_customers"])
        self.assertEqual(len(plan["order_ids"]), 100_000)


if __name__ == "__main__":
    unittest.main()
