"""Tests for the targeted order-items store-id backfill command."""
import tempfile
import unittest
from pathlib import Path

import _support as S
import backfill_order_item_store_ids as backfill


class BackfillMappingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dataset = S.make_synthetic_bundle(Path(self.tmp.name) / "data")

    def tearDown(self):
        self.tmp.cleanup()

    def test_derives_store_id_from_parent_orders(self):
        grouped = backfill.order_item_store_ids(self.dataset)
        self.assertEqual({store: len(ids) for store, ids in grouped.items()},
                         {"store_a": 2, "store_b": 4, "store_c": 6})

    def test_update_is_bounded_to_the_supplied_ids(self):
        statement = backfill.update_statement("store_a", ["item_10", "item_11"])
        self.assertEqual(
            statement,
            "UPDATE order_items SET store_id = 'store_a' "
            "WHERE _id IN ('item_10', 'item_11')",
        )

    def test_unsafe_identifier_is_rejected(self):
        with self.assertRaises(ValueError):
            backfill.update_statement("bad store", ["item_1"])
