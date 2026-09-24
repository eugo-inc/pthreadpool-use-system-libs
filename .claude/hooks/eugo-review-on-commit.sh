#!/usr/bin/env bash
# §2109 — dispatch the adversarial review of any commit that has no ledger entry.
#
# WHY THIS EXISTS. The review watch was a polling daemon: `sudo -u slava nohup
# codex_watch.py --interval 300`. Measured at §2106, it delivered a verdict a MEDIAN of
# 17 minutes after the commit (p90 49), because it drains serially at a 300s poll while
# commits land every ~5 minutes. Everything it added over a hook was lifecycle — a
# single-instance flock, a sudo launch, a STOP sentinel, a `--since` that must be chosen
# correctly on every restart, a stale-code trap, a per-commit retry budget that ends in
# "advancing PAST it; this commit will never be reviewed" — and lifecycle is where
# §2082, §2088, §2089, §2090 and §2092 all came from. The reviewer itself was never the
# daemon's: `codex_review.py` spawns a separate CLI either way.
#
# WHAT MAKES IT SAFE TO BE A HOOK. §2108 gave `codex_watch.py` a cursor derived from the
# LEDGER (`--since-ledger`) instead of from process memory, so "which commits need
# review" is a pure function of `advice.jsonl` + `archive/*.jsonl`. That is idempotent
# under concurrent invocation, needs no marker file, and cannot advance past an
# unreviewed commit. It also means the TRIGGER and the BACKSTOP are the same command,
# which is why this one script serves both events.
#
# Contract (each line is a test in tools/tests/test_review_on_commit_hook.py):
#   - every path exits 0: a hook must NEVER block a session, least of all someone else's
#   - stdin (the hook JSON) is closed before any child runs
#   - it prints NOTHING on the common path — measured at §2109, this fires for EVERY
#     session and EVERY subagent in the checkout (13 fires in 30s across 3 sessions),
#     so a chatty hook would bury three transcripts
#   - it dispatches NOTHING when no commit is unreviewed — that is the common case and
#     it must be the cheap one
#   - the review runs in the BACKGROUND: it costs ~151s (p50) and the session does not
#     wait. Verified at §2109 that a backgrounded child outlives the hook process.
#   - it never mutates the ledger itself; only `codex_watch.py` writes there
#   - bash 3.2 safe (macOS): no mapfile, no ${x,,}, no associative arrays
#   - an errexit INHERITED through BASH_ENV is disarmed before anything else runs
#
# §3143 — THE DISARM COMES FIRST (fact 7664bbb3e4c7: every kit hook started from `set -u`
# alone). The eugo deploy image's BASH_ENV turns on `set -eE -o pipefail` (fact 76fb0dc9202e)
# for EVERY non-interactive bash, this hook included whenever Claude Code runs in the
# devcontainer.
# Under it the hold read in STAGE 1a — `head` of an ABSENT `.account-down`, the normal
# state, failing through `pipefail` — ended this hook before it dispatched: measured, a
# non-zero exit (97 under the test's trap) and no review, on every unreviewed commit.
# The cure is the one protomolecule f73c6ba408 (Ben) gave the publish guard.
set +eE +o pipefail
trap - ERR
set -u

# §3103 (§1.85) — WHO dispatched this review, read BEFORE the detach below.
#
# The ledger has never carried an owner, so every session's queue was every other
# session's queue; `session_id` arrives in the hook payload on stdin. This hook had never
# read stdin because it had no use for it — and `exec </dev/null` on the next line means a
# read placed anywhere AFTER it silently returns nothing. That is not a hypothetical: the
# first version of this change sat below the detach, dispatched happily, and stamped every
# entry with an empty session. ORDER IS THE WHOLE FIX.
#
# `[ -t 0 ]` guards the read: under the harness stdin is the payload pipe and EOFs at once,
# but a hand invocation from a terminal would otherwise block on `cat` forever.
SID=""
if [ ! -t 0 ]; then
  SID="$(cat 2>/dev/null | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

# ⚠ THE DETACH STAYS, AND IT STAYS HERE. §2109 put it at the top so the backgrounded
# dispatch below cannot hold the session's stdin open; everything after this line — the
# review included — sees /dev/null, which is what makes `( … ) &` safe to leave running.
exec </dev/null

ROOT="${CLAUDE_PROJECT_DIR:-.}"
WATCH="$ROOT/.claude/scripts/codex_watch.py"
# §3110 — the catch-up's ledger gate reads `unreviewed=` from here (see STAGE 1).
WATCH_DRAIN="$ROOT/.claude/scripts/watch_drain.py"
ADVICE="$ROOT/.adversarial-review/watch"
FULL=0
[ "${1:-}" = "--full" ] && FULL=1

