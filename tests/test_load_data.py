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


class BundleReading(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dataset = S.make_synthetic_bundle(Path(self._tmp.name) / "data")

    def tearDown(self):
        self._tmp.cleanup()

    def test_expected_counts_from_manifest(self):
        manifest = ld.read_manifest(self.dataset)
        counts = ld.expected_counts(self.dataset, manifest)
        self.assertEqual(counts["orders"], sum(S.STORE_ORDER_COUNTS.values()))
        self.assertEqual(counts["order_items"], 12)
        self.assertEqual(counts["product_types"], 1)

    def test_expected_counts_fall_back_to_line_counts(self):
        # No manifest at all -> count the files directly (stores get no flag).
        broken = Path(self._tmp.name) / "nomanifest"
        import shutil
        shutil.copytree(self.dataset, broken, ignore=shutil.ignore_patterns("manifest.json"))
        counts = ld.expected_counts(broken, ld.read_manifest(broken))
        self.assertEqual(counts["orders"], sum(S.STORE_ORDER_COUNTS.values()))

    def test_reads_gzip_and_plain(self):
        docs = [d for d, _ in ld.iter_ndjson(self.dataset / "orders.ndjson.gz")]
        self.assertEqual(len(docs), sum(S.STORE_ORDER_COUNTS.values()))
        plain = Path(self._tmp.name) / "plain.ndjson"
        plain.write_text('{"a": 1}\n{"a": 2}\n')
        self.assertEqual(len([d for d, _ in ld.iter_ndjson(plain)]), 2)

    def test_demo_default_stamped_exactly_once(self):
        docs = [d for d, _ in ld.collection_docs("stores", self.dataset, S.DEFAULT_STORE)]
        flagged = [d["_id"] for d in docs if d.get("demo_default") is True]
        self.assertEqual(flagged, [S.DEFAULT_STORE])
        self.assertTrue(all(d.get("demo_default") is False
                            for d in docs if d["_id"] != S.DEFAULT_STORE))

    def test_no_default_store_stamps_nothing(self):
        docs = [d for d, _ in ld.collection_docs("stores", self.dataset, None)]
        self.assertTrue(all(d.get("demo_default") is False for d in docs))

    def test_non_store_collections_pass_through_untouched(self):
        docs = [d for d, _ in ld.collection_docs("orders", self.dataset, S.DEFAULT_STORE)]
        self.assertFalse(any("demo_default" in d for d in docs))


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

    def test_clear_with_dry_run_rejected(self):
        self.assertEqual(self.run_main(["--clear", "--dry-run"]), 2)

    def test_clear_with_verify_only_rejected(self):
        self.assertEqual(self.run_main(["--clear", "--verify-only"]), 2)

    def test_unknown_collection_rejected(self):
        self.assertEqual(self.run_main(["--only", "bogus"]), 2)

    def test_nonpositive_concurrency(self):
        self.assertEqual(self.run_main(["--concurrency", "0"]), 2)


class DryRunSmoke(unittest.TestCase):
    """End-to-end argparse -> manifest/counts -> printed table, offline."""

    def test_dry_run_against_synthetic_bundle(self):
        with tempfile.TemporaryDirectory() as td:
            dataset = S.make_synthetic_bundle(Path(td) / "data")
            argv = ["load_data.py", "--dry-run", "--dataset-dir", str(dataset)]
            out = io.StringIO()
            with mock.patch("sys.argv", argv), contextlib.redirect_stdout(out):
                rc = ld.main()
            text = out.getvalue()
        self.assertEqual(rc, 0)
        self.assertIn("orders", text)
        self.assertIn(f"{sum(S.STORE_ORDER_COUNTS.values())} docs", text)
        self.assertIn(S.DEFAULT_STORE, text)


if __name__ == "__main__":
    unittest.main()
