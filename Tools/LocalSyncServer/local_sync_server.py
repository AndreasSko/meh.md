#!/usr/bin/env python3
"""Durable loopback HTTP record store for local sync development."""

from __future__ import annotations

import argparse
import base64
import binascii
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit
import uuid


MAX_REQUEST_BYTES = 16 * 1024 * 1024
MAX_RESPONSE_BYTES = 24 * 1024 * 1024
MAX_PAGE_SIZE = 1_000
DEFAULT_PAGE_SIZE = 100


def encode_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


class StoreError(Exception):
    def __init__(self, code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


class WorkspaceStore:
    """Atomic, append-ordered workspace state stored beneath one directory."""

    def __init__(
        self,
        root: Path,
        max_response_bytes: int = MAX_RESPONSE_BYTES,
    ) -> None:
        if max_response_bytes < 1:
            raise ValueError("max_response_bytes must be positive")
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.max_response_bytes = max_response_bytes
        self._lock = threading.RLock()

    def bootstrap(
        self,
        scope: object,
        record: object,
        protocol_version: int = 1,
    ) -> dict[str, Any]:
        checked_scope = self._validate_scope(scope)
        checked_version = self._validate_protocol_version(protocol_version)
        checked_record = self._validate_record(record, checked_version)
        if checked_version == 2 and checked_record["kind"] != "catalog":
            raise StoreError(
                "invalid_record",
                "Version 2 bootstrap records must contain a catalog.",
            )
        storage_scope = self._storage_scope(checked_scope, checked_version)
        with self._lock:
            state = self._load(storage_scope, checked_version)
            seed_id = state["seedID"]
            if seed_id is not None:
                return self._record_by_id(state, seed_id)

            self._bind_notebook(state, checked_record, checked_version)
            self._append(state, checked_record)
            state["seedID"] = checked_record["id"]
            self._write(storage_scope, state)
            return checked_record

    def publish(
        self,
        scope: object,
        record: object,
        protocol_version: int = 1,
    ) -> None:
        checked_scope = self._validate_scope(scope)
        checked_version = self._validate_protocol_version(protocol_version)
        checked_record = self._validate_record(record, checked_version)
        storage_scope = self._storage_scope(checked_scope, checked_version)
        with self._lock:
            state = self._load(storage_scope, checked_version)
            if checked_version == 2 and state["seedID"] is None:
                raise StoreError(
                    "bootstrap_required",
                    "Version 2 workspaces require a catalog bootstrap.",
                    409,
                )
            self._bind_notebook(state, checked_record, checked_version)
            if (
                checked_version == 2
                and checked_record["kind"] == "note"
                and checked_record["snapshot"]["noteID"]
                in state["deletedNoteIDs"]
            ):
                return
            if self._append(state, checked_record):
                self._write(storage_scope, state)

    def purge_deleted_notes(
        self,
        scope: object,
        notebook_id: object,
        note_ids: object,
    ) -> None:
        checked_scope = self._validate_scope(scope)
        checked_notebook_id = self._validate_uuid(
            notebook_id, "The notebook identifier is invalid."
        )
        checked_note_ids = self._validate_uuid_list(note_ids)
        storage_scope = self._storage_scope(checked_scope, 2)
        with self._lock:
            state = self._load(storage_scope, 2)
            if state["seedID"] is None:
                raise StoreError(
                    "bootstrap_required",
                    "Version 2 workspaces require a catalog bootstrap.",
                    409,
                )
            if state["notebookID"] != checked_notebook_id:
                raise StoreError(
                    "notebook_conflict",
                    "The cleanup belongs to a different notebook.",
                    409,
                )

            deleted = set(state["deletedNoteIDs"])
            deleted.update(checked_note_ids)
            state["deletedNoteIDs"] = sorted(deleted)
            state["records"] = [
                None
                if record is not None
                and record["kind"] == "note"
                and record["snapshot"]["noteID"] in deleted
                else record
                for record in state["records"]
            ]
            self._write(storage_scope, state)

    def fetch(
        self,
        scope: object,
        cursor: object = None,
        limit: object = DEFAULT_PAGE_SIZE,
        protocol_version: int = 1,
    ) -> dict[str, Any]:
        checked_scope = self._validate_scope(scope)
        checked_limit = self._validate_limit(limit)
        checked_version = self._validate_protocol_version(protocol_version)
        storage_scope = self._storage_scope(checked_scope, checked_version)
        with self._lock:
            state = self._load(storage_scope, checked_version)
            offset = self._decode_cursor(storage_scope, cursor)
            records = state["records"]
            if offset > len(records):
                raise StoreError(
                    "invalid_cursor",
                    "The cursor points beyond the workspace history.",
                )
            maximum_end = min(offset + checked_limit, len(records))
            low = offset
            high = maximum_end
            while low < high:
                candidate = (low + high + 1) // 2
                page = self._page(storage_scope, records, offset, candidate)
                if len(encode_json(page)) <= self.max_response_bytes:
                    low = candidate
                else:
                    high = candidate - 1

            if low == offset and offset < maximum_end:
                raise StoreError(
                    "record_too_large",
                    "A stored record exceeds the response-size limit.",
                    500,
                )
            return self._page(storage_scope, records, offset, low)

    def _page(
        self,
        scope: str,
        records: list[dict[str, Any] | None],
        offset: int,
        end: int,
    ) -> dict[str, Any]:
        return {
            "records": [
                record for record in records[offset:end] if record is not None
            ],
            "cursor": self._encode_cursor(scope, end),
            "hasMore": end < len(records),
        }

    def _path(self, scope: str) -> Path:
        name = hashlib.sha256(scope.encode("utf-8")).hexdigest() + ".json"
        return self.root / name

    def _load(self, scope: str, protocol_version: int) -> dict[str, Any]:
        path = self._path(scope)
        if not path.exists():
            state = {
                "version": protocol_version,
                "scope": scope,
                "seedID": None,
                "records": [],
            }
            if protocol_version == 2:
                state["notebookID"] = None
                state["deletedNoteIDs"] = []
            return state
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
            if (
                state.get("version") != protocol_version
                or state.get("scope") != scope
                or not isinstance(state.get("records"), list)
                or not (
                    state.get("seedID") is None
                    or isinstance(state.get("seedID"), str)
                )
            ):
                raise ValueError("invalid workspace envelope")
            if protocol_version == 1 and any(
                item is None for item in state["records"]
            ):
                raise ValueError("version 1 workspace contains tombstones")
            checked_records = [
                None
                if item is None
                else self._validate_record(item, protocol_version)
                for item in state["records"]
            ]
            live_records = [
                item for item in checked_records if item is not None
            ]
            if len({item["id"] for item in live_records}) != len(
                live_records
            ):
                raise ValueError("duplicate record identifier")
            seed_id = state["seedID"]
            if seed_id is not None and seed_id not in {
                item["id"] for item in live_records
            }:
                raise ValueError("missing seed record")
            if protocol_version == 2:
                notebook_id = state.get("notebookID")
                if not isinstance(notebook_id, str):
                    raise ValueError("missing notebook identifier")
                parsed_notebook_id = str(uuid.UUID(notebook_id)).upper()
                if any(
                    item["notebookID"] != parsed_notebook_id
                    for item in live_records
                ):
                    raise ValueError("mixed notebook identifiers")
                if seed_id is not None and self._record_by_id(
                    {"records": live_records}, seed_id
                )["kind"] != "catalog":
                    raise ValueError("version 2 seed is not a catalog")
                deleted_note_ids = self._validate_uuid_list(
                    state.get("deletedNoteIDs", [])
                )
                if any(
                    item["kind"] == "note"
                    and item["snapshot"]["noteID"] in deleted_note_ids
                    for item in live_records
                ):
                    raise ValueError("deleted note body remains stored")
                state["notebookID"] = parsed_notebook_id
                state["deletedNoteIDs"] = deleted_note_ids
            state["records"] = checked_records
            return state
        except StoreError as error:
            raise StoreError(
                "storage_corrupt",
                f"The workspace store contains an invalid record: {error.message}",
                500,
            ) from error
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
            raise StoreError(
                "storage_corrupt",
                f"The workspace store is invalid: {error}",
                500,
            ) from error

    def _write(self, scope: str, state: dict[str, Any]) -> None:
        payload = encode_json(state)
        target = self._path(scope)
        file_descriptor, temporary_name = tempfile.mkstemp(
            dir=self.root,
            prefix=target.name + ".",
            suffix=".tmp",
        )
        try:
            with os.fdopen(file_descriptor, "wb") as temporary:
                temporary.write(payload)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary_name, target)
            directory_descriptor = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass

    def _append(
        self,
        state: dict[str, Any],
        record: dict[str, Any],
    ) -> bool:
        for existing in state["records"]:
            if existing is None:
                continue
            if existing["id"] != record["id"]:
                continue
            if existing != record:
                raise StoreError(
                    "immutable_record_conflict",
                    "A different record already uses this identifier.",
                    409,
                )
            return False
        state["records"].append(record)
        return True

    def _record_by_id(
        self,
        state: dict[str, Any],
        record_id: str,
    ) -> dict[str, Any]:
        for record in state["records"]:
            if record is None:
                continue
            if record["id"] == record_id:
                return record
        raise StoreError(
            "storage_corrupt",
            "The workspace seed record is missing.",
            500,
        )

    @staticmethod
    def _validate_scope(value: object) -> str:
        if not isinstance(value, str) or not value or len(value) > 256:
            raise StoreError(
                "invalid_scope",
                "Scope must contain between 1 and 256 characters.",
            )
        if any(ord(character) < 32 for character in value):
            raise StoreError(
                "invalid_scope",
                "Scope must not contain control characters.",
            )
        return value

    @staticmethod
    def _validate_protocol_version(value: object) -> int:
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value not in (1, 2)
        ):
            raise StoreError(
                "invalid_protocol_version",
                "Protocol version must be 1 or 2.",
            )
        return value

    @staticmethod
    def _storage_scope(scope: str, protocol_version: int) -> str:
        if protocol_version == 1:
            return scope
        # External scopes cannot contain control characters, so this namespace
        # can never collide with an existing version 1 workspace name.
        return "\0meh-notebook-v2\0" + scope

    @staticmethod
    def _bind_notebook(
        state: dict[str, Any],
        record: dict[str, Any],
        protocol_version: int,
    ) -> None:
        if protocol_version == 1:
            return
        notebook_id = state["notebookID"]
        if notebook_id is None:
            state["notebookID"] = record["notebookID"]
        elif notebook_id != record["notebookID"]:
            raise StoreError(
                "notebook_conflict",
                "The record belongs to a different notebook.",
                409,
            )

    @staticmethod
    def _validate_limit(value: object) -> int:
        try:
            limit = int(value)
        except (TypeError, ValueError) as error:
            raise StoreError("invalid_limit", "Limit must be an integer.") from error
        if not 1 <= limit <= MAX_PAGE_SIZE:
            raise StoreError(
                "invalid_limit",
                f"Limit must be between 1 and {MAX_PAGE_SIZE}.",
            )
        return limit

    @staticmethod
    def _validate_uuid(value: object, message: str) -> str:
        if not isinstance(value, str):
            raise StoreError("invalid_record", message)
        try:
            return str(uuid.UUID(value)).upper()
        except ValueError as error:
            raise StoreError("invalid_record", message) from error

    @classmethod
    def _validate_uuid_list(cls, value: object) -> list[str]:
        if not isinstance(value, list) or len(value) > 100_000:
            raise StoreError(
                "invalid_record", "Deleted note identifiers are invalid."
            )
        checked = [
            cls._validate_uuid(
                item, "A deleted note identifier is invalid."
            )
            for item in value
        ]
        if len(set(checked)) != len(checked):
            raise StoreError(
                "invalid_record", "Deleted note identifiers must be unique."
            )
        return sorted(checked)

    @staticmethod
    def _validate_record(
        value: object,
        protocol_version: int = 1,
    ) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise StoreError("invalid_record", "Record must be a JSON object.")
        record_id = value.get("id")
        snapshot = value.get("snapshot")
        if (
            not isinstance(record_id, str)
            or len(record_id) != 64
            or any(character not in "0123456789abcdef" for character in record_id)
            or not isinstance(snapshot, dict)
        ):
            raise StoreError("invalid_record", "Record shape is invalid.")

        encoded_data = snapshot.get("data")
        note_id = snapshot.get("noteID")
        heads = snapshot.get("heads")
        if (
            not isinstance(encoded_data, str)
            or not isinstance(note_id, str)
            or not isinstance(heads, list)
            or any(not isinstance(head, str) for head in heads)
            or len(set(heads)) != len(heads)
        ):
            raise StoreError("invalid_record", "Snapshot shape is invalid.")
        try:
            raw_data = base64.b64decode(encoded_data, validate=True)
            parsed_note_id = uuid.UUID(note_id)
        except (binascii.Error, ValueError) as error:
            raise StoreError(
                "invalid_record",
                "Snapshot data or note identifier is invalid.",
            ) from error
        if protocol_version == 1:
            if value.get("protocolVersion", 1) != 1:
                raise StoreError(
                    "invalid_record",
                    "Record protocol version does not match the route.",
                )
            if value.get("kind", "note") != "note" or value.get(
                "notebookID"
            ) is not None:
                raise StoreError(
                    "invalid_record",
                    "Version 1 records must use the legacy note shape.",
                )
            digest_input = raw_data
        else:
            kind = value.get("kind")
            notebook_id = value.get("notebookID")
            if value.get("protocolVersion") != 2 or kind not in (
                "note",
                "catalog",
            ):
                raise StoreError(
                    "invalid_record",
                    "Version 2 record metadata is invalid.",
                )
            if not isinstance(notebook_id, str):
                raise StoreError(
                    "invalid_record",
                    "Version 2 records require a notebook identifier.",
                )
            try:
                parsed_notebook_id = uuid.UUID(notebook_id)
            except ValueError as error:
                raise StoreError(
                    "invalid_record",
                    "The notebook identifier is invalid.",
                ) from error
            if kind == "catalog" and parsed_note_id != parsed_notebook_id:
                raise StoreError(
                    "invalid_record",
                    "A catalog document must identify its notebook.",
                )
            prefix = (
                "meh-notebook-v2\n"
                + kind
                + "\n"
                + str(parsed_notebook_id).upper()
                + "\n"
                + str(parsed_note_id).upper()
                + "\n"
            ).encode("utf-8")
            digest_input = prefix + raw_data

        if hashlib.sha256(digest_input).hexdigest() != record_id:
            raise StoreError(
                "invalid_record",
                "Record identifier does not match the snapshot data.",
            )
        if any(not head or len(head) > 256 for head in heads):
            raise StoreError("invalid_record", "Snapshot heads are invalid.")

        checked = {
            "id": record_id,
            "snapshot": {
                "data": base64.b64encode(raw_data).decode("ascii"),
                "heads": sorted(heads),
                "noteID": str(parsed_note_id).upper()
                if protocol_version == 2
                else str(parsed_note_id),
            },
        }
        if protocol_version == 2:
            checked.update(
                {
                    "protocolVersion": 2,
                    "kind": kind,
                    "notebookID": str(parsed_notebook_id).upper(),
                }
            )
        return checked

    def _encode_cursor(self, scope: str, offset: int) -> str:
        value = {
            "n": offset,
            "s": hashlib.sha256(scope.encode("utf-8")).hexdigest(),
            "v": 1,
        }
        raw = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    def _decode_cursor(self, scope: str, value: object) -> int:
        if value is None:
            return 0
        if not isinstance(value, str) or not value or len(value) > 512:
            raise StoreError("invalid_cursor", "The cursor is malformed.")
        try:
            padding = "=" * (-len(value) % 4)
            raw = base64.b64decode(value + padding, altchars=b"-_", validate=True)
            cursor = json.loads(raw)
            expected_scope = hashlib.sha256(scope.encode("utf-8")).hexdigest()
            if (
                cursor.get("v") != 1
                or cursor.get("s") != expected_scope
                or not isinstance(cursor.get("n"), int)
                or isinstance(cursor.get("n"), bool)
                or cursor["n"] < 0
            ):
                raise ValueError("invalid cursor fields")
            return cursor["n"]
        except (
            binascii.Error,
            UnicodeDecodeError,
            json.JSONDecodeError,
            AttributeError,
            ValueError,
        ) as error:
            raise StoreError(
                "invalid_cursor",
                "The cursor is malformed or belongs to another workspace.",
            ) from error


