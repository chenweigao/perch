# Preventing accidental disclosure

GitHub secret scanning and repository push protection are enabled for Perch.
Local hooks add a check before data reaches the public repository. Pull-request
and main-branch CI provide a second check; CI runs after upload and cannot undo
an exposure.

## One-time setup for each clone

```sh
python3 scripts/setup-security.py
```

Requires Git, Python 3 and curl on macOS or Linux. This downloads Gitleaks 8.30.1
from its official GitHub release and verifies a pinned SHA-256 checksum. The tool
and generated hooks live in Git's common directory, shared by that clone's
worktrees. No credentials or system-wide Git configuration are changed.

Existing hooks are preserved. The previous pre-commit hook runs first, so any
index changes it makes are checked. The previous pre-push hook receives the
original arguments and stdin after our checks pass. Other existing hooks remain
linked. Re-running setup is safe; the prior hooks directory is recorded in the
repository-local `perch.previousHooksPath` setting.

- **Commit:** inspect the actual Git index, not unstaged file contents.
- **Push:** inspect all history reachable from each pushed tip, including values
  removed in a later commit. Deleting a remote ref introduces no content to scan.
- **Checks:** Gitleaks uses its default rules; Perch additionally checks private
  paths, email addresses and credential filenames. Tracked files are checked
  even when marked `export-ignore`. Explicit GitHub noreply commit identities
  are allowed.
- **Failures:** missing/broken scanners or incomplete checks block the operation.
  Reports show file locations and rule names without printing candidate values.

Run checks manually:

```sh
python3 scripts/security-check.py staged
python3 scripts/security-check.py history HEAD
python3 -m unittest discover -s Tests/Publication -p 'test_*.py'
```

PR checks inspect the contributor's actual head and its history, not GitHub's
synthetic merge commit. Keep GitHub account email privacy enabled too: GitHub can
otherwise attach a personal address to commits it generates itself. Local hooks
cannot control GitHub-generated metadata.

CI uses a commit-pinned checkout action, a read-only token, no persisted Git
credentials, and no external credentials. It scans full history and runs isolated
regressions with synthetic tokens. It does not probe the validity of candidate
credentials against external services or upload secret reports as artifacts.

## Daily workflow

Keep real credentials, logs and session exports outside the repository or in
ignored local storage. `.gitignore` does not protect files already tracked by Git.
Use placeholders in example configuration and synthetic conversations in the
[offline demo](../Tests/PublicDemo/README.md). Images and metadata still require
manual review; text scanners do not understand screenshots.

Hooks can be bypassed or changed locally, and scanners do not recognize every
secret format. Investigate a block before continuing; do not add real secrets to
allowlists. If a credential reaches GitHub, revoke or rotate it first, then remove
it and follow GitHub's sensitive-data history cleanup process. Deleting the latest
file alone does not remove the exposed value from history.
