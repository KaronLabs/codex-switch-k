# Publication Guards Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans task by task. Verify each deliverable before proceeding.

**Goal:** Add repeatable CI and secret checks, then protect `main` with the observed successful checks.

**Architecture:** A two-job GitHub Actions workflow tests the Ubuntu product and scans full Git history. A small repository-history policy rejects credential files, archives, and scanner bypass files, including paths deleted in later commits. GitHub branch protection binds the observed CI check-run names after the first green pull request.

**Tech Stack:** GitHub Actions, Ubuntu 24.04, Bash, Bats, ShellCheck, Python 3, Gitleaks v8.30.1, GitHub REST API.

**Spec:** `docs/superpowers/specs/2026-10-24-publication-guards-design.md`

## Global Constraints

- Work only in the public `KaronLabs/codex-switch-k` checkout. Do not copy Git history or authentication from the private repository.
- Never use operational credentials or make a Codex server request.
- Pin external Actions to a full commit SHA and Gitleaks to the release SHA-256.
- Do not print synthetic scanner canary values or unredacted finding text in CI logs.

## Review Focus

- A secret introduced and deleted in a later commit must still fail the scan.
- A secret introduced only by merge-conflict resolution must still fail the scan.
- A secret introduced only when a regular file becomes a symlink must still fail the scan.
- An archive or `auth.json` committed then deleted must still fail the path policy.
- Common backup and credential filenames must be rejected, including backup directories and compressed tar forms.
- A shallow or empty Git checkout must fail closed; common tar compression suffixes must be rejected.
- A PR that adds `.gitleaksignore` or `.gitleaks.toml` must not weaken the scanner.
- A failed or skipped required job must not allow a protected `main` merge.
- A secret finding must stop source-printing test tools before they execute; required jobs cannot hang indefinitely.
- Real-runner tests must execute rather than silently skip in CI.

## Task 1: Historical path policy

**Files:** Create `scripts/check_public_history.py`; create `tests/test_public_history.py`.

- [ ] Write tests with disposable Git repos for clean history, deleted authentication/archive paths, and scanner override files.
- [ ] Run those tests and confirm the missing policy fails them.
- [ ] Implement the smallest read-only path check across all reachable commits, with category-only diagnostics.
- [ ] Run the focused tests and full Python test discovery.

## Task 2: CI workflow

**Files:** Create `.github/workflows/ci.yml`; update `README.md` for the new verification contract and `.gitattributes` to keep the new `.yml` workflow on LF.

- [ ] Record the RED baseline: no workflow and no Actions checks at the current public HEAD.
- [ ] Add `tests` and `secrets` jobs on pull requests and pushes to `main`, without path filters.
- [ ] Run Bash/ShellCheck/Python/Bats in `tests`; configure the synthetic real runner so all Bats cases execute.
- [ ] In `secrets`, verify the pinned Gitleaks download, run the history path policy, prove deleted, merge-only and file-to-symlink disposable synthetic canaries are detected, then scan full checkout history including type changes and merge diffs, with redaction and archive depth 2.
- [ ] Validate workflow syntax locally and require the first PR run to pass before changing branch protection.

## Task 3: Repository controls and publication

**Files:** GitHub settings only, after Tasks 1 and 2 are independently reviewed.

- [ ] Commit only explicit public source paths, push a feature branch, and open a pull request.
- [ ] Inspect the PR run: both jobs succeed and the real-runner tests did not skip. Resolve failures before proceeding.
- [ ] Confirm the exact check-run names and current protection state, then require the PR and those checks on `main`; enforce admins and disable force pushes/deletions.
- [ ] Merge the passing PR, verify the `main` push run and branch protection readback.
- [ ] Attempt generic-pattern secret scanning enablement when supported; read back its state and report any plan/API limitation without disabling existing push protection.
- [ ] Recheck the public Git object inventory for credential/archive paths and the final worktree status.
