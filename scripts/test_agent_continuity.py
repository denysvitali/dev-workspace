import json
import tempfile
import unittest
from pathlib import Path
from agent_checkpoint import snapshot, restoration, repeated_failure
from install_agent_progress import install, BEGIN


class ContinuityTests(unittest.TestCase):
    def test_root_startup_before_transcript_exists_and_child_hook(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            old = root / "old.jsonl"
            self.write_codex(old, "old", "Keep the original goal")
            event = {"session_id": "old", "transcript_path": str(old), "hook_event_name": "SessionStart", "source": "startup"}
            path, _ = snapshot(event, root / "state", happy_session_id="happy")
            new = dict(event, session_id="new", transcript_path=str(root / "not-created.jsonl"))
            recovered, state = snapshot(new, root / "state", happy_session_id="happy")
            self.assertEqual(path, recovered)
            self.assertEqual(state["goal"], "Keep the original goal")
            child, _ = snapshot(dict(new, agent_id="child"), root / "state", happy_session_id="happy")
            self.assertNotEqual(path, child)

    def test_identical_errors_warn_once_and_success_resets(self):
        state = {}
        event = {"hook_event_name": "PostToolUse", "tool_name": "test", "tool_input": {"secret": "not saved"},
                 "tool_response": {"isError": True, "content": "failure"}}
        self.assertEqual([bool(repeated_failure(state, event)) for _ in range(4)], [False, False, True, False])
        self.assertNotIn("not saved", json.dumps(state))
        changed = dict(event, tool_input={"changed": True})
        self.assertFalse(repeated_failure(state, changed))
        self.assertFalse(repeated_failure(state, dict(event, tool_response={"status": "running", "wait_timed_out": True})))
        self.assertNotIn("failure_streak", state)
        self.assertFalse(repeated_failure(state, {"hook_event_name": "Stop"}))

    def test_install_preserves_settings_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            settings = home / ".claude/settings.json"
            settings.parent.mkdir()
            settings.write_text(json.dumps({"model": "keep", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "existing-hook"}]}]}}))
            repo = Path(__file__).resolve().parent.parent
            install(home, repo)
            before = settings.read_text()
            install(home, repo)
            self.assertEqual(before, settings.read_text())
            self.assertEqual(json.loads(before)["model"], "keep")
            self.assertIn("existing-hook", before)
            self.assertEqual((home / ".codex/AGENTS.md").read_text().count(BEGIN), 1)
            self.assertEqual(settings.stat().st_mode & 0o777, 0o600)

    def test_recovery_budget_keeps_latest_correction_and_note_tail(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "state.json"
            path.with_suffix(".notes.md").write_text("x" * 5900 + "\nREMAINING: wait for run 42")
            state = {"goal": "Original objective", "user_updates": ["a" * 3000, "Latest correction"], "progress": ["b" * 3000]}
            text = restoration(path, state)
            self.assertLessEqual(len(text), 10000)
            self.assertIn("Latest correction", text)
            self.assertIn("REMAINING: wait for run 42", text)

    def write_codex(self, path, session, text, subagent=False):
        source = {"subagent": {"thread_spawn": {"parent_thread_id": "root"}}} if subagent else "vscode"
        records = [{"type": "session_meta", "payload": {"id": session, "source": source}},
                   {"type": "event_msg", "payload": {"type": "user_message", "message": text}}]
        path.write_text("".join(json.dumps(r) + "\n" for r in records))

    def test_same_happy_session_survives_provider_thread_change(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            old, new = root / "old.jsonl", root / "new.jsonl"
            self.write_codex(old, "old", "Fix the UART; keep the acceptance gate")
            self.write_codex(new, "new", "Continue")
            event = {"session_id": "old", "transcript_path": str(old), "hook_event_name": "SessionStart"}
            path, _ = snapshot(event, root / "state", happy_session_id="happy-one")
            path.with_suffix(".notes.md").write_text("Verified: host tests passed. Waiting: HIL run 42.")
            new_event = dict(event, session_id="new", transcript_path=str(new))
            resumed, state = snapshot(new_event, root / "state", happy_session_id="happy-one")
            self.assertEqual(resumed, path)
            self.assertEqual(state["goal"], "Fix the UART; keep the acceptance gate")
            self.assertIn("HIL run 42", restoration(resumed, state))
            self.assertEqual(state["transcript"], str(new))
            # A late hook from the replaced process cannot retake ownership.
            snapshot(dict(event, hook_event_name="Stop"), root / "state", happy_session_id="happy-one")
            self.assertEqual(json.loads(path.read_text())["transcript"], str(new))
            other, other_state = snapshot(new_event, root / "state", happy_session_id="happy-two")
            self.assertNotEqual(other, path)
            self.assertEqual(other_state["goal"], "Continue")

    def test_child_never_shares_parent_checkpoint(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            parent, child = root / "parent.jsonl", root / "child.jsonl"
            self.write_codex(parent, "parent", "Main goal")
            self.write_codex(child, "child", "Child assignment", True)
            def call(p, sid):
                return snapshot({"session_id": sid, "transcript_path": str(p), "hook_event_name": "SessionStart"}, root / "state", happy_session_id="happy")
            p, _ = call(parent, "parent")
            c, state = call(child, "child")
            self.assertNotEqual(p, c)
            self.assertEqual(state["goal"], "Child assignment")

    def test_claude_text_recovery_excludes_tools_and_thinking(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            transcript = root / "claude.jsonl"
            records = [
                {"type": "user", "isSidechain": False, "message": {"role": "user", "content": "Fix it all"}},
                {"type": "assistant", "isSidechain": False, "message": {"role": "assistant", "content": [
                    {"type": "thinking", "thinking": "secret reasoning"},
                    {"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "secret command"}},
                    {"type": "text", "text": "Waiting on run 42"}]}},
                {"type": "user", "isSidechain": False, "message": {"role": "user", "content": [
                    {"type": "tool_result", "content": "secret result"}]}}]
            transcript.write_text("".join(json.dumps(r) + "\n" for r in records))
            path, state = snapshot({"session_id": "claude", "transcript_path": str(transcript)}, root / "state", happy_session_id="happy")
            self.assertEqual(state["goal"], "Fix it all")
            self.assertEqual(state["progress"], ["Waiting on run 42"])
            self.assertNotIn("secret", path.read_text())


if __name__ == "__main__":
    unittest.main()
