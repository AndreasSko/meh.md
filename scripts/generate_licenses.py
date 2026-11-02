#!/usr/bin/env python3
"""Writes meh.md/OpenSourceLicenses.json, the list Settings shows.

Run it after changing a Swift package in Package.resolved:

    python3 scripts/generate_licenses.py

Every Swift package pinned in Package.resolved (and the Xcode project's
copy) gets its license and NOTICE files, and so does each git submodule it
vendors, like the C libraries in aws-crt-swift. We read them from a
shallow, blob-less git fetch at the pinned revision.

A package that ships a prebuilt Rust library (Automerge) also brings the
Rust crates compiled into it. We read their names from the library itself
(`ar t`), so build-time-only crates in Cargo.lock are left out. Each
crate's license comes from its published .crate file. Downloads are cached
in build/licenses/.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tomllib
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOLVED = [
    ROOT / "Package.resolved",
    ROOT / "meh.md.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]
OUTPUT = ROOT / "meh.md" / "OpenSourceLicenses.json"
CACHE = ROOT / "build" / "licenses"

# Swift packages that ship a prebuilt Rust library, with the Cargo.lock it
# was built from.
RUST_LOCKFILES = {"automerge-swift": "rust/Cargo.lock"}

# Crates published without a license file. Their text comes from the
# crate's repository at the release tag instead.
LICENSES_IN_REPOSITORY = {
    "automerge": ("automerge/automerge", "rust/automerge@{version}", "LICENSE"),
    # hexane lives in the automerge repository but has no release tags.
    "hexane": ("automerge/automerge", "rust/automerge@0.7.2", "LICENSE"),
    "uniffi": ("mozilla/uniffi-rs", "v{version}", "LICENSE"),
    "uniffi_core": ("mozilla/uniffi-rs", "v{version}", "LICENSE"),
}

# Crates that come from Rust's standard library, not from Cargo.lock. They
# are covered by the Rust project's own license. The tag only pins where we
# read that license text from; the text is the same across releases.
RUST_LICENSE_TAG = "1.90.0"
RUST_STD = {
    "addr2line", "adler2", "alloc", "compiler_builtins", "core", "gimli",
    "hashbrown", "object", "panic_unwind", "rustc_demangle",
    "rustc_std_workspace_alloc", "rustc_std_workspace_core", "std",
    "std_detect", "unwind",
}

LICENSE_FILE = re.compile(
    r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE|THIRD[-_]PARTY[-_A-Z]*)"
    r"([-_][A-Z0-9-]+)?(\.(txt|md|markdown|rst))?$", re.I)

# Besides the repository root and Sources/, license files in these folders
# cover vendored code, like cJSON in aws-c-common.
VENDORED_FOLDERS = {"external", "third_party", "third-party", "vendor", "vendored"}
TEST_FOLDERS = {"test", "tests"}

# Vendored files whose license is only in their leading comment.
LICENSE_HEADERS = {"aws-checksums": ["source/external/xxhash.h"]}

# Packages with a prebuilt binary we checked by hand and found covered by
# the package's own license. Other binaries stop the script.
CHECKED_BINARIES: set[str] = set()


def fetch(url: str, path: Path) -> Path:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url) as response:
            path.with_suffix(".part").write_bytes(response.read())
        path.with_suffix(".part").rename(path)
    return path


def github_raw(repo: str, revision: str, file: str) -> str:
    url = f"https://raw.githubusercontent.com/{repo}/{revision}/{file}"
    name = f"{repo.replace('/', '_')}-{revision}-{file.replace('/', '_')}"
    return fetch(url, CACHE / "github" / name).read_text(encoding="utf-8")


def git(repo: Path, *args: str) -> str:
    return run("git", "-C", repo, *args)


def git_checkout(url: str, revision: str) -> Path:
    """A bare repository with `revision` fetched; file contents load lazily."""
    repo = CACHE / "git" / hashlib.sha256(url.encode()).hexdigest()[:16]
    if not repo.exists():
        run("git", "init", "--quiet", "--bare", repo)
        git(repo, "remote", "add", "origin", url)
    try:
        git(repo, "cat-file", "-e", f"{revision}^{{commit}}")
    except subprocess.CalledProcessError:
        print(f"Fetching {url} at {revision[:12]}", file=sys.stderr)
        git(repo, "fetch", "--quiet", "--depth", "1", "--filter=blob:none",
            "origin", revision)
    return repo


def git_file(repo: Path, revision: str, path: str) -> str:
    return git(repo, "show", f"{revision}:{path}")


def license_texts(repo: Path, revision: str, name: str) -> list[str]:
    """License files at the root, under Sources/ (like llhttp in swift-nio)
    and in vendored-code folders, plus licenses kept in file headers."""
    files = git(repo, "ls-tree", "-r", "--name-only", revision).splitlines()
    texts = [git_file(repo, revision, file) for file in sorted(files)
             if is_license_file(file)]
    texts += [leading_comment(git_file(repo, revision, file))
              for file in LICENSE_HEADERS.get(name, [])]
    return texts


def is_license_file(path: str) -> bool:
    *folders, file = path.split("/")
    if not LICENSE_FILE.match(file):
        return False
    folders = [folder.lower() for folder in folders]
    return (not folders or folders[0] == "sources"
            or bool(VENDORED_FOLDERS & set(folders))
            and not TEST_FOLDERS & set(folders))


def leading_comment(source: str) -> str:
    """The text of the first /* … */ comment, without the leading stars."""
    match = re.match(r"\s*/\*(.*?)\*/", source, re.S)
    if not match:
        sys.exit("Expected a license comment at the top of a LICENSE_HEADERS file")
    return "\n".join(re.sub(r"^\s*\* ?", "", line)
                     for line in match.group(1).splitlines())


def submodules(repo: Path, revision: str, url: str) -> list[tuple[str, str]]:
    """(url, commit) of each git submodule at `revision`, recursively."""
    try:
        config = git(repo, "config", "--blob", f"{revision}:.gitmodules",
                     "--get-regexp", r"^submodule\..*\.(path|url)$")
    except subprocess.CalledProcessError:
        return []
    paths, urls = {}, {}
    for line in config.splitlines():
        key, value = line.split(" ", 1)
        name, field = key.removeprefix("submodule.").rsplit(".", 1)
        (paths if field == "path" else urls)[name] = value
    found = []
    for name, path in paths.items():
        entry = git(repo, "ls-tree", revision, path).split()
        if len(entry) < 3 or entry[1] != "commit":
            continue
        sub_url = urls[name]
        if sub_url.startswith("."):
            sub_url = urllib.parse.urljoin(url.rstrip("/") + "/", sub_url)
        found.append((sub_url, entry[2]))
    return found


def repository_name(url: str) -> str:
    return url.rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


BINARY_TARGET = re.compile(
    r'\.binaryTarget\(\s*name:\s*"[^"]+",\s*url:\s*"([^"]+)",'
    r'\s*checksum:\s*"([0-9a-f]+)"')


def linked_crates(manifest: str, identity: str) -> set[str]:
    """Crate names compiled into the package's prebuilt binary target."""
    match = BINARY_TARGET.search(manifest)
    if not match:
        sys.exit(f"No remote binary target in {identity}'s Package.swift")
    url, checksum = match.groups()
    folder = CACHE / "binaries" / checksum
    archive = fetch(url, folder / "binary.zip")
    if sha256(archive) != checksum:
        archive.unlink()
        sys.exit(f"Checksum mismatch for {url}")
    crates = set()
    with zipfile.ZipFile(archive) as zip_file:
        libraries = [name for name in zip_file.namelist()
                     if name.endswith(".a") and not name.startswith("__MACOSX/")]
        for name in libraries:
            library = folder / name.replace("/", "_")
            if not library.exists():
                library.write_bytes(zip_file.read(name))
            for thin in thin_archives(library):
                crates |= crate_names(run("ar", "t", thin).split())
    if not crates:
        sys.exit(f"Found no Rust crates in {identity}'s binary; check its format")
    return crates