class SyncRequestHandler(BaseHTTPRequestHandler):
    server_version = "MehLocalSync/1"
    protocol_version = "HTTP/1.1"

    @property
    def store(self) -> WorkspaceStore:
        return self.server.store  # type: ignore[attr-defined]

    def do_POST(self) -> None:
        try:
            body = self._read_json_body()
            path = self.path
            if path in ("/v1/bootstrap", "/v2/bootstrap"):
                version = 1 if path.startswith("/v1/") else 2
                record = self.store.bootstrap(
                    body.get("scope"),
                    body.get("record"),
                    version,
                )
                self._send_json(200, record)
            elif path in ("/v1/records", "/v2/records"):
                version = 1 if path.startswith("/v1/") else 2
                self.store.publish(
                    body.get("scope"),
                    body.get("record"),
                    version,
                )
                self._send_json(200, {"stored": True})
            elif path == "/v2/purge":
                self.store.purge_deleted_notes(
                    body.get("scope"),
                    body.get("notebookID"),
                    body.get("noteIDs"),
                )
                self._send_json(200, {"stored": True})
            else:
                raise StoreError("not_found", "The route does not exist.", 404)
        except StoreError as error:
            self._send_error(error)

    def do_GET(self) -> None:
        try:
            parsed = urlsplit(self.path)
            if parsed.path not in ("/v1/records", "/v2/records"):
                raise StoreError("not_found", "The route does not exist.", 404)
            version = 1 if parsed.path.startswith("/v1/") else 2
            query = parse_qs(parsed.query, keep_blank_values=True)
            if any(len(values) != 1 for values in query.values()):
                raise StoreError("invalid_query", "Query values must be unique.")
            unknown = set(query) - {"scope", "after", "limit"}
            if unknown:
                raise StoreError("invalid_query", "The query contains unknown keys.")
            result = self.store.fetch(
                self._single(query, "scope"),
                self._single(query, "after", required=False),
                self._single(
                    query,
                    "limit",
                    required=False,
                    default=str(DEFAULT_PAGE_SIZE),
                ),
                version,
            )
            self._send_json(200, result)
        except StoreError as error:
            self._send_error(error)

    def _read_json_body(self) -> dict[str, Any]:
        content_length = self.headers.get("Content-Length")
        if content_length is None:
            raise StoreError("length_required", "Content-Length is required.", 411)
        try:
            length = int(content_length)
        except ValueError as error:
            raise StoreError("invalid_length", "Content-Length is invalid.") from error
        if length < 0 or length > MAX_REQUEST_BYTES:
            raise StoreError(
                "request_too_large",
                f"Requests are limited to {MAX_REQUEST_BYTES} bytes.",
                413,
            )
        try:
            value = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise StoreError("invalid_json", "The request body is invalid JSON.") from error
        if not isinstance(value, dict):
            raise StoreError("invalid_json", "The request body must be an object.")
        return value

    @staticmethod
    def _single(
        query: dict[str, list[str]],
        key: str,
        *,
        required: bool = True,
        default: str | None = None,
    ) -> str | None:
        if key not in query:
            if required:
                raise StoreError("invalid_query", f"Query parameter {key} is required.")
            return default
        return query[key][0]

    def _send_error(self, error: StoreError) -> None:
        self._send_json(
            error.status,
            {"error": error.code, "message": error.message},
        )

    def _send_json(self, status: int, value: object) -> None:
        payload = encode_json(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} - {format % args}")


class LocalSyncHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: WorkspaceStore) -> None:
        super().__init__(address, SyncRequestHandler)
        self.store = store


class DataDirectoryLock:
    """Prevents two service processes from rewriting the same state files."""

    def __init__(self, root: Path) -> None:
        self.path = root.resolve() / ".local-sync-server.lock"
        self._file = None

    def __enter__(self) -> DataDirectoryLock:
        lock_file = self.path.open("a+", encoding="utf-8")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            lock_file.close()
            raise StoreError(
                "data_directory_locked",
                "Another local sync service is using this data directory.",
                500,
            ) from error
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(str(os.getpid()) + "\n")
        lock_file.flush()
        os.fsync(lock_file.fileno())
        self._file = lock_file
        return self

    def __exit__(self, *args: object) -> None:
        if self._file is None:
            return
        fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
        self._file.close()
        self._file = None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-dir",
        type=Path,
        required=True,
        help="directory containing durable workspace state",
    )
    parser.add_argument("--port", type=int, default=8765)
    arguments = parser.parse_args()
    if not 0 <= arguments.port <= 65_535:
        parser.error("--port must be between 0 and 65535")

    store = WorkspaceStore(arguments.data_dir)
    try:
        with DataDirectoryLock(store.root):
            server = LocalSyncHTTPServer(
                ("127.0.0.1", arguments.port),
                store,
            )
            host, port = server.server_address
            print(
                f"Local sync service listening on http://{host}:{port}",
                flush=True,
            )
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
    except StoreError as error:
        parser.error(error.message)


if __name__ == "__main__":
    main()
