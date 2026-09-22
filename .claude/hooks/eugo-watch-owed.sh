#!/usr/bin/env bash
# §2090 — Claude Code SessionStart hook (startup|resume|clear|compact): say what the
# review-watch daemon is owed, at the one moment a session is guaranteed to look.
#
# WHY THIS EXISTS. The daemon reviews every commit on the shared branch and writes its
# verdicts to `.adversarial-review/watch/advice.jsonl`. Nothing ever told a session they
# were there: a verdict was found only when someone remembered to run the drain. In one
# day that cost four commits reviewed by nobody, a finding that sat unread for hours, and
# seven commits dropped during an account outage that no session noticed had begun. The
# daemon cannot push — it runs as another OS user and the session sockets are 0600 to
# theirs — so the supported route is a hook, and this is it.
#
# Contract (each line is a test in tools/tests/test_watch_owed_hook.py):
#   - every path exits 0: a session is NEVER blocked by this hook
#   - stdin (Claude Code's hook JSON) is closed before any child runs
#   - exactly ONE line on stdout, always — silence would be indistinguishable from a
#     hook that no longer runs, which is the failure this whole file argues against
#   - the drain is READ-ONLY here: `status`, never `rotate`
#   - a missing repo, a missing drain script or a broken one still prints one line
#   - bash 3.2 safe (macOS): no mapfile, no ${x,,}, no associative arrays
set -u
exec </dev/null

ROOT="${CLAUDE_PROJECT_DIR:-.}"
DRAIN="$ROOT/.claude/scripts/watch_drain.py"

say() { printf 'review watch: %s\n' "$1"; exit 0; }

[ -f "$DRAIN" ] || say "drain script not found at .claude/scripts/watch_drain.py — cannot report owed verdicts"

# `status` is read-only and cheap. ⚠ §2183 — it is NO LONGER git-free: `unreviewed` asks
# `codex_watch.unreviewed_commits`, which runs `git rev-list`. Re-measured on this repo
# after that change: 128 ms, from 88 ms. The `unreviewed` count degrades to `?` when git is
# absent or the tree is not a checkout, and never raises.
#
# ⚠ §2196 — "IT EXITS 0 ON EVERY PATH, INCLUDING A MISSING ADVICE DIR" WAS FALSE, AND §2183
# RE-ASSERTED IT. `cmd_status` opens with `_require_dir`, which raises
# `DrainError(EXIT_FAIL)`: `watch_drain.py --advice-dir <absent> status` prints
# `ERROR: advice dir not found: …` and exits 1. So the `||` branch below is live code, not
# the unreachable guard two comments described — and the state it fires in is a NORMAL one:
# `init-hooks --review` registers this row (watch-owed is not in `_DEFAULT_KEYS`), so every
# freshly wired repo sits without `.adversarial-review/watch/` — and ⚠ §3069: NOTHING
# creates it in hook mode ("until its first review creates it" was false: the on-commit
# hook exits before dispatching while the directory is absent, so the first review never
# comes). `eugo-skills arm-review` seeds the tracked RESOLVED.md that creates it on every
# clone. Parsing stdout rather than `$?` is still right; the reason is that status exits
# 0 whenever it CAN report, not that it always can.
#
# ⚠ AND THE GUARD IS ON THE FAILURE PATH, NOT AHEAD OF IT. The first version of this fix
# tested for the directory BEFORE running the drain and short-circuited — which silenced a
# drain that could have reported perfectly well, and went red across six existing arms that
# supply a working stub without creating the tree. Ask the drain first; only interpret a
# FAILURE.
if ! OUT="$(cd "$ROOT" && python3 "$DRAIN" status 2>/dev/null)"; then
  if [ ! -d "$ROOT/.adversarial-review/watch" ]; then
    say "no .adversarial-review/watch yet — review is wired but NOT armed (the hooks exit before dispatching); \`eugo-skills arm-review --into .\` seeds it, then commit"
  fi
  say "watch_drain.py status failed — run it yourself"
fi
[ -n "$OUT" ] || say "watch_drain.py status printed nothing — run it yourself"

# `status` puts some fields alone on a line and others together (`owed=N unresolved=M`),
# so split on spaces first: an anchored line match silently found neither of those two.
field() { printf '%s\n' "$OUT" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }

UNRESOLVED="$(field unresolved)"
LOCK="$(field watch_lock)"
STALE="$(field stale)"
# ⚠ §2123 — COMMITS NOBODY REVIEWED, which `unresolved` never counted. A review that
# fails its way to the retry cap produces no owed row, so 31 abandoned commits on this
# repo's own branch went unnoticed until someone queried the ledger by hand. `?` means the
# sibling `codex_watch.py` is absent or too old to answer — not that the number is zero.
# ⚠ §2189 — THE CURE MUST REACH WHAT THE COUNT MEASURES. The counts below are ledger-wide
# and unbounded; `--retry-abandoned` alone is bounded by `--ledger-scan`, default 100, and
# the candidate set is built BEFORE the retry filter is applied. A stuck ref ages past 100
# commits precisely because it is excluded, so the flag silently stops reaching it — the
# two refs §2179 counted were 307 and 308 commits back and needed `--ledger-scan 330`.
# `status` now computes the depth; empty means nothing is stuck, `?` means it could not ask.
RETRY_SCAN="$(field retry_scan)"
case "$RETRY_SCAN" in
  ""|"?") RETRY_CURE="--retry-abandoned --ledger-scan <deep enough to reach them> --wait-for-lock 900" ;;
  *) RETRY_CURE="--retry-abandoned --ledger-scan $RETRY_SCAN --wait-for-lock 900" ;;
