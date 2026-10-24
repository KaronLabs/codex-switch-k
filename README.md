# Codex-Switch K

Select a local Codex CLI account by number on Ubuntu 24.04. This repository contains code and synthetic tests only: **no slot credentials, account directories, sessions, or personal Codex configuration**. A fresh installation starts with no slots; create empty slots 1 and 2 locally, then sign in with your own accounts.

The launcher keeps your normal `~/.codex` state and presents the selected slot's `auth.json` through a private mount view. The root-owned runner creates that view, drops back to your user, and starts Codex with `--no-daemon`. Login uses Bubblewrap. No account is logged in by cloning this repository.

## Ubuntu 24.04 setup

Install the required OS tools (Bats and ShellCheck are for tests):

```bash
sudo apt update
sudo apt install -y git curl ca-certificates bash python3 jq coreutils findutils gawk procps bubblewrap util-linux sudo bats shellcheck
```

Install the [Codex CLI](https://learn.chatgpt.com/docs/cli) separately. Its Linux standalone installer normally places `codex` in `~/.local/bin`:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
"$HOME/.local/bin/codex" --version
```

Use a Codex CLI release that supports `--no-daemon` and `-c cli_auth_credentials_store=file`. If you installed Codex elsewhere, set `CODEX_BIN` to its absolute executable path in your shell before using the switcher. Do not sign in to the shared default account just to set up slots.

Clone the new, independent public repository:

```bash
umask 077
git clone https://github.com/KaronLabs/codex-switch-k.git
cd codex-switch-k
```

Install the user launcher and the root-owned runner. These first-install commands stop if either target already exists; inspect and back it up instead of silently replacing another installation.

```bash
set -euo pipefail
umask 077
install -d -m 700 "$HOME/.local/bin"
test ! -e "$HOME/.local/bin/codex-switch" && test ! -L "$HOME/.local/bin/codex-switch"
sudo install -d -m 755 /usr/local/libexec
sudo test ! -e /usr/local/libexec/codex-switch-admin-run
sudo test ! -L /usr/local/libexec/codex-switch-admin-run
install -m 700 codex-switch "$HOME/.local/bin/codex-switch"
sudo install -o root -g root -m 755 codex-switch-admin-run /usr/local/libexec/codex-switch-admin-run
```

Give your own Unix user passwordless permission for **only that runner path**. Open `/etc/sudoers.d/codex-switch-k` with `sudo visudo -f /etc/sudoers.d/codex-switch-k`, add the following line after replacing `YOUR_USER` with `id -un`, and save. Do not add a wildcard command or `SETENV` permission.

```sudoers
YOUR_USER ALL=(root) NOPASSWD:NOSETENV: /usr/local/libexec/codex-switch-admin-run
```

Check it before use:

```bash
sudo chmod 0440 /etc/sudoers.d/codex-switch-k
sudo visudo -cf /etc/sudoers.d/codex-switch-k
sudo stat -c '%U:%G %a %n' /usr/local/libexec/codex-switch-admin-run
```

The runner must be owned by `root:root`; the sudoers check must say the file parses. The launcher uses `sudo -n` without `-E`, so a missing or denied rule stops launch instead of falling back to an unisolated account. The runner traverses authentication paths with the caller's permissions, pins the selected file and shared mount target with file descriptors, and binds those objects using Linux `open_tree` and `move_mount`. It checks that the selected file remains visible at `CODEX_HOME` before running Codex. It fails closed if either syscall is unavailable or denied. This requires Linux 5.2+ and glibc 2.36+ (Ubuntu 24.04 satisfies both). Do not use the older pathname-based runner with this sudoers rule.

## Create slots and sign in

Run these as your normal user. `add` creates an empty private `auth.json` (0600), an empty `home/` (0700), and—only if missing—a shared `~/.codex/auth.json` mount target. It does not replace existing slot paths or shared configuration.

```bash
"$HOME/.local/bin/codex-switch" add 1
"$HOME/.local/bin/codex-switch" add 2
"$HOME/.local/bin/codex-switch" list
"$HOME/.local/bin/codex-switch" login 1
"$HOME/.local/bin/codex-switch" login 2 --browser
"$HOME/.local/bin/codex-switch" list
"$HOME/.local/bin/codex-switch" launch 1 -- --version
```

`login N` uses a device code by default; `login N --browser` starts Codex's browser OAuth flow. On a remote/headless host, device code is usually simpler. Browser login may require [forwarding the localhost callback](https://learn.chatgpt.com/docs/auth) over SSH. Both flows explicitly request `cli_auth_credentials_store=file` and require an actual file credential afterward. The switcher refuses a local managed policy that requires another credential store, rather than silently using a keyring account. **The tests do not sign in to OpenAI or prove that your account is valid.**

To add another slot, run `codex-switch add N` and then `codex-switch login N`. `N` is a positive decimal integer with no leading zeros. Existing slots are never overwritten; `0` exits the interactive menu. `list` discovers only local numeric slots and may display an email and a shortened account ID—do not share its output publicly. Duplicate accounts are marked and cannot launch. A missing slot must be added before login or launch.

Optional Bash aliases (add to your own shell configuration only if desired):

```bash
alias cod='"$HOME/.local/bin/codex-switch"'
alias cod-l='"$HOME/.local/bin/codex-switch" launch'
```

Use `cod` for the menu, `cod list` for status, or `cod-l 1` to start slot 1. The switcher can detect running Codex sessions and may ask before terminating conflicting sessions. `--kill` signals only the PIDs classified into blocking sessions (which may include an associated wrapper), not unrelated siblings in the same process group. It does so without a prompt; use it only when you intend that result. This repository does **not** set a default approval policy, sandbox mode, or YOLO mode.

## Test, update, and remove

Tests use synthetic credentials and a fake CLI; they make no OpenAI model request:

```bash
bash -n codex-switch
bash -n codex-switch-admin-run
shellcheck codex-switch codex-switch-admin-run
bats tests/codex-switch.bats
python3 -m unittest discover -s tests -p 'test_*.py' -q
```

Pull requests and pushes to `main` run these checks in CI, including the synthetic real-runner Bats cases on an ephemeral Ubuntu 24.04 runner. A separate job checks prohibited paths across Git history and scans the fetched history with Gitleaks; neither job signs in to OpenAI or makes a model request.

### Check before a public push

The optional local pre-push hook checks all local Git history paths and runs the same Gitleaks 8.30.1 history scan as CI. It rejects pushed commits outside local refs, annotated tags, and local Gitleaks configuration overrides that this scan cannot cover. Install [Gitleaks 8.30.1](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1) on `PATH`, or put its executable in the ignored `.githooks/tools/` directory as `gitleaks` (Linux) or `gitleaks.exe` (Windows). Verify the downloaded archive SHA-256 before extracting it: Linux x64 `551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`; Windows x64 `d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e`. The hook refuses a missing or different version and suppresses scanner output so a suspected secret is not copied into terminal logs.

Enable the hook in **each clone** from its repository root:

```bash
git config --local core.hooksPath .githooks
bash .githooks/pre-push
```

The second command should report that both checks passed. Git does not activate tracked hooks automatically, and `git push --no-verify` can bypass a local hook. Protected `main` still requires the server-side `secrets` and `tests` checks.

### Maintain publication guards

After changing GitHub branch settings, run `python3 scripts/check_main_protection.py` with a GitHub CLI login that can read repository protection. It compares the exact required check names `secrets` and `tests`, their GitHub Actions app ID `15368`, strict status checks, administrator enforcement, PR reviews with no bypass actors, and force-push/deletion denial. A mismatch or failed API read exits nonzero. On Windows, use `python` if `python3` is unavailable. The check is read-only and does not require a new repository secret.

CI also runs weekly on Monday at 03:17 UTC and can be started from the Actions tab or with `gh workflow run ci.yml --ref main`. Run it manually after changing the Ubuntu runner image. Its `Probe Bubblewrap namespace support` step must pass, followed by the real-runner Bats tests. When updating Gitleaks, update its pinned download and checksum together and keep all three synthetic history canaries: deleted secret, merge-resolution secret, and regular-file-to-symlink secret. Confirm the `secrets` job passes all three on the new scanner before merging. GitHub may delay scheduled workflows or disable them after 60 days of public-repository inactivity, so use manual dispatch for an immediate image check.

For updates, stop Codex sessions, inspect `git status`, and run `git pull --ff-only`. From the repository root, back up the installed files and replace only these two paths:

```bash
set -euo pipefail
umask 077
backup_dir=$(mktemp -d "$HOME/.local/bin/codex-switch-k-backup.XXXXXXXX")
cp -p -- "$HOME/.local/bin/codex-switch" "$backup_dir/codex-switch"
sudo cp -p -- /usr/local/libexec/codex-switch-admin-run "$backup_dir/codex-switch-admin-run"
test ! -e "$HOME/.local/bin/.codex-switch.new" && test ! -L "$HOME/.local/bin/.codex-switch.new"
sudo test ! -e /usr/local/libexec/.codex-switch-admin-run.new
sudo test ! -L /usr/local/libexec/.codex-switch-admin-run.new
install -m 700 codex-switch "$HOME/.local/bin/.codex-switch.new"
sudo install -o root -g root -m 755 codex-switch-admin-run /usr/local/libexec/.codex-switch-admin-run.new
mv -T -- "$HOME/.local/bin/.codex-switch.new" "$HOME/.local/bin/codex-switch"
sudo mv -T -- /usr/local/libexec/.codex-switch-admin-run.new /usr/local/libexec/codex-switch-admin-run
```

If the new version fails, restore those two files from `backup_dir` with `install -m 700` for the launcher and `sudo install -o root -g root -m 755` for the runner. Do not replace `/etc/sudoers.d/codex-switch-k` or your personal `~/.codex` as part of an update. Keep slot data outside Git.

To remove the switcher, first remove its single rule with `sudo visudo -f /etc/sudoers.d/codex-switch-k`, then remove only the installed launcher and runner if their paths still identify this installation. Remove aliases from your own shell configuration if you added them. Slot credentials under `~/.local/share/codex-accounts` are **not** removed automatically; back them up or delete them separately only when you intend to.

This first release targets Ubuntu 24.04. WSL support, credential backup, existing-server migration, and live-login automation are outside its tested scope. Treat local `auth.json` files as passwords and never commit them to Git. See [OpenAI's authentication guidance](https://learn.chatgpt.com/docs/auth).

MIT licensed; see [LICENSE](LICENSE).
