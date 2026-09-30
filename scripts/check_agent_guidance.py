#!/usr/bin/env python3
"""Bound instruction files and their inherited chain, including Git symlinks."""
import argparse
import os
from pathlib import Path, PurePosixPath
import subprocess

FILE_LIMIT = 24 * 1024
CHAIN_LIMIT = 28 * 1024
NAMES = {"agents.md", "agents.override.md", "claude.md"}


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def check(repo, staged=False):
    repo = Path(repo)
    entries = {}
    if staged:
        for entry in git(repo, "ls-files", "--stage", "-z").split(b"\0"):
            if entry:
                metadata, name = entry.split(b"\t", 1)
                mode, oid, stage = metadata.decode().split()
                if stage != "0":
                    raise ValueError("Resolve the unmerged index before checking guidance")
                entries[os.fsdecode(name)] = (mode, oid)
    else:
        entries = {os.fsdecode(p): None for p in git(
            repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z"
        ).split(b"\0") if p}

    def read(name, seen=()):
        if name in seen or len(seen) > 16:
            raise ValueError(f"cyclic guidance symlink: {name}")
        if staged:
            if name not in entries:
                raise ValueError(f"guidance target is absent from index: {name}")
            mode, oid = entries[name]
            data = git(repo, "cat-file", "blob", oid)
            if mode == "120000":
                target = os.fsdecode(data)
                name2 = os.path.normpath(str(PurePosixPath(name).parent / target))
                if os.path.isabs(target) or name2 == ".." or name2.startswith("../"):
                    raise ValueError(f"guidance symlink leaves repository: {name}")
                return read(name2, (*seen, name))
            return data
        path = repo / name
        if not path.resolve().is_relative_to(repo.resolve()):
            raise ValueError(f"guidance symlink leaves repository: {name}")
        return path.read_bytes()

    guides, errors = {}, []
    for name in sorted(entries):
        if PurePosixPath(name).name.lower() not in NAMES:
            continue
        try:
            size = len(read(name))
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            errors.append(f"{name}: {exc}")
            continue
        guides[name] = size
        if size > FILE_LIMIT:
            errors.append(f"{name}: {size} bytes > individual limit {FILE_LIMIT}; move details to references")
    directories = {PurePosixPath(name).parent for name in guides}
    selected = {}
    for directory in directories:
        for filename in ("AGENTS.override.md", "AGENTS.md", "CLAUDE.md"):
            name = str(directory / filename)
            if name in guides:
                selected[directory] = name
                break
    for directory in sorted(directories):
        parents = [directory, *directory.parents]
        chain = [selected[p] for p in reversed(parents) if p in selected]
        size = sum(guides[p] for p in chain)
        if size > CHAIN_LIMIT:
            errors.append(f"{directory}: inherited chain {size} bytes > {CHAIN_LIMIT}: " + " + ".join(chain))
    return errors, guides


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", nargs="?", default=".")
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--all", type=Path, help="Check every primary checkout immediately under this directory")
    args = parser.parse_args()
    repos = sorted(p for p in args.all.iterdir() if (p / ".git").is_dir()) if args.all else [Path(args.repo)]
    failed = 0
    for repo in repos:
        errors, guides = check(repo, args.staged)
        if errors:
            failed += 1
            print(f"{repo}:")
            for error in errors:
                print(f"  {error}")
    print(f"Agent guidance: {len(repos)} repositories checked, {failed} failing")
    return bool(failed)


if __name__ == "__main__":
    raise SystemExit(main())
