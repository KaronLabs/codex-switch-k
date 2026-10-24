import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


POLICY = Path(__file__).resolve().parents[1] / "scripts" / "check_public_history.py"


class PublicHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def git(self, repo, *args):
        result = subprocess.run(
            ["git", "-C", str(repo), *args], capture_output=True, text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def new_repo(self, name="repo"):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q", "-b", "main")
        return repo

    def commit_file(self, repo, name):
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("ordinary test data", encoding="utf-8")
        self.git(repo, "add", "--", name)
        self.git(
            repo, "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-qm", "fixture",
        )

    def policy(self, repo, explicit=True):
        command = [sys.executable, str(POLICY)]
        if explicit:
            command.append(str(repo))
        return subprocess.run(
            command, cwd=repo, capture_output=True, text=True, check=False,
        )

    def assert_forbidden(self, result, category):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, f"forbidden: {category}\n")
        self.assertEqual(result.stderr, "")

    def test_clean_history_uses_current_directory_by_default(self):
        repo = self.new_repo()
        self.commit_file(repo, "docs/readme.txt")

        result = self.policy(repo, explicit=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "clean\n")
        self.assertEqual(result.stderr, "")

    def test_deleted_authentication_and_archive_paths_still_fail(self):
        for name, category in (
            ("nested/auth.json", "credentials"),
            ("artifacts/release.tar.gz", "archives"),
        ):
            with self.subTest(category=category):
                repo = self.new_repo(category)
                self.commit_file(repo, name)
                self.git(repo, "rm", "-q", "--", name)
                self.git(
                    repo, "-c", "user.name=Fixture", "-c",
                    "user.email=fixture@example.invalid", "commit", "-qm", "remove",
                )

                self.assert_forbidden(self.policy(repo), category)

    def test_shallow_clone_cannot_claim_deleted_upstream_auth_is_absent(self):
        upstream = self.new_repo("upstream")
        self.commit_file(upstream, "auth.json")
        self.git(upstream, "rm", "-q", "--", "auth.json")
        self.git(
            upstream, "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-qm", "remove",
        )
        shallow = self.root / "shallow"
        self.git(self.root, "clone", "-q", "--depth", "1", "--no-local", str(upstream), str(shallow))
        self.assertEqual(self.git(shallow, "rev-parse", "--is-shallow-repository").strip(), "true")
        self.assertEqual(self.git(shallow, "rev-list", "--count", "--all").strip(), "1")

        result = self.policy(shallow)

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "git inspection failed\n")

    def test_empty_repository_fails_closed(self):
        repo = self.new_repo()

        result = self.policy(repo)

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "git inspection failed\n")

    def test_deleted_tar_xz_archive_is_rejected(self):
        repo = self.new_repo()
        self.commit_file(repo, "dist/release.tar.xz")
        self.git(repo, "rm", "-q", "--", "dist/release.tar.xz")
        self.git(
            repo, "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-qm", "remove",
        )

        self.assert_forbidden(self.policy(repo), "archives")

    def test_adjacent_archive_suffixes_are_rejected(self):
        for index, name in enumerate((
            "dist/release.tar.bz2", "dist/release.tbz2", "dist/release.tar.zst",
            "dist/release.zst", "dist/release.xz",
        )):
            with self.subTest(name=name):
                repo = self.new_repo(f"archive-{index}")
                self.commit_file(repo, name)
                self.assert_forbidden(self.policy(repo), "archives")

    def test_common_named_backup_credential_and_archive_paths(self):
        cases = (
            ("auth-backup.json", "credentials"),
            ("nested/auth_backup.json", "credentials"),
            ("keys/id_ed25519.bak", "credentials"),
            ("dist/release.tar.br", "archives"),
            ("backups/any.txt", "runtime"),
            ("nested/credentials.json", "credentials"),
            ("nested/secrets.json", "credentials"),
        )
        for index, (name, category) in enumerate(cases):
            with self.subTest(name=name):
                repo = self.new_repo(f"named-{index}")
                self.commit_file(repo, name)
                self.assert_forbidden(self.policy(repo), category)

    def test_all_forbidden_path_families(self):
        cases = (
            ("auth.json.bak", "credentials"),
            ("nested/.env", "credentials"),
            ("nested/.env.local", "credentials"),
            ("keys/id_rsa", "credentials"),
            ("keys/id_ed25519", "credentials"),
            ("keys/private.pem", "credentials"),
            ("keys/private.key", "credentials"),
            ("keys/private.p12", "credentials"),
            ("keys/private.pfx", "credentials"),
            ("keys/private.ppk", "credentials"),
            ("codex-accounts/slot/data.txt", "runtime"),
            ("nested/.codex/config.toml", "runtime"),
            ("backup/old/data.txt", "runtime"),
            ("dist/release.tar", "archives"),
            ("dist/release.tgz", "archives"),
            ("dist/release.zip", "archives"),
            ("dist/release.7z", "archives"),
            ("dist/release.rar", "archives"),
            ("dist/release.gz", "archives"),
            (".gitleaks.toml", "scanner-override"),
            ("nested/.gitleaksignore", "scanner-override"),
        )
        for index, (name, category) in enumerate(cases):
            with self.subTest(name=name):
                repo = self.new_repo(f"case-{index}")
                self.commit_file(repo, name)
                self.assert_forbidden(self.policy(repo), category)

    def test_other_ref_is_scanned_when_current_branch_is_clean(self):
        repo = self.new_repo()
        self.commit_file(repo, "readme.txt")
        self.git(repo, "checkout", "-qb", "side")
        self.commit_file(repo, ".gitleaksignore")
        self.git(repo, "checkout", "-q", "main")

        self.assert_forbidden(self.policy(repo), "scanner-override")

    def test_unicode_path_is_read_without_leaking_its_name(self):
        repo = self.new_repo()
        self.commit_file(repo, "검사 폴더/.env.local")

        self.assert_forbidden(self.policy(repo), "credentials")

    @unittest.skipIf(os.name == "nt", "Windows filenames cannot contain newlines")
    def test_newline_in_parent_path_is_not_a_tree_record_boundary(self):
        repo = self.new_repo()
        self.commit_file(repo, "folder\nlabel/.env.local")

        self.assert_forbidden(self.policy(repo), "credentials")

    def test_non_repository_reports_generic_git_failure(self):
        repo = self.root / "ordinary directory"
        repo.mkdir()

        result = self.policy(repo)

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "git inspection failed\n")


if __name__ == "__main__":
    unittest.main()