def run(*command: str | Path) -> str:
    return subprocess.run([str(part) for part in command], check=True,
                          capture_output=True, encoding="utf-8").stdout


def thin_archives(library: Path) -> list[Path]:
    """`ar` can't read universal archives, so split them per architecture."""
    if run("lipo", "-info", library).startswith("Non-fat"):
        return [library]
    thin = []
    for arch in run("lipo", "-archs", library).split():
        path = library.with_suffix(f".{arch}.a")
        if not path.exists():
            run("lipo", library, "-thin", arch, "-output", path)
        thin.append(path)
    return thin


def crate_names(members: list[str]) -> set[str]:
    """Maps `serde-1a2b….serde.3c4d-cgu.0.rcgu.o` to `serde`.

    The only other members we expect are the archive index and the
    compiler-rt objects in compiler_builtins (`1a2b…-lse_cas1_acq.o`), whose
    license doesn't ask for a notice. Anything else could be bundled C code
    that needs its own entry, so it stops the script.
    """
    names, unknown = set(), []
    for member in members:
        match = re.match(r"^([a-z][a-z0-9_]*)-[0-9a-f]{16}\.", member)
        if match:
            names.add(match.group(1))
        elif member != "__.SYMDEF" and not re.match(
                r"^[0-9a-f]{16}-[a-z0-9_]+\.o$", member):
            unknown.append(member)
    if unknown:
        sys.exit(f"Unexpected objects in the Rust library: {unknown[:5]}")
    return names


