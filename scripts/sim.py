#!/usr/bin/env python3
"""Create and clean up per-worktree simulators for local agent work.

    scripts/sim.py create iphone|ipad   print the UDID of a booted simulator
    scripts/sim.py cleanup              delete this worktree's simulators and
                                        those of worktrees that no longer exist
    scripts/sim.py list                 show agent simulators

Simulators are named meh-agent-<repo>-<worktree>-<platform>, where <repo>
identifies this clone. Parallel worktrees never share one, leftovers can be
found later, and other clones' simulators are never touched.
"""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_ui_foundation import select_simulator  # noqa: E402

PLATFORMS = ("iphone", "ipad")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def simctl_json():
    return json.loads(run("xcrun", "simctl", "list", "--json"))


def prefix():
    """Name prefix unique to this clone, shared by all of its worktrees."""
    common = Path(run("git", "rev-parse", "--git-common-dir").strip()).resolve()
    return f"meh-agent-{hashlib.sha256(str(common).encode()).hexdigest()[:6]}-"


def worktree_names():
    """Names of this clone's worktrees, leaving out deleted ones.

    Git marks a worktree whose directory is gone as prunable. Locked worktrees
    are never prunable, so they stay listed.
    """
    porcelain = run("git", "worktree", "list", "--porcelain")
    names = set()
    for entry in porcelain.strip().split("\n\n"):
        lines = entry.splitlines()
        if any(line.startswith("prunable") for line in lines):
            continue
        names.add(Path(lines[0].removeprefix("worktree ")).name)
    return names


def current_worktree():
    return Path(run("git", "rev-parse", "--show-toplevel").strip()).name


def agent_devices(inventory):
    start = prefix()
    return [
        d
        for devices in inventory["devices"].values()
        for d in devices
        if d["name"].startswith(start)
    ]


def owner(name, worktrees):
    """Return the worktree a simulator belongs to, or None if it is gone."""
    worktree, _, platform = name.removeprefix(prefix()).rpartition("-")
    if platform in PLATFORMS and worktree in worktrees:
        return worktree
    return None


def create(platform):
    inventory = simctl_json()
    name = f"{prefix()}{current_worktree()}-{platform}"
    existing = [d for d in agent_devices(inventory) if d["name"] == name]
    if existing:
        udid = existing[0]["udid"]
    else:
        runtime, device = select_simulator(inventory, platform)
        udid = run(
            "xcrun", "simctl", "create", name,
            device["identifier"], runtime["identifier"],
        ).strip()
    subprocess.run(
        ["xcrun", "simctl", "boot", udid], capture_output=True, text=True
    )
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    print(udid)


def cleanup():
    worktrees = worktree_names()
    mine = current_worktree()
    for d in agent_devices(simctl_json()):
        belongs_to = owner(d["name"], worktrees)
        if belongs_to not in (None, mine):
            continue
        subprocess.run(
            ["xcrun", "simctl", "shutdown", d["udid"]], capture_output=True
        )
        run("xcrun", "simctl", "delete", d["udid"])
        print(f"deleted {d['name']} ({d['udid']})")


def list_devices():
    worktrees = worktree_names()
    for d in agent_devices(simctl_json()):
        stale = "" if owner(d["name"], worktrees) else "  [stale]"
        print(f"{d['name']}  {d['udid']}  {d['state']}{stale}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("create").add_argument("platform", choices=PLATFORMS)
    sub.add_parser("cleanup")
    sub.add_parser("list")
    args = parser.parse_args()
    if args.command == "create":
        create(args.platform)
    elif args.command == "cleanup":
        cleanup()
    else:
        list_devices()


if __name__ == "__main__":
    main()
