# Public repository publication guards

## Intent

Keep `codex-switch-k` maintainable while making accidental broken releases and credential commits harder to publish. The repository stays public; operational slot credentials and installed Codex configuration remain outside this work.

## Approaches

- GitHub secret scanning alone blocks only supported patterns and does not run the project's tests.
- CI secret scanning alone reports after a push has reached GitHub.
- **Selected:** keep GitHub push protection enabled, run a pinned full-history Gitleaks scanner plus the existing test suite in CI, and require both CI jobs on `main` pull requests.

## Contract

- A workflow runs on every pull request to `main` and every push to `main`, without path filters. Its token has only `contents: read` and checkout credentials are not persisted.
- The test job runs after the secrets job succeeds and uses Ubuntu 24.04, Bash syntax, concise ShellCheck diagnostics, Python unittest and all Bats cases, including the synthetic real-runner cases in an ephemeral hosted runner. Both jobs have bounded timeouts. Neither makes an OpenAI login or model request.
- The secrets job fetches all Git history, verifies a fixed Gitleaks v8.30.1 Linux release digest, scans ordinary, merge, and file-type-change commits with redacted findings and archive depth 2, and rejects common credential, backup, archive and scanner-override paths anywhere in reachable history. The path check fails on shallow or empty history instead of reporting clean. Temporary synthetic canaries prove it catches deleted, merge-only and regular-file-to-symlink leaks.
- `main` requires a pull request and the two observed successful check-run names. Zero approvals are required while this is a single-maintainer user repository. Admins are subject to the rule; force pushes and deletions are disabled.
- GitHub provider secret scanning and push protection stay enabled. Generic pattern scanning is enabled only if GitHub permits it for this repository; CI remains the compensating control when it does not.

## Boundaries

- CI runs after GitHub receives a push. Its failure can block merging, but cannot retract a secret already sent to a public branch. Push protection and local review remain necessary.
- Scanner patterns and supported archive formats are finite. A green scan is evidence for the specified coverage, not a proof that no possible secret exists.
- No launcher, admin runner, slot data, live authentication, or nonpublic repository state is changed.
