"""Unit tests for scripts/load_data.py (synthetic fixtures, no network)."""
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _support as S
import load_data as ld


class EndpointNormalization(unittest.TestCase):
    def test_bare_host(self):
        self.assertEqual(ld.execute_endpoint("6b1b5999.cloud.dittolive.app"),
                         ("6b1b5999.cloud.dittolive.app", "/api/v5/store/execute"))

    def test_host_with_app_path_and_scheme(self):
        self.assertEqual(ld.execute_endpoint("https://6b1b5999.cloud.dittolive.app/1e83-app"),
                         ("6b1b5999.cloud.dittolive.app", "/1e83-app/api/v5/store/execute"))

    def test_trailing_slash_and_full_api_path(self):
        self.assertEqual(
            ld.execute_endpoint("https://h.example/app/api/v5/store/execute/"),
            ("h.example", "/app/api/v5/store/execute"))

    def test_uppercase_scheme_and_http_forced_to_https(self):
        self.assertEqual(ld.execute_endpoint("HTTPS://H.EXAMPLE/app"), ("H.EXAMPLE", "/app/api/v5/store/execute"))
        host, _ = ld.execute_endpoint("http://h.example")
        self.assertEqual(host, "h.example")


class AnchorExtraction(unittest.TestCase):
    def test_classification(self):
        with tempfile.TemporaryDirectory() as td:
            bench = S.make_synthetic_benchmarks(Path(td))
            orders, uuids, emails = ld.extract_anchor_literals(bench)
        self.assertIn(S.ANCHOR_ORDER, orders)
        self.assertIn(S.ANCHOR_CUSTOMER_UUID, uuids)
        self.assertIn(S.ANCHOR_ITEM, uuids)       # resolved to items later
        self.assertIn(S.PHANTOM_UUID, uuids)      # store rls id — phantom
        self.assertIn(S.ANCHOR_EMAIL, emails)
        # index names / DQL keywords are not captured as anchors
        self.assertFalse(any("orders_cust" in o for o in orders))
        self.assertNotIn("orders_cust", uuids)