def swift_license(texts: list[str]) -> str:
    """Swift packages don't declare a license, so recognize the common ones."""
    found = []
    for text in texts:
        if "Permission is hereby granted, free of charge" in text:
            found.append("MIT")
        elif "Apache License" in text and "Version 2.0" in text:
            found.append("Apache-2.0")
        elif "Mozilla Public License Version 2.0" in text:
            found.append("MPL-2.0")
        elif "Redistribution and use in source and binary forms" in text:
            found.append("BSD")
    return " AND ".join(dict.fromkeys(found)) or "See license text"


def swift_pins() -> list[dict]:
    """Remote pins from every Package.resolved, which must agree."""
    pins: dict[str, dict] = {}
    for resolved in RESOLVED:
        for pin in json.loads(resolved.read_text(encoding="utf-8"))["pins"]:
            if pin["kind"] != "remoteSourceControl":
                sys.exit(f"{pin['identity']} is a {pin['kind']} pin; "
                         "only git packages are supported")
            known = pins.setdefault(pin["identity"], pin)
            if known["state"]["revision"] != pin["state"]["revision"]:
                sys.exit(f"{pin['identity']} is pinned to different revisions; "
                         "resolve packages in Xcode and SwiftPM first")
    return sorted(pins.values(), key=lambda pin: pin["identity"])


def swift_entries(pin: dict, seen: set[tuple[str, str]]) -> list[dict]:
    """The package and the git submodules it vendors that aren't in `seen`."""
    url, state = pin["location"], pin["state"]
    revision = state["revision"]
    version = state.get("version") or state.get("branch") or revision[:12]
    repo = git_checkout(url, revision)
    entries = [swift_entry(pin["identity"], version, url, repo, revision)]
    pending = submodules(repo, revision, url)
    while pending:
        sub_url, commit = pending.pop(0)
        if (repository_name(sub_url), commit) in seen:
            continue
        seen.add((repository_name(sub_url), commit))
        sub_repo = git_checkout(sub_url, commit)
        entry = swift_entry(repository_name(sub_url), commit[:12], sub_url,
                            sub_repo, commit)
        entry["note"] = f"Included in {pin['identity']}."
        entries.append(entry)
        pending += submodules(sub_repo, commit, sub_url)
    return entries


def swift_entry(name: str, version: str, url: str, repo: Path,
                revision: str) -> dict:
    texts = license_texts(repo, revision, name)
    return {
        "name": name,
        "version": version,
        "license": swift_license(texts),
        "url": url.removesuffix(".git"),
        "texts": texts,
    }


def lock_packages(lockfile: str) -> tuple[dict[str, list[dict]], set[str]]:
    """Registry crates by name, and the names of the package's own crates."""
    registry: dict[str, list[dict]] = {}
    local = set()
    for package in tomllib.loads(lockfile)["package"]:
        name = package["name"].replace("-", "_")
        if package.get("source", "").startswith("registry+"):
            registry.setdefault(name, []).append(package)
        elif "source" not in package:
            local.add(name)
    return registry, local


