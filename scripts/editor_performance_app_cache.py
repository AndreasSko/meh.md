#!/usr/bin/env python3
"""Content-address the compiled probe; never reuse an unverified app bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid


EXECUTABLE = "EditorQuoteCheck"


def digest_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def digest_files(files):
    digest = hashlib.sha256()
    for name, path in sorted(files):
        for value in (name.encode(), path.read_bytes()):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


def cache_key(repo, sources, compiler, sdk, target, scenario, host):
    patterns = ("Sources/**/*.swift", "meh.md/*.swift", "Tools/EditorQuoteCheck/*.swift",
                "Tools/EditorQuoteCheck/Info.plist", "Package.swift", "Package.resolved",
                "scripts/run_editor_performance*.sh", "scripts/editor_performance_app_cache.py")
    paths = {path for pattern in patterns for path in repo.glob(pattern) if path.is_file()}
    files = [(path.relative_to(repo).as_posix(), path) for path in paths]
    # Historical editor comparisons compile selected files from another ref.
    files += [("compiled-sources/" + path.name, path) for path in sources.glob("*.swift")]
    content = digest_files(files)
    config = json.dumps([content, compiler, sdk, target, scenario, host], separators=(",", ":"))
    return hashlib.sha256(config.encode()).hexdigest()


def bundle_digest(app):
    if not (app / EXECUTABLE).is_file() or not (app / "Info.plist").is_file():
        raise ValueError("probe executable or Info.plist missing")
    files = []
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError("cached probe bundle must not contain symlinks")
        if path.is_file():
            files.append((path.relative_to(app).as_posix(), path))
    return digest_files(files)


def lookup(cache, key, destination):
    try:
        metadata = json.loads((cache / (key + ".json")).read_text())
        entry = metadata["entry"]
        if (metadata["key"] != key or not isinstance(entry, str)
                or not re.fullmatch(re.escape(key) + r"--[0-9a-f]{32}", entry)):
            return False
        app = cache / entry / "Editor Quote Check.app"
        if (digest_file(app / EXECUTABLE) != metadata["executable_sha256"]
                or bundle_digest(app) != metadata["bundle_sha256"]):
            return False
    except (OSError, ValueError, KeyError, TypeError):
        return False
    shutil.copytree(app, destination, dirs_exist_ok=True)
    # Verify the copied executable/bundle too; a concurrent tamper is fatal.
    if (digest_file(destination / EXECUTABLE) != metadata["executable_sha256"]
            or bundle_digest(destination) != metadata["bundle_sha256"]):
        raise ValueError("copied cached probe failed integrity validation")
    return True


def store(cache, key, app):
    metadata = {"key": key, "executable_sha256": digest_file(app / EXECUTABLE),
                "bundle_sha256": bundle_digest(app), "entry": key + "--" + uuid.uuid4().hex}
    cache.mkdir(parents=True, exist_ok=True)
    # Unique immutable entries let simultaneous writers/readers finish safely.
    entry = cache / metadata["entry"]
    shutil.copytree(app, entry / "Editor Quote Check.app")
    with tempfile.NamedTemporaryFile(mode="w", dir=cache, delete=False) as file:
        json.dump(metadata, file, sort_keys=True)
        temporary = file.name
    os.replace(temporary, cache / (key + ".json"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    key_parser = commands.add_parser("key")
    for name in ("repo", "sources", "compiler", "sdk", "target", "scenario", "host"):
        key_parser.add_argument("--" + name, required=True)
    for name in ("lookup", "store"):
        command = commands.add_parser(name)
        command.add_argument("--cache", type=Path, required=True)
        command.add_argument("--key", required=True)
        command.add_argument("--app", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.command == "key":
        print(cache_key(Path(arguments.repo), Path(arguments.sources), arguments.compiler,
                        arguments.sdk, arguments.target, arguments.scenario, arguments.host))
    else:
        if not re.fullmatch(r"[0-9a-f]{64}", arguments.key):
            parser.error("cache key must contain 64 lowercase hexadecimal digits")
        if arguments.command == "lookup":
            try:
                return 0 if lookup(arguments.cache, arguments.key, arguments.app) else 1
            except (OSError, ValueError) as error:
                print(f"cache copy integrity failure: {error}", file=sys.stderr)
                return 2
        store(arguments.cache, arguments.key, arguments.app)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
