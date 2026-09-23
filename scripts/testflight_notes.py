#!/usr/bin/env python3
"""Validate PR notes and snapshot them for confirmed TestFlight publications.

Uses only Python's standard library, git, and the workflow's GITHUB_TOKEN.
State lives on separate testflight-state/<platform> branches, never main.
"""

from __future__ import annotations

import argparse
import base64
import copy
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

START = "<!-- release-notes:start -->"
END = "<!-- release-notes:end -->"
MAX_UNITS = 4000
FALLBACK = "No user-visible changes in this build."
PLATFORMS = ("IOS", "MAC_OS")


class NotesError(Exception):
    """An actionable validation or publication-state error."""


def check_length(text: str) -> None:
    # Count UTF-16 units conservatively so emoji cannot exceed our field limit.
    if len(text.encode("utf-16-le")) // 2 > MAX_UNITS:
        raise NotesError("Release notes exceed 4,000 characters; shorten them.")


def extract_notes(body: str | None) -> str | None:
    """Return tester-facing plain text, or None for an explicit opt-out."""
    body = (body or "").replace("\r\n", "\n").replace("\r", "\n")
    if body.count(START) != 1 or body.count(END) != 1:
        raise NotesError("Include exactly one pair of release-notes markers.")
    before, rest = body.split(START)
    notes, after = rest.split(END) if END in rest else (None, None)
    if notes is None:
        raise NotesError("Release-notes markers are in the wrong order.")
    # Markers inside fenced examples must not pass as the actual section.
    if re.search(r"(?m)^\s*(```|~~~)", before):
        fences = re.findall(r"(?m)^\s*(```|~~~)", before)
        if len(fences) % 2:
            raise NotesError("Release-notes markers cannot be inside a fence.")
    notes = "\n".join(line.rstrip() for line in notes.strip().splitlines())
    if notes == "None":
        return None
    if not notes or not re.search(r"\w", notes):
        raise NotesError("Write tester-facing notes or the exact word None.")
    if re.search(r"(?im)^\s*(?:[-*]\s*)?none\s*$", notes):
        raise NotesError("Use None alone, or write actual release notes.")
    if re.search(r"\b(TODO|TBD|PLACEHOLDER)\b|describe (the )?user-visible", notes, re.I):
        raise NotesError("Replace the release-notes template placeholder.")
    if "<!--" in notes or "-->" in notes or re.search(r"(?m)^\s*(```|~~~)", notes):
        raise NotesError("Use plain text, not comments or code fences, for notes.")
    if any(ord(char) < 32 and char not in "\n\t" for char in notes):
        raise NotesError("Release notes contain control characters.")
    check_length(notes)
    return notes


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode:
        raise NotesError("git failed: " + result.stderr.strip())
    return result.stdout.strip()


