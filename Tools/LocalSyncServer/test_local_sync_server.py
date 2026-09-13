from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from local_sync_server import (
    DataDirectoryLock,
    LocalSyncHTTPServer,
    StoreError,
    WorkspaceStore,
    encode_json,
)


def make_record(value: bytes, note_id: uuid.UUID | None = None) -> dict:
    return {
        "id": hashlib.sha256(value).hexdigest(),
        "snapshot": {
            "data": base64.b64encode(value).decode("ascii"),
            "heads": [hashlib.sha256(b"head:" + value).hexdigest()],
            "noteID": str(note_id or uuid.UUID(int=1)),
        },
    }


class WorkspaceStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.store = WorkspaceStore(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_bootstrap_is_idempotent_and_first_concurrent_seed_wins(self) -> None:
        records = [make_record(b"left"), make_record(b"right")]
        barrier = threading.Barrier(2)

        def bootstrap(record: dict) -> dict:
            barrier.wait()
            return self.store.bootstrap("workspace", record)

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(bootstrap, records))

        self.assertEqual(results[0], results[1])
        self.assertIn(results[0], records)
        self.assertEqual(
            self.store.bootstrap("workspace", records[0]),
            results[0],
        )
        self.assertEqual(self.store.fetch("workspace")["records"], [results[0]])

    def test_publish_is_idempotent_and_pagination_survives_restart(self) -> None:
        records = [make_record(f"record-{index}".encode()) for index in range(5)]
        self.store.bootstrap("workspace", records[0])
        for record in records[1:]:
            self.store.publish("workspace", record)
            self.store.publish("workspace", record)

        first = self.store.fetch("workspace", limit=2)
        restarted = WorkspaceStore(self.root)
        second = restarted.fetch("workspace", first["cursor"], limit=2)
        third = restarted.fetch("workspace", second["cursor"], limit=2)

        self.assertEqual(first["records"], records[:2])
        self.assertTrue(first["hasMore"])
        self.assertEqual(second["records"], records[2:4])
        self.assertTrue(second["hasMore"])
        self.assertEqual(third["records"], records[4:])
        self.assertFalse(third["hasMore"])

    def test_invalid_records_and_cursors_are_rejected_clearly(self) -> None:
        record = make_record(b"record")
        record["id"] = "0" * 64
        with self.assertRaisesRegex(StoreError, "does not match") as invalid:
            self.store.publish("workspace", record)
        self.assertEqual(invalid.exception.code, "invalid_record")

        with self.assertRaises(StoreError) as malformed:
            self.store.fetch("workspace", "not-a-cursor")
        self.assertEqual(malformed.exception.code, "invalid_cursor")

        first = self.store.fetch("first")
        with self.assertRaises(StoreError) as wrong_scope:
            self.store.fetch("second", first["cursor"])
        self.assertEqual(wrong_scope.exception.code, "invalid_cursor")

    def test_pages_are_bounded_by_serialized_size_and_keep_order(self) -> None:
        records = [make_record(bytes([index]) * 300) for index in range(5)]
        self.store.bootstrap("workspace", records[0])
        for record in records[1:]:
            self.store.publish("workspace", record)

        single = self.store.fetch("workspace", limit=1)
        bounded = WorkspaceStore(
            self.root,
            max_response_bytes=len(encode_json(single)) + 64,
        )
        received = []
        cursor = None
        while True:
            page = bounded.fetch("workspace", cursor, limit=5)
            self.assertLessEqual(
                len(encode_json(page)),
                bounded.max_response_bytes,
            )
            self.assertEqual(len(page["records"]), 1)
            received.extend(page["records"])
            cursor = page["cursor"]
            if not page["hasMore"]:
                break

        self.assertEqual(received, records)

    def test_data_directory_allows_only_one_service_process(self) -> None:
        with DataDirectoryLock(self.root):
            with self.assertRaises(StoreError) as conflict:
                with DataDirectoryLock(self.root):
                    pass
        self.assertEqual(conflict.exception.code, "data_directory_locked")

    def test_scopes_are_isolated_and_cannot_select_paths(self) -> None:
        first = make_record(b"first", uuid.UUID(int=1))
        second = make_record(b"second", uuid.UUID(int=2))
        self.store.bootstrap("../first", first)
        self.store.bootstrap("/tmp/second", second)

        self.assertEqual(self.store.fetch("../first")["records"], [first])
        self.assertEqual(self.store.fetch("/tmp/second")["records"], [second])
        self.assertEqual(len(list(self.root.glob("*.json"))), 2)
        self.assertEqual(list(self.root.iterdir()), list(self.root.glob("*.json")))


class HTTPServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        store = WorkspaceStore(Path(self.temporary.name))
        self.server = LocalSyncHTTPServer(("127.0.0.1", 0), store)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def test_http_round_trip_and_structured_cursor_error(self) -> None:
        record = make_record(b"over-http")
        request = Request(
            self.base_url + "/v1/bootstrap",
            data=json.dumps({"scope": "http", "record": record}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(request) as response:
            self.assertEqual(json.load(response), record)

        with urlopen(self.base_url + "/v1/records?scope=http&limit=10") as response:
            page = json.load(response)
        self.assertEqual(page["records"], [record])

        with self.assertRaises(HTTPError) as failure:
            urlopen(
                self.base_url
                + "/v1/records?scope=http&limit=10&after=invalid"
            )
        self.assertEqual(failure.exception.code, 400)
        self.assertEqual(json.load(failure.exception)["error"], "invalid_cursor")


if __name__ == "__main__":
    unittest.main()