# ⚠ §2121 — A REVIEW MUST NOT DISPATCH A REVIEW. `codex_review.py` spawns the reviewer
# with `cwd=repo`, so a review of THIS repo loads THIS file, and the reviewer's own tool
# calls would fire this hook. Today that costs nothing here — the reviewer's toolset is
# `Read,Grep,Glob`, so the `Bash` matcher never matches — but that set is a variable, not
# a law, and the sibling `Stop` hook took 31 commits before anyone noticed the same
# inheritance. Guarded on the same marker, for the same reason.
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi

# Nothing installed to review with, or nowhere to record it: stay silent and get out.
[ -f "$WATCH" ] || exit 0
[ -d "$ADVICE" ] || exit 0

# STAGE 1 — the cheap gate, skipped for --full (the SessionStart backstop, which must
# also catch a commit whose review FAILED and therefore left HEAD unchanged).
#
# Stateless on purpose: a marker file recording "the HEAD we last dispatched for" would
# be a second cursor to go stale, be lost, or collide between the three sessions that
# share this checkout and run as different UNIX users. Asking the ledger directly costs
# one tail+grep (~3 ms against ~35 ms for the full check) and cannot disagree with it.
if [ "$FULL" -eq 0 ]; then
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || exit 0
  [ -n "$HEAD_SHA" ] || exit 0
  if tail -c 20000 "$ADVICE/advice.jsonl" 2>/dev/null | grep -qF "$HEAD_SHA"; then
    exit 0          # HEAD is already reviewed; anything older is the backstop's job
  fi
else
  # ⚠ §3110 (§1.85) — THE CATCH-UP HAD NO GATE AT ALL, and that made it the amplifier.
  # `--full` fires on EVERY SessionStart and deliberately skips the HEAD grep above,
  # because its whole job is to catch what that grep cannot see: a commit whose review
  # FAILED (HEAD unchanged but unreviewed) and unreviewed commits OLDER than HEAD. So it
  # dispatched unconditionally, and only the lock probe below could still stop it — every
  # new session paying an interpreter start and a doomed process, or worse, a real review
  # pass over a ledger with nothing in it to review.
  #
  # The cure is NOT the HEAD grep (it answers the wrong question) and NOT a marker file —
  # the comment above explains why a second cursor is refused here, and that reasoning is
  # unchanged. It is to ask the LEDGER the question the catch-up actually has: is anything
  # unreviewed? `unreviewed=` is exactly that count, and it already exists.
  #
  # ⚠ "?" IS NOT ZERO. It is what the count degrades to when git cannot answer, and the
  # established rule in `unreviewed_count`, `eugo-watch-owed.sh` and `_changed_lines` is
  # that a detector's failure must never be read as an absence. Anything that is not a
  # literal `0` dispatches, so the gate can only ever SKIP work it positively knows is
  # absent. Costs one interpreter start per SessionStart — startup, resume, clear and
  # compact each fire `--full` (§3143, §1.94 L7: this said "ONCE per session") — against
  # a review at ~151s.
  UNREV="$(python3 "$WATCH_DRAIN" status 2>/dev/null \
            | grep -o 'unreviewed=[^ ]*' | head -1 | cut -d= -f2)"
  if [ "$UNREV" = "0" ]; then
    exit 0
  fi
fi