esac
# ⚠ §2912 — AND `--wait-for-lock`, OR THE CURE IS REFUSED. The hooks take the review lock on
# every commit, and `codex_watch.py` without that flag refuses the moment another run holds
# it (`_acquire_single_instance`, default 0 = refuse at once) and returns 1 having reviewed
# nothing. Its own help names this case: a backlog pass that refuses and re-races is starved
# (§2155). finding-triage.md §10 prints the full one-shot; this line had the flags without it.
# The lines above are cited by number from codex_watch.py, so this note sits below them.

ABANDONED="$(field abandoned)"
ABANDON_NOTE=""
case "$ABANDONED" in
  ""|"?"|0) ;;
  *) ABANDON_NOTE="; ⚠ $ABANDONED commit(s) ABANDONED unreviewed — $RETRY_CURE" ;;
esac
# ⚠ §2179 — A REFUSAL IS NOT A GIVE-UP, and reporting both as "ABANDONED unreviewed" asked
# for an action that did not exist. §2627/§2628 are a ~4.95 MB runlog.jsonl reformat that
# answered "Prompt is too long" on every attempt; no amount of pushing the watcher would
# have reviewed them, and the banner said otherwise every session for days. §2177 splits an
# oversized diff and §2178 stops charging three retries for the refusal, so the cure named
# here is one that works.
UNREVIEWABLE="$(field unreviewable)"
case "$UNREVIEWABLE" in
  ""|"?"|0) ;;
  *) ABANDON_NOTE="$ABANDON_NOTE; ⚠ $UNREVIEWABLE commit(s) UNREVIEWABLE (the diff was refused, not given up on) — oversized diffs are split now, so rerun with $RETRY_CURE" ;;
esac

# ⚠ §2183 — THIS LINE REPORTED A DAEMON §2109 RETIRED, AND THE LOCK STOPPED MEANING WHAT
# IT READ AS. It was: `watch_lock=held` -> "daemon up", anything else -> "⚠ DAEMON NOT
# RUNNING", because until §2109 a polling daemon held that lock for its whole life. Review
# is dispatched by hooks now — `codex_watch.py --once` takes the lock for ~150s and exits —
# so a held lock means "a review is running this second" and a free lock is the NORMAL
# idle state. Measured on this checkout inside one minute: three fires said `daemon up`
# (Bash calls were dispatching reviews) and one said `DAEMON NOT RUNNING`, nothing wrong
# either time. A banner that alarms on health and reassures on accident is §2179's defect
# one line up: it named a cure ("restart the daemon") that no longer exists.
#
# The two questions a reader can act on are whether review is WIRED and whether anything
# is UNREVIEWED, and `status` now answers both. The lock becomes what it is: informational.
#
# ⚠ THE DAEMON CASE IS KEPT, NOT DELETED. An `--interval` daemon can still be launched
# deliberately and the stale-code warning is meaningful only for it; `holder` tells them
# apart from the lock holder's own argv. Dropping it would trade a false alarm for a blind
# spot, which is the trade this commit exists to undo.
WIRED="$(field review_wired)"
UNREVIEWED="$(field unreviewed)"
HOLDER="$(field holder)"
# §3069 — the per-tick budget the watcher will honour (`tick_budget=` from a §3067 drain;
# "" from an older one), so a pending catch-up is priced before it is spent.
BUDGET="$(field tick_budget)"
# §3109 — how long the OLDEST pending commit has waited. The depth alone cannot tell a
# healthy burst from a queue that is not keeping up, and the p90 of 63.9 min measured on
# this repo 2026-09-22 was noticed by the operator, never by this line. "" from an older
# drain and "?" when git could not answer; neither is zero.
OLDEST="$(field unreviewed_oldest_h)"