def require_ancestor(base: str, head: str) -> None:
    for sha in (base, head):
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise NotesError("Expected a full commit SHA in publication state.")
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head], capture_output=True
    )
    if result.returncode:
        raise NotesError(
            "The last published commit is not an ancestor of this build. "
            "Do not rerun an older release or rewind publication state. "
            "Check that checkout uses fetch-depth: 0."
        )


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository or "") or not token:
            raise NotesError("GITHUB_REPOSITORY and GH_TOKEN are required.")
        self.repository = repository
        self.root = "https://api.github.com/repos/" + repository
        self.token = token

    def request(self, method, path, data=None, missing=False):
        request = urllib.request.Request(
            self.root + path,
            data=None if data is None else json.dumps(data).encode(),
            method=method,
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
                "User-Agent": "meh.md-testflight-notes",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise NotesError(
                f"GitHub {method} {path} failed (HTTP {error.code}). "
                "Check token permissions/state-branch rules and retry."
            ) from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise NotesError("GitHub request failed; retry the workflow.") from error

    def pages(self, path):
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            items = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            if not isinstance(items, list):
                raise NotesError("Unexpected GitHub pagination response.")
            yield from items
            if len(items) < 100:
                return
            page += 1


def collect_notes(api: GitHub, base: str, head: str) -> tuple[str, list[dict]]:
    """Follow the built history, never the latest PR or merge timestamps."""
    require_ancestor(base, head)
    commits = git("rev-list", "--reverse", "--first-parent", f"{base}..{head}").splitlines()
    included = set(git("rev-list", f"{base}..{head}").splitlines())
    entries = {}
    for sha in commits:
        prs = [
            pr for pr in api.pages(f"/commits/{sha}/pulls")
            if pr.get("merged_at")
            and pr.get("base", {}).get("ref") == "main"
            and pr.get("base", {}).get("repo", {}).get("full_name") == api.repository
            and pr.get("merge_commit_sha") in included
        ]
        if not prs:
            raise NotesError(
                f"Commit {sha[:12]} has no merged main PR in this release. "
                "Release changes through a PR with notes; do not silently omit them."
            )
        for pr in sorted(prs, key=lambda item: item["number"]):
            number = pr["number"]
            if number not in entries:
                try:
                    notes = extract_notes(pr.get("body"))
                except NotesError as error:
                    raise NotesError(f"PR #{number}: {error}") from error
                entries[number] = {"number": number, "notes": notes}
    text = "\n\n".join(entry["notes"] for entry in entries.values() if entry["notes"])
    text = text or FALLBACK
    check_length(text)
    return text, list(entries.values())


class State:
    """Git-backed snapshots, atomically committed with the success pointer.

    Each platform has its own orphan branch. Non-forced ref updates reject
    concurrent writers instead of overwriting them. The workflow serializes
    main releases; files are always read from an exact state commit.
    """

    def __init__(self, api, platform):
        self.api = api
        self.branch = "testflight-state/" + platform
        ref = api.request("GET", "/git/ref/heads/" + self.branch, missing=True)
        self.head = ref["object"]["sha"] if ref else None

    def read(self, path):
        if self.head is None:
            return None
        item = self.api.request(
            "GET", f"/contents/{path}?ref={self.head}", missing=True
        )
        if item is None:
            return None
        if item.get("encoding") != "base64":
            raise NotesError("Unexpected publication-state file encoding.")
        return json.loads(base64.b64decode(item["content"]))

    def write(self, files):
        tree = {"tree": [
            {"path": path, "mode": "100644", "type": "blob",
             "content": json.dumps(value, indent=2, ensure_ascii=False) + "\n"}
            for path, value in files.items()
        ]}
        if self.head:
            commit = self.api.request("GET", "/git/commits/" + self.head)
            tree["base_tree"] = commit["tree"]["sha"]
        tree_sha = self.api.request("POST", "/git/trees", tree)["sha"]
        commit_sha = self.api.request("POST", "/git/commits", {
            "message": "Record TestFlight release notes",
            "tree": tree_sha,
            "parents": [self.head] if self.head else [],
        })["sha"]
        if self.head:
            self.api.request("PATCH", "/git/refs/heads/" + self.branch, {
                "sha": commit_sha, "force": False,
            })
        else:
            self.api.request("POST", "/git/refs", {
                "ref": "refs/heads/" + self.branch, "sha": commit_sha,
            })
        self.head = commit_sha


def check_snapshot(snapshot, repository, platform, sha, run_id):
    expected = {"schema": 1, "repository": repository, "platform": platform,
                "sha": sha, "run_id": str(run_id), "locale": "en-US"}
    if any(snapshot.get(key) != value for key, value in expected.items()):
        raise NotesError("Stored notes do not match this repository/build/run.")
    if not isinstance(snapshot.get("notes"), str) or not snapshot["notes"]:
        raise NotesError("Stored notes are empty or invalid.")
    check_length(snapshot["notes"])


def prepare(api, state, platform, sha, run_id, bootstrap):
    path = f"runs/{run_id}.json"
    snapshot = state.read(path)
    if snapshot:
        check_snapshot(snapshot, api.repository, platform, sha, run_id)
        if snapshot.get("publication"):
            return snapshot  # A successful matrix leg must not upload again.
    latest = state.read("latest.json")
    baseline = latest["sha"] if latest else bootstrap[platform]["sha"]
    require_ancestor(baseline, sha)
    if snapshot:
        return snapshot  # Keep the exact original text even after PR edits.
    text, prs = collect_notes(api, baseline, sha)
    snapshot = {"schema": 1, "repository": api.repository, "platform": platform,
                "sha": sha, "run_id": str(run_id), "baseline": baseline,
                "locale": "en-US", "notes": text, "pull_requests": prs,
                "publication": None}
    # Snapshot BEFORE contacting Apple. This must succeed before uploading.
    state.write({path: snapshot})
    return snapshot


def confirm(state, snapshot, publication):
    path = f"runs/{snapshot['run_id']}.json"
    stored = state.read(path)
    if stored != snapshot:
        raise NotesError("Publication snapshot changed; refusing to advance state.")
    if stored.get("publication"):
        return stored
    latest = state.read("latest.json")
    if latest:
        require_ancestor(latest["sha"], snapshot["sha"])
    result = copy.deepcopy(snapshot)
    result["publication"] = publication
    # Notes + receipt + baseline advance together in one Git commit/ref update.
    state.write({path: result, "latest.json": result})
    return result


def write_snapshot(directory, snapshot):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "notes.txt").write_text(snapshot["notes"], encoding="utf-8")
    (directory / "manifest.json").write_text(
        json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--event", type=Path, required=True)
    for name in ("prepare", "confirm"):
        sub = commands.add_parser(name)
        sub.add_argument("--platform", choices=PLATFORMS, required=True)
        sub.add_argument("--directory", type=Path, required=True)
        if name == "prepare":
            sub.add_argument("--bootstrap", type=Path,
                             default=Path(".github/testflight/notes-bootstrap.json"))
        else:
            sub.add_argument("--build-id", required=True)
            sub.add_argument("--version", required=True)
            sub.add_argument("--build-number", required=True)
    summary = commands.add_parser("summary")
    summary.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "validate":
        event = json.loads(args.event.read_text(encoding="utf-8"))
        extract_notes(event["pull_request"].get("body"))
        print("Release notes are valid.")
        return
    if args.command == "summary":
        snapshot = json.loads((args.directory / "manifest.json").read_text())
        status = "Confirmed publication" if snapshot["publication"] else "Prepared; not confirmed"
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(f"\n### TestFlight notes ({snapshot['platform']})\n\n{status}\n\n")
            output.write("<pre>" + html.escape(snapshot["notes"]) + "</pre>\n\n")
            output.write(f"Commit: `{snapshot['sha']}`; baseline: `{snapshot['baseline']}`\n")
        return
    api = GitHub(os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GH_TOKEN"))
    sha, run_id = os.environ["GITHUB_SHA"], os.environ["GITHUB_RUN_ID"]
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise NotesError("Expected a numeric GITHUB_RUN_ID.")
    state = State(api, args.platform)
    if args.command == "prepare":
        snapshot = prepare(api, state, args.platform, sha, run_id,
                           json.loads(args.bootstrap.read_text()))
        write_snapshot(args.directory, snapshot)
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("already_published=" + str(bool(snapshot["publication"])).lower() + "\n")
    else:
        snapshot = json.loads((args.directory / "manifest.json").read_text())
        check_snapshot(snapshot, api.repository, args.platform, sha, run_id)
        if not re.fullmatch(r"[\w-]+", args.build_id):
            raise NotesError("Invalid confirmed Apple build ID.")
        result = confirm(state, snapshot, {
            "build_id": args.build_id, "version": args.version,
            "build_number": args.build_number,
            "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        })
        write_snapshot(args.directory, result)


if __name__ == "__main__":
    try:
        main()
    except (NotesError, ValueError, KeyError, OSError) as error:
        # Do not print PR text, tokens, or API response bodies into Actions logs.
        print(f"TestFlight notes: {error}", file=sys.stderr)
        sys.exit(1)
