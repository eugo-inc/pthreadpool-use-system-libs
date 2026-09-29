#!/usr/bin/env bash
# §2.47 (run 1231) — the OPT-IN cloud provisioning hook: in a Claude Code cloud session, run the
# repo's own `.claude/cloud-setup.sh` (operator ruling 2026-09-28: a fixed script path, no
# `.eugo.toml` table).
#
# WHY. A cloud session starts in a fresh VM with a fresh clone. athena provisions its test gate
# there with its own `session-start.sh`; the fleet's carriers gave a consumer repo no equivalent
# (FUTURE.md §2.47). This hook is that slot: the repo writes `.claude/cloud-setup.sh` (apt
# packages, a venv, whatever its gate needs — idempotent, because it runs at every session start),
# and `eugo-skills init-hooks --cloud-setup` registers this hook to run it.
#
# Contract (each line is a test in tools/tests/test_cloud_setup_hook.py):
#   - OPT-IN: registered only by `init-hooks --cloud-setup`, never by `--review` or a default run.
#   - LOCAL SESSIONS ARE UNTOUCHED: it exits 0 at once unless `CLAUDE_CODE_REMOTE` is exactly
#     `true` (the signal athena's `session-start.sh` keys on), and inside a review subprocess.
#   - ALWAYS exits 0: a failed setup is REPORTED (its exit status and the last lines of its
#     output, as SessionStart context the session can act on), never a blocked session.
#   - SYNCHRONOUS, like `session-start.sh`: the gate exists before the first tool call. The row's
#     timeout is 600 s, Claude Code's own default for a command hook (hooks.md, "timeout").
#   - The setup runs under `bash`, so a script committed without its exec bit still runs.
set +eE +o pipefail
trap - ERR
set -u
exec </dev/null

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-.}"
SETUP="$ROOT/.claude/cloud-setup.sh"
say() { printf 'eugo cloud-setup: %s\n' "$1"; }

if [ ! -f "$SETUP" ]; then
  say "no .claude/cloud-setup.sh in this repo — nothing provisioned (write one to install what the gate needs)"
  exit 0
fi

OUT="$(cd "$ROOT" && bash "$SETUP" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  say ".claude/cloud-setup.sh finished (exit 0)"
else
  say ".claude/cloud-setup.sh FAILED (exit $RC) — the gate may not be provisioned; its last lines:"
  printf '%s\n' "$OUT" | tail -n 5 | sed 's/^/  /'
fi
exit 0
