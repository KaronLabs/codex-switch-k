"""Reject paths that must never appear in reachable public Git history."""

import os
import subprocess
import sys


PRIVATE_KEY_NAMES = {
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    "id_ecdsa_sk", "id_ed25519_sk",
}
PRIVATE_KEY_EXTENSIONS = (".pem", ".key", ".p8", ".p12", ".pfx", ".ppk")
ARCHIVE_EXTENSIONS = (
    ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz",
    ".tar.zst", ".tar.br", ".zip", ".7z", ".rar", ".gz", ".zst", ".xz",
)
RUNTIME_DIRECTORIES = {"codex-accounts", ".codex", "backup", "backups"}
SCANNER_OVERRIDES = {".gitleaks.toml", ".gitleaksignore"}


def category(path):
    parts = [part.casefold() for part in path.replace("\\", "/").split("/")]
    name = parts[-1]
    if any(part in RUNTIME_DIRECTORIES for part in parts[:-1]):
        return "runtime"
    if name in SCANNER_OVERRIDES:
        return "scanner-override"
    if name == "auth.json" or name.startswith("auth.json."):
        return "credentials"
    if name in {"auth-backup.json", "auth_backup.json", "credentials.json", "secrets.json"}:
        return "credentials"
    if name == ".env" or name.startswith(".env."):
        return "credentials"
    if (name in PRIVATE_KEY_NAMES
            or (name.endswith(".bak") and name[:-4] in PRIVATE_KEY_NAMES)
            or name.endswith(PRIVATE_KEY_EXTENSIONS)):
        return "credentials"
    if name.endswith(ARCHIVE_EXTENSIONS):
        return "archives"
    return None


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", repo, *args], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, check=True,
    ).stdout


def main(repo):
    categories = set()
    try:
        if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
            raise ValueError("incomplete Git history")
        commits = git(repo, "rev-list", "--all").splitlines()
        if not commits:
            raise ValueError("empty Git history")
        for commit in commits:
            paths = git(repo, "ls-tree", "--full-tree", "-r", "-z", "--name-only", commit.decode("ascii"))
            for raw_path in paths.split(b"\0"):
                if raw_path:
                    found = category(os.fsdecode(raw_path))
                    if found:
                        categories.add(found)
    except (OSError, subprocess.CalledProcessError, UnicodeError, ValueError):
        print("git inspection failed", file=sys.stderr)
        return 2

    if categories:
        for found in sorted(categories):
            print(f"forbidden: {found}")
        return 1
    print("clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
