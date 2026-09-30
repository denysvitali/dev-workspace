"""Regression coverage for staged content, inherited budgets and session recovery."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from agent_checkpoint import MAX_RECORD, restoration, snapshot
from check_agent_guidance import check
from install_agent_guardrails import install


class GuidanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args])

    def write(self, name, size):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x" * size)

    def test_staged_symlink_and_working_copy_are_distinct(self):
        self.write("CLAUDE.md", 25000)
        (self.repo / "AGENTS.md").symlink_to("CLAUDE.md")
        self.git("add", ".")
        self.write("CLAUDE.md", 100)
        self.assertFalse(check(self.repo)[0])
        self.assertTrue(check(self.repo, staged=True)[0])

    def test_inherited_chain_and_override_precedence(self):
        self.write("AGENTS.md", 16000)
        self.write("nested/AGENTS.md", 14000)
        self.assertTrue(check(self.repo)[0])
        self.write("AGENTS.override.md", 100)
        self.assertFalse(check(self.repo)[0])

    def test_external_or_missing_symlink_is_rejected(self):
        (self.repo / "AGENTS.md").symlink_to("/etc/hosts")
        self.git("add", ".")
        self.assertTrue(check(self.repo)[0])
        self.assertTrue(check(self.repo, staged=True)[0])
        (self.repo / "AGENTS.md").unlink()
        (self.repo / "AGENTS.md").symlink_to("missing.md")
        self.git("add", ".")
        self.assertTrue(check(self.repo, staged=True)[0])

    def test_install_is_idempotent_and_preserves_existing_hooks(self):
        original = self.repo / ".githooks"
        original.mkdir()
        hook = original / "pre-commit"
        hook.write_text("#!/bin/sh\ntouch prior-hook-ran\n")
        hook.chmod(0o755)
        self.git("config", "core.hooksPath", ".githooks")
        install(self.repo)
        install(self.repo)
        managed = Path(self.git("config", "core.hooksPath").decode().strip())
        subprocess.run([str(managed / "pre-commit")], cwd=self.repo, check=True, capture_output=True)
        self.assertTrue((self.repo / "prior-hook-ran").is_file())
        self.write("AGENTS.md", 25000)
        self.git("add", "AGENTS.md")
        self.assertNotEqual(subprocess.run([str(managed / "pre-commit")], cwd=self.repo, capture_output=True).returncode, 0)


class CheckpointTests(unittest.TestCase):
    def test_current_codex_response_messages_preserve_goal_and_corrections(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "rollout.jsonl"
            records = [("user", "# AGENTS.md instructions\nGlobal rules"),
                       ("user", "Fix Codex configuration"), ("user", "Keep Happy reasoning controls"),
                       ("assistant", "All guidance checks pass")]
            transcript.write_text("".join(json.dumps({"type": "response_item", "payload": {
                "type": "message", "role": role, "content": [{"type": "input_text", "text": message}]}}) + "\n"
                for role, message in records))
            _, state = snapshot({"session_id": "own", "transcript_path": str(transcript)}, root / "state")
            self.assertEqual(state["goal"], "Fix Codex configuration")
            self.assertIn("Keep Happy reasoning controls", state["user_updates"])
            self.assertEqual(state["progress"], ["All guidance checks pass"])

    def test_incremental_partial_write_isolation_and_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "rollout.jsonl"
            line = json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": "Fix guidance; leave reasoning alone"}}) + "\n"
            partial = json.dumps({"type": "event_msg", "payload": {"type": "agent_message", "message": "Verified the staged guard"}})
            transcript.write_text(line + partial[:20])
            event = {"session_id": "own", "transcript_path": str(transcript), "cwd": directory, "hook_event_name": "PreCompact"}
            path, state = snapshot(event, root / "state")
            self.assertEqual(state["offset"], len(line.encode()))
            transcript.write_text(line + partial + "\n")
            _, state = snapshot(event, root / "state")
            self.assertEqual(state["progress"], ["Verified the staged guard"])
            _, repeated = snapshot(event, root / "state")
            self.assertEqual(repeated["progress"], state["progress"])
            path.with_suffix(".notes.md").write_text("Remaining: commit and push. CI pending.")
            self.assertIn("CI pending", restoration(path, state))
            other, _ = snapshot(dict(event, session_id="other"), root / "state")
            child, _ = snapshot(dict(event, transcript_path=str(root / "child.jsonl")), root / "state")
            self.assertNotEqual(path, other)
            self.assertNotEqual(path, child)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    def test_large_records_and_reasoning_are_not_saved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "rollout.jsonl"
            records = [{"type": "response_item", "payload": {"type": "reasoning", "text": "private reasoning"}},
                       {"type": "response_item", "payload": {"type": "function_call_output", "output": "secret" + "x" * MAX_RECORD}},
                       {"type": "event_msg", "payload": {"type": "user_message", "message": "Continue"}}]
            transcript.write_text("".join(json.dumps(r) + "\n" for r in records))
            path, state = snapshot({"session_id": "own", "transcript_path": str(transcript)}, root / "state")
            self.assertEqual(state["goal"], "Continue")
            self.assertNotIn("private reasoning", path.read_text())
            self.assertNotIn("secret", path.read_text())
            self.assertLess(path.stat().st_size, 2000)


if __name__ == "__main__":
    unittest.main()