# STAGE 1a — §3121 (§1.90 cure A): an account hold is in force. §3095 made the watcher read
# `.account-down` at startup and exit, which removed the ~151 s SPEND of reviewing against an
# account that cannot answer — but not the SPAWN: a 154-commit outage day was still 154
# interpreter starts to read one file. The hook reads it first.
#
# ⚠ FAILS OPEN, AS `codex_watch.read_account_hold` DOES, ON A NARROWER PARSE: only a
# whole-number epoch in the future skips. Absent, unreadable, empty, junk — all dispatch, and
# the watcher makes its own call. §3143 (§1.94 L7) — this called that call "identical"; it
# is not: the watcher takes any float (`float(parts[0])`), so a hand-edited future float such
# as `1999999999.5` dispatches here and the watcher then stands down on it itself. What the watcher
# writes — `int(until)` and at most one account, on one line — the two parse alike. This
# file can only ever make reviewing do LESS, so a corrupt one must never be able to switch
# it off.
#
# §3130 — THE HOLD BELONGS TO AN ACCOUNT: `<until> <accountUuid>`. It skips only when it names
# no account (the pre-§3130 form) or THIS user's current Claude account — the operator swaps
# accounts to replenish quota, and a peer on another account must not be paused. An account
# this hook cannot read never matches: dispatch, and let the watcher decide.
HOLD_LINE="$(head -c 128 "$ADVICE/.account-down" 2>/dev/null | head -n 1)"
HOLD_UNTIL="${HOLD_LINE%% *}"; HOLD_UNTIL="$(printf '%s' "$HOLD_UNTIL" | tr -d '[:space:]')"
HOLD_ACCT=""
case "$HOLD_LINE" in *" "*) HOLD_ACCT="$(printf '%s' "${HOLD_LINE#* }" | tr -d '[:space:]')" ;; esac
case "$HOLD_UNTIL" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$HOLD_UNTIL" -gt "$(date +%s)" ] 2>/dev/null; then
      if [ -z "$HOLD_ACCT" ]; then
        exit 0
      fi
      CUR_ACCT="$(python3 -c 'import json,os,sys
b=os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~")
try: print(((json.load(open(os.path.join(b,".claude.json"))) or {}).get("oauthAccount") or {}).get("accountUuid") or "")
except Exception: print("")' 2>/dev/null)"
      [ -n "$CUR_ACCT" ] && [ "$CUR_ACCT" = "$HOLD_ACCT" ] && exit 0
    fi ;;
esac

# STAGE 1b — is a review ALREADY running? If so there is nothing to do, and finding
# that out here rather than in a spawned python is the difference between free and
# expensive. MEASURED at §2110, the first time this hook ran live: while one review was
# in flight, every subsequent fire from every session dispatched a doomed process that
# died on the single-instance flock — 301 of them in a few minutes, each costing an
# interpreter start and a log line. A review takes ~151s (p50) and this hook fires
# ~1,500x/hour across the checkout's three sessions, so that window is the COMMON case,
# not an edge one.
#
# A SHARED lock request is the probe: `flock` refuses it while an exclusive lock is held,
# and grants it otherwise. Opened READ-ONLY so it works no matter which user created the
# file — the defect §2110 also fixed on the writer side.
if [ -e "$ADVICE/.watch.lock" ]; then
  # ⚠ §2128 — the redirect is on the GROUP, not on `exec`. `exec 9<f 2>/dev/null` makes
  # the `2>/dev/null` an argument to EXEC, permanently rebinding this script's stderr for
  # everything after it. That silenced the sibling turn-end hook's blocking report for its
  # whole life. Harmless here today — this hook writes nothing to stderr — and corrected
  # anyway, because "harmless in the current code" is how the other one started.
  if { exec 9<"$ADVICE/.watch.lock"; } 2>/dev/null; then
    if ! flock -n -s 9 2>/dev/null; then
      exec 9<&-
      exit 0        # a review is in flight; it selects from the same ledger
    fi
    flock -u 9 2>/dev/null
    exec 9<&-
  fi
fi

# STAGE 2 — hand off to the daemon's own one-shot. Nothing about the review path
# changes: `codex_watch.py` builds the same argv, writes the same raw dir, takes the
# same `.advice.lock`, and appends the same entry schema — which matters because
# `watch_drain._entry_problem` kills the whole drain on one malformed line.
#
# `--once` is one DISPATCH, not always one tick. §3143 — this said "exits after a single
# tick", untrue since §3120: while a commit whose committer time is at or after this
# session's earliest ledger entry (`session_start_epoch` — on a shared clone a peer's commit
# counts too) is unreviewed and not yet tried by this process, the one-shot runs another
# tick at once, with no sleep; an account hold stops it, and a dispatch with no session id
# owns nothing. If a review is already running its single-instance flock refuses this one,
# which is the correct outcome and not an error: the running process selects from the same
# ledger, and whatever it leaves outstanding the next dispatch selects again (§2108).
LOG="$ROOT/outputs/_state/logs/review-on-commit.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
# §3044 — identify the dispatcher to the ledger through the ENVIRONMENT, never argv: this
# hook and codex_watch.py are pinned by different carriers, so a `--writer` flag into an
# older copy is an argparse exit 2 in a log nobody reads, while an unknown env var is
# simply ignored. The value must be one of `codex_watch.WRITERS`.
( cd "$ROOT" 2>/dev/null &&
  EUGO_REVIEW_WRITER=hook-commit EUGO_REVIEW_SESSION="$SID" python3 "$WATCH" --once --since-ledger --commits --no-worktree \
      --engine claude --advice-dir ".adversarial-review/watch"
) >>"$LOG" 2>&1 &

exit 0