class StrideSlicing(unittest.TestCase):
    """Synthetic dataset: 100 orders, total_orders=100. A stride of 10 picks
    exactly lines {0,10,...,90}; every anchor is deliberately off-stride."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.dataset = S.make_synthetic_dataset(root / "data")
        self.bench = S.make_synthetic_benchmarks(root)
        self.empty_bench = root / "empty_benchmarks.json"
        self.empty_bench.write_text("{}")

    def tearDown(self):
        self._tmp.cleanup()

    def plan(self, n=10, bench=None, full_catalog=False):
        return ld.plan_slices(n, self.dataset, bench or self.bench,
                              full_catalog, total_orders=S.N_ORDERS)

    def test_exact_stride_count_without_anchors(self):
        plan = ld.plan_slices(10, self.dataset, self.empty_bench, False,
                              total_orders=S.N_ORDERS)
        self.assertEqual(len(plan["order_ids"]), 10)

    def test_determinism(self):
        a, b = self.plan(), self.plan()
        self.assertEqual(a["order_ids"], b["order_ids"])
        self.assertEqual(a["customer_ids"], b["customer_ids"])

    def test_all_stores_and_full_timeline_at_tiny_size(self):
        plan = self.plan(10)
        docs = [d for d, _ in ld.collection_docs("orders", self.dataset, plan)]
        self.assertEqual({d["store_id"] for d in docs}, set(S.STORE_IDS))
        years = {d["order_date"][:4] for d in docs}
        self.assertIn("2022", years)
        self.assertIn("2025", years)

    def test_anchors_always_included(self):
        plan = self.plan(10)
        self.assertIn(S.ANCHOR_ORDER, plan["order_ids"])               # by-id literal
        self.assertIn(S.ANCHOR_ITEM_PARENT, plan["order_ids"])         # parent of item anchor
        self.assertIn(S.ANCHOR_ITEM, plan["item_ids"])                 # item literal resolved
        self.assertIn(S.ANCHOR_CUSTOMER_UUID, plan["customer_ids"])    # by-customer literal
        self.assertIn(S.ANCHOR_EMAIL_CUSTOMER, plan["customer_ids"])   # email resolved
        # anchor customer's orders are pulled in too (by-customer query non-zero)
        self.assertIn(S.order_id(9), plan["order_ids"])                # customer 9, i=9
        a = plan["anchors"]
        self.assertEqual(a["phantom_literals"], 1)
        self.assertEqual(a["item_literals"], 1)

    def test_referential_integrity(self):
        plan = self.plan(10)
        orders = {d["_id"]: d for d, _ in ld.collection_docs("orders", self.dataset, plan)}
        items = [d for d, _ in ld.collection_docs("order_items", self.dataset, plan)]
        customers = {d["_id"] for d, _ in ld.collection_docs("customers", self.dataset, plan)}
        for item in items:
            self.assertIn(item["order_id"], orders)
        for order in orders.values():
            self.assertIn(order["customer_id"], customers)
        # the anchor item itself loads, and its parent order is in the slice
        self.assertIn(S.ANCHOR_ITEM, {d["_id"] for d in items})

    def test_size_covers_total_loads_everything(self):
        plan = self.plan(S.N_ORDERS)  # size >= total
        self.assertTrue(plan["all_customers"])
        customers = list(ld.collection_docs("customers", self.dataset, plan))
        self.assertEqual(len(customers), S.N_CUSTOMERS)
        orders = list(ld.collection_docs("orders", self.dataset, plan))
        self.assertEqual(len(orders), S.N_ORDERS)

    def test_full_catalog_flag(self):
        plan = self.plan(10, full_catalog=True)
        customers = list(ld.collection_docs("customers", self.dataset, plan))
        self.assertEqual(len(customers), S.N_CUSTOMERS)


class Batching(unittest.TestCase):
    def test_doc_count_cap(self):
        docs = [({"_id": str(i)}, 10) for i in range(7)]
        batches = list(ld.batched(iter(docs), max_docs=3, max_bytes=10**9))
        self.assertEqual([len(b) for b, _ in batches], [3, 3, 1])

    def test_byte_cap(self):
        docs = [({"_id": str(i)}, 100) for i in range(5)]
        batches = list(ld.batched(iter(docs), max_docs=100, max_bytes=250))
        self.assertEqual([len(b) for b, _ in batches], [2, 2, 1])

    def test_single_doc_over_byte_cap_ships_alone(self):
        docs = [({"_id": "big"}, 500), ({"_id": "s"}, 10)]
        batches = list(ld.batched(iter(docs), max_docs=100, max_bytes=250))
        self.assertEqual([len(b) for b, _ in batches], [1, 1])

    def test_empty(self):
        self.assertEqual(list(ld.batched(iter([]), 10, 10)), [])


class BigPeerClientTest(unittest.TestCase):
    def client(self, fake):
        return ld.BigPeerClient("h.example", "/api/v5/store/execute", "KEY",
                                conn_factory=fake.factory, sleep=lambda _: None)

    def test_success_single_request_with_auth_and_body(self):
        fake = S.FakeHTTP([(200, S.OK_BODY)])
        res = self.client(fake).execute("SELECT * FROM stores", {"x": 1})
        self.assertEqual(res["queryType"], "insert")  # canned body
        self.assertEqual(len(fake.requests), 1)
        req = fake.requests[0]
        self.assertEqual(req["headers"]["Authorization"], "Bearer KEY")
        sent = json.loads(req["body"])
        self.assertEqual(sent["statement"], "SELECT * FROM stores")
        self.assertEqual(sent["args"], {"x": 1})

    def test_retryable_statuses_then_success(self):
        for status in (408, 429, 500, 503, 504):
            fake = S.FakeHTTP([(status, b"busy"), (200, S.OK_BODY)])
            res = self.client(fake).execute("SELECT 1")
            self.assertEqual(res["queryType"], "insert")
            self.assertEqual(len(fake.requests), 2, f"status {status}")
            self.assertEqual(fake.connections, 2)  # connection dropped between retries

    def test_fatal_statuses_not_retried(self):
        for status in (400, 401, 403, 404, 413, 422):
            fake = S.FakeHTTP([(status, b'{"error": "nope"}')])
            with self.assertRaises(ld.FatalApiError):
                self.client(fake).execute("SELECT 1")
            self.assertEqual(len(fake.requests), 1, f"status {status}")

    def test_network_error_retried_until_exhausted(self):
        fake = S.FakeHTTP([OSError("boom")] * 6)
        with self.assertRaises(RuntimeError):
            self.client(fake).execute("SELECT 1")
        self.assertEqual(len(fake.requests), 6)

    def test_non_json_200_is_retried_then_succeeds(self):
        fake = S.FakeHTTP([(200, b"<html>proxy error</html>"), (200, S.OK_BODY)])
        res = self.client(fake).execute("SELECT 1")
        self.assertEqual(res["queryType"], "insert")
        self.assertEqual(len(fake.requests), 2)

    def test_non_json_200_exhausts(self):
        fake = S.FakeHTTP([(200, b"<html>")] * 6)
        with self.assertRaises(RuntimeError):
            self.client(fake).execute("SELECT 1")


class StubClient:
    """Canned execute() responses for clear()/verify()."""

    def __init__(self, handler):
        self.handler = handler
        self.statements: list[str] = []

    def execute(self, statement, args=None):
        self.statements.append(statement)
        return self.handler(statement)


class ClearTest(unittest.TestCase):
    def test_batches_until_zero(self):
        calls = {"n": 0}

        def handler(stmt):
            calls["n"] += 1
            n = 30000 if calls["n"] == 1 else 0
            return {"mutatedDocumentIds": [f"id{i}" for i in range(n)]}

        client = StubClient(handler)
        with contextlib.redirect_stdout(io.StringIO()):
            ld.clear(client, {"orders"})
        self.assertEqual(client.statements,
                         ["DELETE FROM orders LIMIT 30000"] * 2)

    def test_empty_collection_single_call(self):
        client = StubClient(lambda stmt: {"mutatedDocumentIds": []})
        with contextlib.redirect_stdout(io.StringIO()):
            ld.clear(client, {"stores"})
        self.assertEqual(client.statements, ["DELETE FROM stores LIMIT 30000"])


class VerifyTest(unittest.TestCase):
    def run_verify(self, counts, expected):
        def handler(stmt):
            for name in ld.LOAD_ORDER:
                if f"FROM {name}" in stmt:
                    return {"items": [{"count": counts.get(name, 0)}]}
            raise AssertionError(stmt)
        client = StubClient(handler)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ok = ld.verify(client, expected, set(expected))
        return ok, out.getvalue()

    def test_match(self):
        ok, _ = self.run_verify({"orders": 5}, {"orders": 5})
        self.assertTrue(ok)

    def test_mismatch(self):
        ok, text = self.run_verify({"orders": 4}, {"orders": 5})
        self.assertFalse(ok)
        self.assertIn("MISMATCH", text)


class ArgumentValidation(unittest.TestCase):
    """Flag validation fires before any filesystem/network work."""

    def run_main(self, argv):
        with mock.patch("sys.argv", ["load_data.py"] + argv):
            with self.assertRaises(SystemExit) as cm:
                with contextlib.redirect_stderr(io.StringIO()):
                    ld.main()
            return cm.exception.code

    def test_nonpositive_concurrency(self):
        self.assertEqual(self.run_main(["--size", "1k", "--concurrency", "0"]), 2)

    def test_clear_with_size_rejected(self):
        self.assertEqual(self.run_main(["--clear", "--size", "1k"]), 2)

    def test_dry_run_alone_rejected(self):
        self.assertEqual(self.run_main(["--dry-run"]), 2)

    def test_unknown_collection_rejected(self):
        self.assertEqual(self.run_main(["--size", "1k", "--only", "bogus"]), 2)

    def test_no_action_rejected(self):
        self.assertEqual(self.run_main([]), 2)


class DryRunSmoke(unittest.TestCase):
    """End-to-end argparse -> planning -> printed table, hermetic + offline."""

    def test_dry_run_against_synthetic_dataset(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            dataset = S.make_synthetic_dataset(root / "data")
            bench = S.make_synthetic_benchmarks(root)
            argv = ["load_data.py", "--size", "1k", "--dry-run",
                    "--dataset-dir", str(dataset), "--benchmarks", str(bench),
                    "--total-orders", str(S.N_ORDERS)]
            out = io.StringIO()
            with mock.patch("sys.argv", argv), contextlib.redirect_stdout(out):
                rc = ld.main()
            text = out.getvalue()
        self.assertEqual(rc, 0)
        # size 1k (1000) >= synthetic total (100) -> everything loads
        self.assertIn("orders", text)
        self.assertIn(f"{S.N_ORDERS} docs", text)
        self.assertIn("phantom", text)


if __name__ == "__main__":
    unittest.main()
