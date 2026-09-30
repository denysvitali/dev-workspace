#!/usr/bin/env python3
"""Incremental, private session checkpoints for Codex lifecycle hooks (no API calls)."""
import argparse
from collections import deque
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MAX_RECORD = 1024 * 1024


def text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def atomic_write(path, state):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def snapshot(event, base=None):
    transcript = event.get("transcript_path")
    session = event.get("session_id")
    if not transcript or not session:
        return None, None
    # Include transcript identity: nested agents must never overwrite each other's state.
    key = hashlib.sha256((session + "\0" + transcript).encode()).hexdigest()[:24]
    root = Path(base or Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "workspace-progress")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    path = root / (key + ".json")
    lock = root / (key + ".lock")
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "w") as locking:
        fcntl.flock(locking, fcntl.LOCK_EX)
        state = json.loads(path.read_text()) if path.exists() else {
            "session_id": session, "transcript": transcript, "offset": 0,
            "goal": "", "user_updates": [], "progress": [], "tools": []}
        if state.get("format_version") != 2:
            state["offset"] = 0
            state["format_version"] = 2
        source = Path(transcript)
        if source.is_file():
            size = source.stat().st_size
            offset = state.get("offset", 0)
            if size < offset:
                offset = 0  # A rewritten transcript must be read again.
            users = deque(state.get("user_updates", []), maxlen=6)
            progress = deque(state.get("progress", []), maxlen=6)
            tools = deque(state.get("tools", []), maxlen=8)
            with source.open("rb") as stream:
                stream.seek(offset)
                while True:
                    start = stream.tell()
                    line = stream.readline(MAX_RECORD + 1)
                    if not line:
                        break
                    if len(line) > MAX_RECORD:
                        while line and not line.endswith(b"\n"):
                            line = stream.readline(MAX_RECORD + 1)
                        continue  # Skip huge tool results without loading them.
                    if not line.endswith(b"\n"):
                        stream.seek(start)
                        break  # Do not advance past a concurrent partial write.
                    try:
                        record = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue
                    payload = record.get("payload", {})
                    if record.get("type") == "event_msg":
                        kind = payload.get("type")
                        if kind == "user_message":
                            message = text_content(payload.get("message", ""))
                            if message:
                                if not state["goal"]:
                                    state["goal"] = message[:4000]
                                if not users or users[-1] != message[:2500]:
                                    users.append(message[:2500])
                        elif kind == "agent_message":
                            message = text_content(payload.get("message", ""))
                            if message and (not progress or progress[-1] != message[:2000]):
                                progress.append(message[:2000])
                    elif record.get("type") == "response_item":
                        kind = payload.get("type")
                        if kind == "message":
                            message = text_content(payload.get("content", ""))
                            role = payload.get("role")
                            if role == "user" and message and not message.startswith(("# AGENTS.md instructions", "<environment_context>")):
                                if not state["goal"]:
                                    state["goal"] = message[:4000]
                                if not users or users[-1] != message[:2500]:
                                    users.append(message[:2500])
                            elif role == "assistant" and message:
                                if not progress or progress[-1] != message[:2000]:
                                    progress.append(message[:2000])
                        if kind in ("function_call", "custom_tool_call"):
                            tools.append({"name": payload.get("name"), "call_id": payload.get("call_id")})
                        # Hidden reasoning and raw tool arguments/results are intentionally excluded.
                state["offset"] = stream.tell()
            state.update(user_updates=list(users), progress=list(progress), tools=list(tools))
        state["cwd"] = event.get("cwd", state.get("cwd"))
        state["updated_at"] = datetime.now(timezone.utc).isoformat()
        state["event"] = event.get("hook_event_name")
        state["turn_id"] = event.get("turn_id")
        if event.get("hook_event_name") in ("PreCompact", "Stop", "SessionStart"):
            try:
                cwd = state.get("cwd") or "."
                branch = subprocess.check_output(["git", "-C", cwd, "branch", "--show-current"], stderr=subprocess.DEVNULL, timeout=3).decode().strip()
                head = subprocess.check_output(["git", "-C", cwd, "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, timeout=3).decode().strip()
                state["git"] = {"branch": branch, "head": head}
            except (OSError, subprocess.SubprocessError):
                pass
        atomic_write(path, state)
    return path, state


def restoration(path, state):
    note = path.with_suffix(".notes.md")
    parts = ["Session recovery checkpoint (local transcript evidence; verify current files and task status).",
             f"Checkpoint: {path}\nUpdate your own durable progress note at: {note}",
             "Initial goal: " + state.get("goal", "")[:2000],
             "Recent user instructions:\n" + "\n".join(state.get("user_updates", [])[-4:])[-3500:],
             "Latest reported progress:\n" + "\n".join(state.get("progress", [])[-3:])[-2000:]]
    if note.is_file():
        with note.open() as stream:
            parts.insert(2, "Durable task state:\n" + stream.read(6000))
    return "\n\n".join(parts)[:10000]


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    event = json.load(sys.stdin)
    path, state = snapshot(event)
    if path and event.get("hook_event_name") == "SessionStart":
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                 "additionalContext": restoration(path, state)}}))


if __name__ == "__main__":
    main()
