#!/usr/bin/env python3
"""Install instruction checks without replacing existing repository hooks."""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import subprocess


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def install(repo):
    repo = Path(repo).resolve()
    git_dir = Path(git(repo, "rev-parse", "--absolute-git-dir"))
    managed = git_dir / "workspace-agent-hooks"
    state = managed / "original.json"
    configured = subprocess.run(["git", "-C", str(repo), "config", "--get", "core.hooksPath"],
                                capture_output=True, text=True).stdout.strip()
    if state.exists() and configured == str(managed):
        original = Path(json.loads(state.read_text())["directory"])
    else:
        original = Path(configured) if configured else git_dir / "hooks"
        if not original.is_absolute():
            original = repo / original
        original = original.resolve()
        if original == managed:
            raise ValueError(f"Missing original-hook metadata in {managed}")
    managed.mkdir(exist_ok=True)
    state.write_text(json.dumps({"directory": str(original)}, indent=2) + "\n")
    # Link every other hook to the existing path, including currently absent hooks.
    names = {"applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit",
             "pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-commit",
             "pre-rebase", "post-checkout", "post-merge", "pre-push", "post-rewrite",
             "sendemail-validate", "fsmonitor-watchman", "post-index-change"}
    if original.is_dir():
        names.update(p.name for p in original.iterdir() if not p.name.endswith(".sample"))
    for name in names - {"pre-commit"}:
        link = managed / name
        if link.is_symlink():
            link.unlink()
        if not link.exists():
            link.symlink_to(original / name)
    checker = Path(__file__).resolve().with_name("check_agent_guidance.py")
    prior = shlex.quote(str(original / "pre-commit"))
    hook = managed / "pre-commit"
    hook.write_text("#!/bin/sh\nset -e\n" +
                    f"python3 {shlex.quote(str(checker))} --staged\n" +
                    f'if [ -x {prior} ]; then {prior} "$@"; fi\n')
    hook.chmod(0o755)
    subprocess.run(["git", "-C", str(repo), "config", "--local", "core.hooksPath", str(managed)], check=True)


def install_template(directory=None):
    """Preserve the current template and add a guard for future clones/inits."""
    destination = Path(directory or Path.home() / ".local/share/workspace-agent-git-template").resolve()
    current = subprocess.run(["git", "config", "--global", "--get", "init.templateDir"],
                             capture_output=True, text=True).stdout.strip()
    original = Path(current).expanduser() if current else Path("/usr/share/git-core/templates")
    if not destination.exists():
        if original.is_dir() and original.resolve() != destination:
            shutil.copytree(original, destination, symlinks=True)
        else:
            destination.mkdir(parents=True)
    hooks = destination / "hooks"
    hooks.mkdir(exist_ok=True)
    hook = hooks / "pre-commit"
    marker = "# workspace-agent-guidance-guard"
    previous = hooks / "pre-commit.before-agent-guard"
    if hook.exists() and marker not in hook.read_text():
        if previous.exists():
            raise ValueError("Existing template hook backup would be overwritten")
        hook.rename(previous)
    checker = Path(__file__).resolve().with_name("check_agent_guidance.py")
    hook.write_text("#!/bin/sh\n" + marker + "\nset -e\n" +
                    f"python3 {shlex.quote(str(checker))} --staged\n" +
                    'prior="$(dirname "$0")/pre-commit.before-agent-guard"\n' +
                    'if [ -x "$prior" ]; then "$prior" "$@"; fi\n')
    hook.chmod(0o755)
    subprocess.run(["git", "config", "--global", "init.templateDir", str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--future", action="store_true", help="Also preserve/install a Git template for future checkouts")
    args = parser.parse_args()
    repos = sorted(p for p in args.root.iterdir() if (p / ".git").is_dir())
    for repo in repos:
        install(repo)
    if args.future:
        install_template()
    print(f"Installed guidance guard in {len(repos)} primary repositories; existing hooks preserved")


if __name__ == "__main__":
    main()