def crate_entry(package: dict) -> dict:
    name, version = package["name"], package["version"]
    crate = fetch(
        f"https://static.crates.io/crates/{name}/{name}-{version}.crate",
        CACHE / "crates" / f"{name}-{version}.crate")
    if sha256(crate) != package["checksum"]:
        sys.exit(f"Checksum mismatch for {name} {version}")
    prefix = f"{name}-{version}/"
    texts = []
    with tarfile.open(crate) as tar:
        manifest = tomllib.loads(
            tar.extractfile(prefix + "Cargo.toml").read().decode())["package"]
        license_file = manifest.get("license-file")
        for member in sorted(tar.getmembers(), key=lambda m: m.name):
            path = member.name.removeprefix(prefix)
            if member.isfile() and ("/" not in path and LICENSE_FILE.match(path)
                                    or path == license_file):
                texts.append(tar.extractfile(member).read().decode())
    if not texts and name in LICENSES_IN_REPOSITORY:
        repo, tag, file = LICENSES_IN_REPOSITORY[name]
        texts.append(github_raw(repo, tag.format(version=version), file))
    return {
        "name": name,
        "version": version,
        "license": manifest.get("license", "See license text"),
        "url": manifest.get("repository") or f"https://crates.io/crates/{name}",
        "texts": texts,
    }


def rust_std_entry(crates: set[str]) -> dict:
    texts = [github_raw("rust-lang/rust", RUST_LICENSE_TAG, file)
             for file in ("LICENSE-MIT", "LICENSE-APACHE")]
    return {
        "name": "Rust standard library",
        "version": "",
        "license": "MIT OR Apache-2.0",
        "url": "https://github.com/rust-lang/rust",
        "note": "Includes " + ", ".join(sorted(crates)) + ".",
        "texts": texts,
    }


def generate() -> dict:
    packages, sources, seen = [], {}, set()
    for pin in swift_pins():
        identity, revision = pin["identity"], pin["state"]["revision"]
        sources[identity] = revision
        packages += swift_entries(pin, seen)
        repo = git_checkout(pin["location"], revision)
        manifest = git_file(repo, revision, "Package.swift")
        lockfile = RUST_LOCKFILES.get(identity)
        if not lockfile:
            if ".binaryTarget(" in manifest and identity not in CHECKED_BINARIES:
                sys.exit(f"{identity} ships a prebuilt binary. Check what it "
                         "contains, then add it to RUST_LOCKFILES or "
                         "CHECKED_BINARIES.")
            continue
        by_name, own = lock_packages(git_file(repo, revision, lockfile))
        linked = linked_crates(manifest, identity) - own
        std = {name for name in linked if name not in by_name}
        unknown = std - RUST_STD
        if unknown:
            sys.exit(f"Linked crates missing from {lockfile}: {sorted(unknown)}")
        for name in sorted(linked - std):
            packages += [crate_entry(package) for package in by_name[name]]
        if std:
            packages.append(rust_std_entry(std))
    missing = [f"{p['name']} {p['version']}" for p in packages if not p["texts"]]
    if missing:
        sys.exit("No license file found for: " + ", ".join(missing)
                 + ". For crates, add them to LICENSES_IN_REPOSITORY.")
    return deduplicated(packages, sources)


def deduplicated(packages: list[dict], sources: dict[str, str]) -> dict:
    """Stores each distinct license text once; packages refer to it by key."""
    texts: dict[str, str] = {}
    for package in packages:
        keys = []
        for text in package.pop("texts"):
            text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
            key = hashlib.sha256(text.encode()).hexdigest()[:12]
            texts[key] = text
            keys.append(key)
        package["texts"] = list(dict.fromkeys(keys))
    packages.sort(key=lambda package: (package["name"].lower(), package["version"]))
    return {"sources": sources, "packages": packages, "texts": texts}


def main() -> None:
    licenses = generate()
    OUTPUT.write_text(json.dumps(licenses, indent=1, ensure_ascii=False) + "\n",
                      encoding="utf-8")
    print(f"Wrote {len(licenses['packages'])} packages to "
          f"{OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
