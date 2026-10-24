import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from contextlib import redirect_stdout, redirect_stderr
from io import StringIO
import json


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / ".githooks" / "pre-push"
PROTECTION = ROOT / "scripts" / "check_main_protection.py"


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True,
    )
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout


class PrePushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "scripts").mkdir()
        (self.repo / ".githooks").mkdir()
        shutil.copyfile(ROOT / "scripts" / "check_public_history.py", self.repo / "scripts" / "check_public_history.py")
        shutil.copyfile(HOOK, self.repo / ".githooks" / "pre-push")
        if os.name != "nt":
            (self.repo / ".githooks" / "pre-push").chmod(0o700)
        (self.repo / "README.md").write_text("ordinary test data\n", encoding="utf-8")
        git(self.repo, "add", "README.md", "scripts/check_public_history.py")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base")
        self.scanner = self.repo / ".fake-gitleaks.sh"
        self.scanner.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = version ]; then echo \"${FAKE_VERSION:-8.30.1}\"; exit 0; fi\n"
            "printf '%s\\n' \"$*\" >\"$SCAN_ARGS\"\n"
            "printf 'ghp_fixture_must_not_be_echoed\\n'\n"
            "exit \"${SCAN_EXIT:-0}\"\n", encoding="utf-8",
        )
        if os.name != "nt":
            self.scanner.chmod(0o700)

    def hook(self, **changes):
        bash = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
        env = os.environ.copy()
        env.update({"GITLEAKS_BIN": "./.fake-gitleaks.sh", "SCAN_ARGS": "./.scan-args"})
        env.update(changes)
        return subprocess.run([bash, ".githooks/pre-push"], cwd=self.repo, env=env, capture_output=True, text=True)

    def test_clean_history_scans_full_history_with_hardened_flags(self):
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.repo / ".scan-args").read_text(encoding="utf-8")
        self.assertIn("--all --full-history --diff-merges=first-parent", args)
        self.assertIn("--redact=100", args)
        self.assertIn("--ignore-gitleaks-allow", args)
        self.assertNotIn("ghp_fixture_must_not_be_echoed", result.stdout + result.stderr)

    def test_scanner_finding_blocks_push_without_echoing_output(self):
        result = self.hook(SCAN_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ghp_fixture_must_not_be_echoed", result.stdout + result.stderr)

    def test_missing_scanner_blocks_push(self):
        result = self.hook(GITLEAKS_BIN="./missing")
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_scanner_version_blocks_push(self):
        result = self.hook(FAKE_VERSION="8.29.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / ".scan-args").exists())

    def test_forbidden_history_blocks_before_scanner(self):
        (self.repo / "auth.json").write_text("synthetic only\n", encoding="utf-8")
        git(self.repo, "add", "-f", "auth.json")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "forbidden")
        result = self.hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repo / ".scan-args").exists())

    def test_git_push_invokes_the_hook(self):
        remote = Path(self.temp.name) / "remote.git"
        remote.mkdir()
        git(remote, "init", "--bare", "-q")
        git(self.repo, "config", "--local", "core.hooksPath", ".githooks")
        env = os.environ.copy()
        env.update({"GITLEAKS_BIN": "./.fake-gitleaks.sh", "SCAN_ARGS": "./.scan-args"})
        result = subprocess.run(
            ["git", "-C", str(self.repo), "push", str(remote), "HEAD:main"],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo / ".scan-args").exists())
        self.assertIn("pre-push: public history and Gitleaks checks passed", result.stderr)


class ProtectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("check_main_protection", PROTECTION)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def protection(self):
        return {
            "required_status_checks": {
                "strict": True, "contexts": ["secrets", "tests"],
                "checks": [{"context": name, "app_id": 15368} for name in ("secrets", "tests")],
            },
            "enforce_admins": {"enabled": True},
            "required_pull_request_reviews": {"required_approving_review_count": 0},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
        }

    def test_expected_protection_passes(self):
        self.assertEqual(self.module.assess(self.protection()), [])

    def test_missing_check_or_wrong_app_fails(self):
        payload = self.protection()
        payload["required_status_checks"]["checks"].pop()
        self.assertTrue(self.module.assess(payload))
        payload = self.protection()
        payload["required_status_checks"]["checks"][0]["app_id"] = -1
        self.assertTrue(self.module.assess(payload))
        payload = self.protection()
        payload["required_status_checks"]["contexts"] = ["secrets", "other"]
        self.assertTrue(self.module.assess(payload))

    def test_relaxed_admin_force_or_deletion_fails(self):
        for key in ("enforce_admins", "allow_force_pushes", "allow_deletions"):
            payload = self.protection()
            payload[key]["enabled"] = not payload[key]["enabled"]
            self.assertTrue(self.module.assess(payload), key)

    def test_review_count_drift_fails(self):
        payload = self.protection()
        payload["required_pull_request_reviews"]["required_approving_review_count"] = 1
        self.assertTrue(self.module.assess(payload))

    def test_cli_distinguishes_pass_drift_and_failed_read(self):
        for payload, expected in ((self.protection(), 0), ({}, 1)):
            response = subprocess.CompletedProcess([], 0, json.dumps(payload), "")
            with mock.patch.object(self.module.subprocess, "run", return_value=response):
                with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                    self.assertEqual(self.module.main(), expected)
        response = subprocess.CompletedProcess([], 0, "not JSON", "")
        with mock.patch.object(self.module.subprocess, "run", return_value=response):
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                self.assertEqual(self.module.main(), 2)
        with mock.patch.object(
            self.module.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["gh"]),
        ):
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                self.assertEqual(self.module.main(), 2)


if __name__ == "__main__":
    unittest.main()