case "$WIRED" in
  no)
    REVIEW="⚠ review is NOT wired — no PostToolUse hook dispatches it; \`eugo-skills init-hooks --review\`" ;;
  unrunnable)
    REVIEW="⚠ review hook is registered but NOT EXECUTABLE — \`chmod 755 .claude/hooks/eugo-review-on-commit.sh\`" ;;
  "?")
    REVIEW="⚠ review wiring unknown (.claude/settings.json is present and will not parse)" ;;
  "")
    # ⚠ AN EMPTY FIELD IS NOT `?`. Every consumer repo ships a `watch_drain.py` older than
    # this field, and there `field review_wired` returns "" — which must stay SILENT about
    # wiring rather than alarm, the rule `abandoned` and `unreviewable` already follow.
    # `?` means the file is THERE and will not parse, which is a finding; "" means nobody
    # was asked. So an old drain gets exactly what the lock supports and no claim beyond it.
    case "$LOCK" in
      held) REVIEW="review running" ;;
      *) REVIEW="review idle" ;;
    esac ;;
  *)
    case "$LOCK" in
      held)
        case "$HOLDER" in
          daemon) REVIEW="daemon up" ;;
          once) REVIEW="review running" ;;
          *) REVIEW="review running (lock holder unidentified)" ;;
        esac ;;
      *) REVIEW="review wired" ;;
    esac
    # `?` is not zero — the count degrades to it when git cannot answer — and a trailing
    # `+` means the scan window was exhausted, so the number is a floor.
    case "$UNREVIEWED" in
      ""|"?"|0) ;;
      *)
        REVIEW="$REVIEW; ⚠ $UNREVIEWED commit(s) unreviewed"
        # §3109 — the AGE, when the drain reports one. Only above 1h, because below that
        # the number is noise on every healthy session and a line that warns constantly is
        # one a reader learns to skip — the §2120 rule for ERROR entries, applied here.
        case "$OLDEST" in
          ""|"?") ;;
          *[!0-9.]*) ;;
          *) case "${OLDEST%%.*}" in
               ""|0) ;;
               *) REVIEW="$REVIEW, oldest ${OLDEST}h" ;;
             esac ;;
        esac
        # §3069 — name the pace: a positive integer budget means the next dispatches
        # review at most that many each (HEAD first); "" (old drain) or 0 (unbounded)
        # keep the line as it was.
        case "$BUDGET" in
          ""|0|*[!0-9]*) ;;
          *) REVIEW="$REVIEW — reviewed at ≤$BUDGET per tick" ;;
        esac ;;
    esac ;;
esac
# §2092 — a RUNNING daemon can still be the wrong daemon: `stale=yes` means the script
# changed after that process started, so it reviews with the old code and `rotate` will
# refuse. ⚠ §2183 NARROWS IT, AND THE NARROWING IS "CONFIRMED HARMLESS", NOT "CONFIRMED
# HARMFUL". A stale `--once` is harmless — it reviews and exits, and this checkout edits
# `codex_watch.py` constantly, so firing on those made the warning routine, which is how a
# warning stops being read. But an UNIDENTIFIED holder, or a drain too old to report one,
# cannot be ruled out as a daemon: a consumer repo shipping the old drain may also be
# running the old `--interval` regime, which is precisely who §2092 protects. So only a
# holder positively identified as `--once` suppresses it.
if [ "$STALE" = "yes" ] && [ "$LOCK" = "held" ] && [ "$HOLDER" != "once" ]; then
  REVIEW="⚠ daemon RUNNING STALE CODE (restart it; rotate will refuse)"
fi

# §3123 (§1.89 cure 3) — a RESOLVED.md row the drain cannot parse closes nothing, and the
# writer who minted it never finds out: `status` counted it and no banner field read it.
MALFORMED="$(field malformed_rows)"
case "$MALFORMED" in
  ""|0|*[!0-9]*) ;;
  *) REVIEW="$REVIEW; ⚠ $MALFORMED malformed RESOLVED.md row(s) — status must START with FIXED/OPEN/REFUTED/RETRY/UNTRACED/CLAIMED (watch_drain.py --help)" ;;
esac

# §3122 — a persisted quota hold pauses every dispatch; say so, or reviewing is silently off.
HOLD="$(field account_hold_until)"
case "$HOLD" in
  ""|-) ;;
  *) REVIEW="$REVIEW; review PAUSED until $HOLD (account quota — clear .adversarial-review/watch/.account-down after switching accounts)" ;;
esac

# §3122 (§1.88) — LEAD WITH THE WORK. `unresolved` counts reviews an account outage never
# let happen (protomolecule, 2026-09-21: 372 owed, 282 of them one session limit); the drain
# now splits them. An older drain prints neither field, and then the line is exactly as before.
WORK="$(field unresolved_work)"
DOWN="$(field unresolved_account_down)"
OUTAGES=""
case "$WORK:$DOWN" in
  *[!0-9:]*|:*|*:) WORK="$UNRESOLVED" ;;
  *) [ "$DOWN" -gt 0 ] && OUTAGES=" (+$DOWN failed on account quota, not findings)" ;;
esac
case "$UNRESOLVED" in
  "") say "could not read the owed count from watch_drain.py status — $REVIEW$ABANDON_NOTE" ;;
  0) say "nothing owed; $REVIEW$ABANDON_NOTE" ;;
  *) say "$WORK verdict(s) owed a row$OUTAGES — python3 .claude/scripts/watch_drain.py list --unresolved; $REVIEW$ABANDON_NOTE" ;;
esac
