import subprocess
import tempfile
import unittest
from pathlib import Path


README = Path(__file__).resolve().parents[1] / "README.md"


class ReadmeAliasTests(unittest.TestCase):
    def assert_alias_arguments(self, home_name, command, expected):
        aliases = [
            line for line in README.read_text(encoding="utf-8").splitlines()
            if line.startswith(("alias cod=", "alias cod-l="))
        ]
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / home_name
            launcher = home / ".local" / "bin" / "codex-switch"
            launcher.parent.mkdir(parents=True)
            launcher.write_text('#!/bin/bash\nprintf \'<%s>\\n\' "$@"\n', encoding="utf-8")
            launcher.chmod(0o700)
            completed = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c",
                 "shopt -s expand_aliases\n" + "\n".join(aliases) + "\n" + command],
                env={"HOME": str(home), "PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, expected)

    def test_cod_list_with_normal_home(self):
        self.assert_alias_arguments("home", "cod list", "<list>\n")

    def test_cod_list_with_spaced_home(self):
        self.assert_alias_arguments("home with spaces", "cod list", "<list>\n")

    def test_cod_l_slot_with_normal_home(self):
        self.assert_alias_arguments("home", "cod-l 3", "<launch>\n<3>\n")

    def test_cod_l_slot_with_spaced_home(self):
        self.assert_alias_arguments("home with spaces", "cod-l 3", "<launch>\n<3>\n")


if __name__ == "__main__":
    unittest.main()
