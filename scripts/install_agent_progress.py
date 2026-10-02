#!/usr/bin/env python3
"""Install shared progress guidance and additive Claude checkpoint hooks."""
import argparse
import json
from pathlib import Path

BEGIN = "<!-- workspace-progress:begin -->"
END = "<!-- workspace-progress:end -->"


def install(home, repository):
    guidance = (repository / "agent-guidance/progress.md").read_text().strip()
    for relative in (".codex/AGENTS.md", ".claude/CLAUDE.md"):
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        text = path.read_text() if path.exists() else ""
        block = f"{BEGIN}\n{guidance}\n{END}"
        if BEGIN in text:
            before, rest = text.split(BEGIN, 1)
            if END not in rest:
                raise ValueError(f"Unclosed progress block in {path}")
            text = before + block + rest.split(END, 1)[1]
        else:
            text = text.rstrip() + "\n\n" + block + "\n"
        if len(text.encode()) >= 24 * 1024:
            raise ValueError(f"Guidance exceeds 24 KiB: {path}")
        path.write_text(text)
    settings = home / ".claude/settings.json"
    config = json.loads(settings.read_text()) if settings.exists() else {}
    hooks = config.setdefault("hooks", {})
    command = f"python3 {repository / 'scripts/agent_checkpoint.py'}"
    for event in ("SessionStart", "PreCompact", "PostToolUse", "PostToolUseFailure", "Stop", "UserPromptSubmit"):
        entries = hooks.setdefault(event, [])
        if any(h.get("command") == command for entry in entries for h in entry.get("hooks", [])):
            continue
        entries.append({"hooks": [{"type": "command", "command": command, "timeout": 10}]})
    settings.write_text(json.dumps(config, indent=2) + "\n")
    settings.chmod(0o600)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    install(args.home, Path(__file__).resolve().parent.parent)
