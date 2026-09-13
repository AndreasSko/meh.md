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


def make_v2_record(
    value: bytes,
    notebook_id: uuid.UUID,
    document_id: uuid.UUID,
    kind: str = "note",
) -> dict:
    prefix = (
        "meh-notebook-v2\n"
        + kind
        + "\n"
        + str(notebook_id).upper()
        + "\n"
        + str(document_id).upper()
        + "\n"
    ).encode()
    return {
        "id": hashlib.sha256(prefix + value).hexdigest(),
        "snapshot": {
            "data": base64.b64encode(value).decode("ascii"),
            "heads": [hashlib.sha256(b"head:" + value).hexdigest()],
            "noteID": str(document_id).upper(),
        },
        "protocolVersion": 2,
        "kind": kind,
        "notebookID": str(notebook_id).upper(),
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

    def test_v2_catalog_and_notes_persist_with_pagination(self) -> None:
        notebook_id = uuid.UUID("628FC016-B345-4B2E-A004-1942FFB800B6")
        catalog = make_v2_record(
            b"catalog",
            notebook_id,
            notebook_id,
            "catalog",
        )
        notes = [
            make_v2_record(
                f"note-{index}".encode(),
                notebook_id,
                uuid.UUID(int=index + 10),
            )
            for index in range(3)
        ]

        self.assertEqual(
            self.store.bootstrap("workspace", catalog, 2),
            catalog,
        )
        for record in notes:
            self.store.publish("workspace", record, 2)

        first = self.store.fetch("workspace", limit=2, protocol_version=2)
        restarted = WorkspaceStore(self.root)
        second = restarted.fetch(
            "workspace",
            first["cursor"],
            limit=2,
            protocol_version=2,
        )
        self.assertEqual(first["records"], [catalog, notes[0]])
        self.assertTrue(first["hasMore"])
        self.assertEqual(second["records"], notes[1:])
        self.assertFalse(second["hasMore"])

    def test_v2_first_catalog_wins_across_fresh_proposals(self) -> None:
        first_id = uuid.UUID(int=100)
        second_id = uuid.UUID(int=101)
        first = make_v2_record(b"first", first_id, first_id, "catalog")
        second = make_v2_record(b"second", second_id, second_id, "catalog")

        self.assertEqual(self.store.bootstrap("workspace", first, 2), first)
        self.assertEqual(self.store.bootstrap("workspace", second, 2), first)
        self.assertEqual(
            self.store.fetch("workspace", protocol_version=2)["records"],
            [first],
        )

    def test_v2_publish_requires_catalog_bootstrap(self) -> None:
        notebook_id = uuid.UUID(int=110)
        note = make_v2_record(b"note", notebook_id, uuid.UUID(int=111))

        with self.assertRaises(StoreError) as failure:
            self.store.publish("workspace", note, 2)
        self.assertEqual(failure.exception.code, "bootstrap_required")

    def test_v2_rejects_bad_hash_mode_scope_and_notebook(self) -> None:
        notebook_id = uuid.UUID(int=20)
        catalog = make_v2_record(
            b"catalog",
            notebook_id,
            notebook_id,
            "catalog",
        )
        note = make_v2_record(b"note", notebook_id, uuid.UUID(int=21))

        with self.assertRaises(StoreError) as wrong_bootstrap_kind:
            self.store.bootstrap("workspace", note, 2)
        self.assertEqual(wrong_bootstrap_kind.exception.code, "invalid_record")

        bad_hash = dict(catalog)
        bad_hash["id"] = "0" * 64
        with self.assertRaises(StoreError) as invalid_hash:
            self.store.bootstrap("workspace", bad_hash, 2)
        self.assertEqual(invalid_hash.exception.code, "invalid_record")

        with self.assertRaises(StoreError) as v1_on_v2:
            self.store.publish("workspace", make_record(b"legacy"), 2)
        self.assertEqual(v1_on_v2.exception.code, "invalid_record")
        with self.assertRaises(StoreError) as v2_on_v1:
            self.store.publish("workspace", note, 1)
        self.assertEqual(v2_on_v1.exception.code, "invalid_record")

        self.store.bootstrap("workspace", catalog, 2)
        foreign = make_v2_record(
            b"foreign",
            uuid.UUID(int=22),
            uuid.UUID(int=23),
        )
        with self.assertRaises(StoreError) as wrong_notebook:
            self.store.publish("workspace", foreign, 2)
        self.assertEqual(wrong_notebook.exception.code, "notebook_conflict")

        cursor = self.store.fetch("workspace", protocol_version=2)["cursor"]
        with self.assertRaises(StoreError) as wrong_scope:
            self.store.fetch("other", cursor, protocol_version=2)
        self.assertEqual(wrong_scope.exception.code, "invalid_cursor")

        with self.assertRaises(StoreError) as unsupported_mode:
            self.store.fetch("workspace", protocol_version=3)
        self.assertEqual(
            unsupported_mode.exception.code,
            "invalid_protocol_version",
        )

    def test_same_workspace_keeps_v1_and_v2_state_isolated(self) -> None:
        legacy = make_record(b"legacy")
        notebook_id = uuid.UUID(int=30)
        catalog = make_v2_record(
            b"catalog",
            notebook_id,
            notebook_id,
            "catalog",
        )

        self.store.bootstrap("shared", legacy)
        self.store.bootstrap("shared", catalog, 2)

        self.assertEqual(self.store.fetch("shared")["records"], [legacy])
        self.assertEqual(
            self.store.fetch("shared", protocol_version=2)["records"],
            [catalog],
        )
        self.assertEqual(len(list(self.root.glob("*.json"))), 2)


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

    def test_v2_http_routes_accept_catalog_and_note_records(self) -> None:
        notebook_id = uuid.UUID(int=40)
        catalog = make_v2_record(
            b"catalog",
            notebook_id,
            notebook_id,
            "catalog",
        )
        note = make_v2_record(b"note", notebook_id, uuid.UUID(int=41))
        bootstrap = Request(
            self.base_url + "/v2/bootstrap",
            data=json.dumps(
                {"scope": "http-v2", "record": catalog}
            ).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(bootstrap) as response:
            self.assertEqual(json.load(response), catalog)

        publish = Request(
            self.base_url + "/v2/records",
            data=json.dumps({"scope": "http-v2", "record": note}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlopen(publish) as response:
            self.assertEqual(json.load(response), {"stored": True})

        with urlopen(
            self.base_url + "/v2/records?scope=http-v2&limit=1"
        ) as response:
            first = json.load(response)
        self.assertEqual(first["records"], [catalog])
        self.assertTrue(first["hasMore"])


if __name__ == "__main__":
    unittest.main()
