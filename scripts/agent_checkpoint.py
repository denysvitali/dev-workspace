#!/usr/bin/env python3
"""Private Codex/Claude checkpoints, scoped to the conversation (no API calls)."""
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


def repeated_failure(state, event):
    """Warn once per identical explicit tool-error streak; never block a turn."""
    if event.get("hook_event_name") not in ("PostToolUse", "PostToolUseFailure"):
        return ""
    result = event.get("tool_response", {})
    failed = event.get("hook_event_name") == "PostToolUseFailure"
    if isinstance(result, dict):
        failed = failed or result.get("isError") is True or result.get("is_error") is True
        failed = failed or (isinstance(result.get("exit_code"), int) and result["exit_code"] != 0)
    if not failed:
        state.pop("failure_streak", None)
        return ""
    signature = hashlib.sha256(json.dumps([event.get("tool_name"), event.get("tool_input"),
                                           event.get("error", result)], sort_keys=True).encode()).hexdigest()
    old = state.get("failure_streak", {})
    count = old.get("count", 0) + 1 if old.get("signature") == signature else 1
    state["failure_streak"] = {"signature": signature, "count": count}
    if count == 3:
        return ("The same tool call has failed three times with unchanged input and error. "
                "Do not repeat it again without new evidence or a changed precondition. "
                "Try a different hypothesis or supported alternative, or record the concrete blocker; "
                "keep unfinished tasks pending and continue independent authorized work.")
    return ""


def text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c["text"] for c in content if isinstance(c, dict)
                         and c.get("type") in ("text", "input_text", "output_text")
                         and isinstance(c.get("text"), str) and c["text"])
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


def confirmed_root(transcript, event):
    """Fail closed: inherited HAPPY_SESSION_ID is also present in subagents."""
    if "subagents" in Path(transcript).parts or event.get("agent_id"):
        return False
    try:
        with open(transcript, "rb") as stream:
            for _ in range(16):
                line = stream.readline(MAX_RECORD + 1)
                if not line or len(line) > MAX_RECORD:
                    break
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if record.get("type") == "session_meta":
                    source = record.get("payload", {}).get("source")
                    return isinstance(source, str) and source in ("cli", "exec", "vscode", "app-server")
                if record.get("type") in ("user", "assistant") and "isSidechain" in record:
                    return record["isSidechain"] is False
    except OSError:
        pass
    # Native providers can run SessionStart before creating the transcript.
    # Subagents use SubagentStart / agent_id, not this root startup event.
    return (event.get("hook_event_name") == "SessionStart"
            and event.get("source") in ("startup", "resume", "compact", "clear"))


def snapshot(event, base=None, happy_session_id=None):
    transcript = event.get("transcript_path")
    session = event.get("session_id")
    if not transcript or not session:
        return None, None
    # Include transcript identity: nested agents must never overwrite each other's state.
    legacy_key = hashlib.sha256((session + "\0" + transcript).encode()).hexdigest()[:24]
    happy = os.environ.get("HAPPY_SESSION_ID", "") if happy_session_id is None else happy_session_id
    shared = bool(happy and confirmed_root(transcript, event))
    key = hashlib.sha256(("happy\0" + happy).encode()).hexdigest()[:24] if shared else legacy_key
    root = Path(base or Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "workspace-progress")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    path = root / (key + ".json")
    lock = root / (key + ".lock")
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "w") as locking:
        fcntl.flock(locking, fcntl.LOCK_EX)
        legacy = root / (legacy_key + ".json")
        previous = path if path.exists() else legacy
        state = json.loads(previous.read_text()) if previous.exists() else {
            "session_id": session, "transcript": transcript, "offset": 0,
            "goal": "", "user_updates": [], "progress": [], "tools": []}
        restored = False
        if state.get("transcript") != transcript:
            # Only a new lifecycle/user event can transfer ownership. Late
            # PostToolUse/Stop hooks from the old process cannot roll it back.
            if event.get("hook_event_name") not in ("SessionStart", "UserPromptSubmit"):
                return None, None
            state.update(session_id=session, transcript=transcript, offset=0)
            restored = True
        if shared:
            state["happy_session_id"] = happy
            # Keep the already-instructed private note usable during migration.
            note, old_note = path.with_suffix(".notes.md"), legacy.with_suffix(".notes.md")
            if not note.exists() and old_note.is_file() and note != old_note:
                note.symlink_to(old_note.name)
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
                            elif role == "assistant" and message and payload.get("channel") != "analysis":
                                if not progress or progress[-1] != message[:2000]:
                                    progress.append(message[:2000])
                        if kind in ("function_call", "custom_tool_call"):
                            tools.append({"name": payload.get("name"), "call_id": payload.get("call_id")})
                        # Hidden reasoning and raw tool arguments/results are intentionally excluded.
                    elif record.get("type") in ("user", "assistant") and not record.get("isSidechain"):
                        payload = record.get("message", {})
                        if not isinstance(payload, dict):
                            continue
                        content = payload.get("content", "")
                        # text_content deliberately excludes tool results and thinking.
                        message = text_content(content)
                        if record["type"] == "user" and message and not message.startswith(("<task-notification>", "<system-reminder>", "# AGENTS.md instructions")):
                            if not state["goal"]:
                                state["goal"] = message[:4000]
                            if not users or users[-1] != message[:2500]:
                                users.append(message[:2500])
                        elif record["type"] == "assistant" and message:
                            if not progress or progress[-1] != message[:2000]:
                                progress.append(message[:2000])
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
        notice = repeated_failure(state, event)
        atomic_write(path, state)
        state["restored"] = restored  # Response-only; never persisted as a repeated instruction.
        state["notice"] = notice
    return path, state


def restoration(path, state):
    note = path.with_suffix(".notes.md")
    parts = ["Session recovery checkpoint (local transcript evidence; verify current files and task status).",
             f"Checkpoint: {path}\nUpdate your own durable progress note at: {note}",
             "Initial goal: " + state.get("goal", "")[:1200],
             "Recent user instructions:\n" + "\n".join(state.get("user_updates", [])[-4:])[-1800:],
             "Latest reported progress:\n" + "\n".join(state.get("progress", [])[-3:])[-900:]]
    if note.is_file():
        with note.open() as stream:
            saved = stream.read(6000)
            if len(saved) > 4000:
                saved = saved[:2000] + "\n[Middle of note omitted; read the note for full state.]\n" + saved[-2000:]
            parts.append("Durable task state:\n" + saved)
    guidance = Path(__file__).resolve().parent.parent / "agent-guidance/progress.md"
    if guidance.is_file():
        parts.append(guidance.read_text()[:1800])
    return "\n\n".join(parts)[:10000]


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    event = json.load(sys.stdin)
    path, state = snapshot(event)
    if path and (event.get("hook_event_name") == "SessionStart" or state.get("restored")):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event["hook_event_name"],
                                                 "additionalContext": restoration(path, state)}}))
    elif path and state.get("notice"):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": event["hook_event_name"],
                                                 "additionalContext": state["notice"]}}))


if __name__ == "__main__":
    main()
