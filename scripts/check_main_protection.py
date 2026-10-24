"""Read-only comparison of the public repository's main protection gate."""

import json
import subprocess
import sys


API_PATH = "repos/KaronLabs/codex-switch-k/branches/main/protection"
EXPECTED_CHECKS = {("secrets", 15368), ("tests", 15368)}


def assess(protection):
    drift = []
    required = protection.get("required_status_checks") or {}
    if required.get("strict") is not True:
        drift.append("required_status_checks.strict")
    checks = required.get("checks") or []
    actual = {(item.get("context"), item.get("app_id")) for item in checks}
    contexts = required.get("contexts") or []
    if (actual != EXPECTED_CHECKS or len(checks) != len(EXPECTED_CHECKS)
            or set(contexts) != {name for name, _ in EXPECTED_CHECKS}
            or len(contexts) != len(EXPECTED_CHECKS)):
        drift.append("required_status_checks.checks")
    if (protection.get("enforce_admins") or {}).get("enabled") is not True:
        drift.append("enforce_admins")
    reviews = protection.get("required_pull_request_reviews") or {}
    if reviews.get("required_approving_review_count") != 0:
        drift.append("required_pull_request_reviews")
    bypass = reviews.get("bypass_pull_request_allowances") or {}
    if not isinstance(bypass, dict) or any(bypass.values()):
        drift.append("required_pull_request_reviews.bypass_pull_request_allowances")
    for name in ("allow_force_pushes", "allow_deletions"):
        if (protection.get(name) or {}).get("enabled") is not False:
            drift.append(name)
    return drift


def main():
    try:
        response = subprocess.run(
            ["gh", "api", API_PATH], capture_output=True, text=True, check=True,
        )
        protection = json.loads(response.stdout)
        drift = assess(protection)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, AttributeError, TypeError):
        print("main protection: inspection failed", file=sys.stderr)
        return 2
    if drift:
        print("main protection: DRIFT " + ", ".join(drift))
        return 1
    print("main protection: PASS (secrets, tests; app 15368)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
