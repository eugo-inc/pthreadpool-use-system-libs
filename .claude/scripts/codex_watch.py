"""Codex continuous-review companion daemon (1.0.0) — the `watch` mode of /eugo-adversarial-review.

Runs ALONGSIDE another command (a live human session, or `/eugo-run-overnight`) and advises on edits AS
THEY LAND, instead of only pre/post review. Each tick it reviews, via `codex_review.py` (the driver):
  * COMMITS  — every new commit since the last seen (`git show <sha>`), deduped by sha;
  * WORKTREE — the current uncommitted `git diff HEAD`, deduped by content-hash + debounced.
TWO ENGINES since §1244 (`--engine`, forwarded to the driver; default `codex`, unchanged). The daemon
still cannot call the Claude `advisor()` tool — that stays in the interactive modes — but `--engine
claude` drives the Claude CLI headless, which needs no interactive login and is therefore the only
engine usable where `codex login status` reports `Not logged in`. That state was previously invisible:
every tick returned ERROR and the tick handler below swallows it, so hours of silence read as quiet.
Light by default (1 model per engine, effort `high`) since it runs repeatedly. Pure stdlib, host-`python3`,
dev-only (under `.claude/`, outside the conda `eugo_kb` env + the Docker images).

```
python3 .claude/scripts/codex_watch.py [--repo <dir>] \
    [--commits|--no-commits] [--worktree|--no-worktree] [--interval 60] [--wt-min-interval 180] \
    [--since <sha>] [--models gpt-5.5] [--effort high] [--advice-dir .adversarial-review/watch] \
    [--once] [--max-ticks N]
```

Appends one JSON object per reviewed increment to `<advice-dir>/advice.jsonl` (+ a human `advice.md`
mirror) and prints a one-line summary (so it surfaces under `run_in_background`/Monitor). A consumer
(`/eugo-run-overnight`) cursors `advice.jsonl` by `ts`. The advice is codex-RAW — the consumer MUST
triage-vs-invariants + verify before acting (codex false-positives on intentional design). Stops on a
`<advice-dir>/STOP` sentinel (consumed at launch — touch it AFTER startup), `--max-ticks`, `--once`, or SIGTERM/SIGINT.
§2131 — ONE SENTINEL PER LANE, pairing with §2124's per-kind lock: `STOP` is the commit lane (the documented
gesture, unchanged) and `STOP.worktree` the worktree-only one, so a turn-end one-shot cannot eat a daemon's stop.
"""

from __future__ import annotations

import argparse
import calendar
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

DRIVER = Path(__file__).resolve().parent / "codex_review.py"
# This repo root (/opt/eugo/athena) — `.claude/scripts/codex_watch.py`.parents[2].
REPO_ROOT = str(Path(__file__).resolve().parents[2])
# The codex team roster — a mirror of codex_review.DEFAULT_MODELS (the two places model ids live;
# eugo_kb §3.5). Watch stays LIGHT by default: a single model (the roster's FIRST) at effort `high`,
# since it runs every tick; the full team is the one-shot driver's default. `_WATCH_DEFAULT_MODEL`
# is DERIVED from the roster so editing DEFAULT_MODELS here also moves the watch default (no dead var).
DEFAULT_MODELS = ["gpt-5.5", "gpt-5.3-codex-spark"]
_WATCH_DEFAULT_MODEL = DEFAULT_MODELS[0]
# §1244 — the same LIGHT rule for the `claude` engine: one model, derived from the
# driver's roster rather than restated, so the two cannot drift apart silently.
DEFAULT_CLAUDE_MODELS = ["opus"]
_WATCH_DEFAULT_CLAUDE_MODEL = DEFAULT_CLAUDE_MODELS[0]

# §1648 (§1.57-F6) — the GATEWAY roster, mirrored from `codex_review.GATEWAY_DEFAULT_MODELS`
# for the same reason the codex roster above is mirrored, and pinned by the same kind of
# parity test. §1244 resolved the light default per ENGINE; `--codex-bin kiro` leaves
# `engine == "codex"`, so a gateway daemon defaulted to `gpt-5.5` — an OpenAI id the kiro
# gateway cannot answer — and every tick failed.
GATEWAY_DEFAULT_MODELS = ["gpt-5.6-sol"]
_WATCH_DEFAULT_GATEWAY_MODEL = GATEWAY_DEFAULT_MODELS[0]

#: Mirrors `codex_review._KIRO_SHORTHAND`'s 2-9 bound rather than re-deriving it:
#: `kiro1` is deliberately NOT a shorthand upstream (instance 1 is plain `kiro`), and a
#: copy that accepted it would hand the wrong light default to a binary that does not exist.
_GATEWAY_BIN_RE = re.compile(r"^kiro([2-9])?$")


def _is_gateway_binary(name: str) -> bool:
    """True when a --codex-bin value reaches kiro-gateway (`kiro`, `kiro2`..`kiro9`)."""
    return bool(name) and _GATEWAY_BIN_RE.fullmatch(name) is not None
DEFAULT_ENGINE = "codex"
# §934 — consecutive empty `git show` results tolerated before a sha is abandoned.
_MAX_SHOW_RETRIES = 3
#: §2132 — the note on a ledger entry recording an empty `git show`. Deliberately NOT one
#: of `_ACCOUNT_DOWN_MARKERS`: an unreadable commit is this commit's problem, so it SHOULD
#: spend the retry budget, which is the opposite of the §2114 outage rule.
SHOW_EMPTY_NOTE = "git show returned empty"
# §1700 (§1.57-F6) — the same bound for a FAILING DRIVER. §1648 made a non-zero
# driver exit loud and left the anchor advancing, so a commit whose review failed
# was never looked at again. Held and retried, but BOUNDED for the reason
# `_MAX_SHOW_RETRIES` is: a permanently broken driver must not wedge the watcher.
_MAX_REVIEW_RETRIES = 3

#: §2089 — default hold after an account-level failure. See `_account_is_down`.
_ACCOUNT_BACKOFF_S = 1800

#: Notes that mean the ACCOUNT cannot review ANYTHING, as distinct from this commit
#: failing. The retry bound above is right for the second kind — a timeout, a capture
#: with no verdict line — and catastrophic for the first: every commit in turn spends
#: its three attempts, is declared unreviewable and is advanced PAST for good. Measured
#: 2026-09-08: one OAuth expiry produced 21 entries across SEVEN CONTIGUOUS commits,
#: each permanently unreviewed and recoverable only by hand.
#:
#: ⚠ SUBSTRING MATCHES ON VENDOR TEXT, so this WILL rot when the CLI rewords a message.
#: That is a deliberate trade and the failure is safe in the right direction: an
#: unrecognised note simply takes the existing per-commit retry, which is what every
#: note takes today. The driver passes the CLI's own stderr tail through verbatim
#: (`codex_review.py`'s claude engine), so there is no structured code to key on.
_ACCOUNT_DOWN_MARKERS = (
    "hit your session limit",
    "hit your weekly limit",
    "hit your usage limit",
    "failed to authenticate",
    "oauth session",
    "not found on path",
    # ⚠ §2197 — THE MARKER FOR A MISSING BINARY NEVER FIRED FOR THE CASE IT EXISTS FOR.
    # "not found on path" matches `_run_one`'s FileNotFoundError note (codex_review.py:627,
    # :715), but that path is only reached if exec is ATTEMPTED — and the driver's preflight
    # runs `shutil.which(cli)` first and prints `ERROR: <bin> CLI not on PATH (...)` before
    # any exec, so the reachable message is a different string. Lowercased, "cli not on path"
    # does not contain "not found on path". Measured: feeding the real preflight tail to
    # `_account_is_down` returned None and `failed_attempts` charged the outage to the
    # COMMIT — against this block's own docstring, and against `failed_attempts`' comment
    # naming "a missing binary" as one of the three account-level failures it must never
    # charge. Three ticks then abandon three commits for a wrong PATH. §1969 records the
    # same message costing two hours of silent ERROR once already.
    "cli not on path",
)


def _account_is_down(entry: dict) -> str | None:
    """The note saying the ACCOUNT is unusable, or None when the failure is this commit's."""
    texts = [(r.get("note") or "") for r in (entry.get("results") or [])]
    texts.append(entry.get("driver_stderr_tail") or "")
    for text in texts:
        low = text.lower()
        if any(marker in low for marker in _ACCOUNT_DOWN_MARKERS):
            return " ".join(text.split())[:160]
    return None

#: §3043 — WHO wrote a ledger entry, carried in the ENVIRONMENT and never argv: the hooks
#: and this file are pinned by DIFFERENT carriers, so a `--writer` flag from a newer hook
#: into an older copy of this script is an argparse exit 2 in a log nobody reads, while an
#: unknown env var is simply ignored. Only a value in `WRITERS` is stamped — an invented
#: value would be `other_verdicts` drift one field over. Entries written before this
#: field existed carry no `writer` and read `unknown` in `watch_drain status`: the
#: daemon-vs-hook coverage gate is satisfiable forward, never backward.
WRITER_ENV = "EUGO_REVIEW_WRITER"
#: MIRRORS `watch_drain.WRITERS` — pinned equal by test_watch_drain.py.
WRITERS = ("hook-commit", "hook-turn-end", "daemon", "once")
_WRITER = "daemon"  # resolved once in main(), read by _append_entry


def _resolve_writer(once: bool, env: dict | None = None) -> str:
    """The writer to stamp: the env value when it is in WRITERS, else the run's mode."""
    val = ((env if env is not None else os.environ).get(WRITER_ENV) or "").strip()
    if val in WRITERS:
        return val
    return "once" if once else "daemon"


#: §3067 (§1.75) — HOW MANY commits one `--since-ledger` tick may REVIEW, carried in the
#: ENVIRONMENT for the same reason as WRITER_ENV: a flag from a newer hook into an older
#: installed copy is an argparse exit 2 in a log nobody reads, an unknown env var is
#: ignored. `--tick-budget` overrides it for operator passes; 0 = unbounded (the
#: `--max-ticks` convention). The default is 3 — HEAD and two of the backlog per dispatch,
#: ~7.5 min of review — because the hook fires on every commit and turn end, so a stale
#: checkout that pulls 30 commits drains them over ten dispatches instead of one 75-minute
#: background burn on the session user's credentials. Operator ruling 2026-09-21.
TICK_BUDGET_ENV = "EUGO_REVIEW_TICK_BUDGET"
DEFAULT_TICK_BUDGET = 3
#: §3067 (§1.76) — THE ARMING BOUNDARY, read from the tracked `RESOLVED.md` beside the
#: ledger: `<!-- armed-at: <sha40> -->`, written by `eugo-skills arm-review`. Commits at or
#: before it are never selected: a freshly armed repo reviews what lands AFTER the arming,
#: never its history (operator ruling 2026-09-21: forward-only). MIRRORS
#: `watch_drain.ARMED_RE`, pinned equal by test_watch_drain.py.
ARMED_RE = re.compile(r"^<!-- armed-at: ([0-9a-f]{40}) -->$", re.M)
#: §3067 (§1.76) — WHOSE commits are ours. A vendored fork's history is mostly upstream's
#: (eugo-grpc: 79 of the last 100 commits, 2026-09-21), brought in by sync merges; the
#: merge commit is reviewed as its combined diff (the conflict resolutions — cheap and
#: right), the commits it carried are NOT ours to review. Reachability from the upstream
#: ref is the test — never an author filter: ring, eugo-website and eugo-university have
#: outside collaborators whose code the operator wants reviewed.
_UPSTREAM_TABLES = ("review", 'skills.adapters."eugo-upstream-merge"')
_UPSTREAM_KEY_RE = re.compile(r'^\s*upstream_ref\s*=\s*"([^"]+)"')
_TOML_TABLE_RE = re.compile(r"^\s*\[([^\]]+)\]")
_UPSTREAM_WARNED: set[str] = set()


def resolve_tick_budget(env: dict | None = None) -> int:
    """The per-tick review budget: the env value when it is a non-negative int, else the default."""
    val = ((env if env is not None else os.environ).get(TICK_BUDGET_ENV) or "").strip()
    if val.isdigit():
        return int(val)
    return DEFAULT_TICK_BUDGET


def armed_at(advice_dir: Path) -> str | None:
    """The `armed-at` sha in `<advice_dir>/RESOLVED.md`, or None (absent, unreadable, or not
    exactly one marker). The path is a LITERAL, not a `_transient` join: RESOLVED.md is a
    TRACKED file (org rule D5), so it must never reach the transient-file registry."""
    try:
        text = (advice_dir / "RESOLVED.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    found = ARMED_RE.findall(text)
    return found[0] if len(found) == 1 else None


def _configured_upstream_ref(repo: str) -> str | None:
    """`upstream_ref = "…"` from `.eugo.toml`'s `[review]` table, else the fork kit's
    `[skills.adapters."eugo-upstream-merge"]` table. A line scanner, not tomllib: the hook
    runs whatever `python3` the checkout's host has, and the two keys are all it needs."""
    try:
        lines = (Path(repo) / ".eugo.toml").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    found: dict[str, str] = {}
    table = ""
    for line in lines:
        m = _TOML_TABLE_RE.match(line)
        if m:
            table = m.group(1).strip()
            continue
        k = _UPSTREAM_KEY_RE.match(line)
        if k and table in _UPSTREAM_TABLES and table not in found:
            found[table] = k.group(1).strip()
    for table in _UPSTREAM_TABLES:
        if found.get(table):
            return found[table]
    return None


def upstream_ref(repo: str) -> str | None:
    """The ref whose reachable commits are excluded from selection, RESOLVED in this checkout,
    or None. Order: `.eugo.toml [review] upstream_ref` → the fork kit's `upstream_ref` param →
    a remote literally named `upstream` (`upstream/HEAD`, then `upstream/main`, `upstream/master`).
    A configured ref that does not resolve here (no `upstream` remote in this clone, say) is
    reported ONCE per process on stderr and selection proceeds as if none were set — every
    commit in the window, budget-bounded — never silently narrower."""
    configured = _configured_upstream_ref(repo)
    candidates = [configured] if configured else []
    if not configured and "upstream" in _git(repo, "remote").split():
        candidates = ["upstream/HEAD", "upstream/main", "upstream/master"]
    for ref in candidates:
        if _git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip():
            return ref
    if configured and configured not in _UPSTREAM_WARNED:
        _UPSTREAM_WARNED.add(configured)
        print(f"[watch] upstream ref {configured!r} (from .eugo.toml) does not resolve in this "
              f"checkout — selecting from the whole window; `git fetch upstream` restores the "
              f"exclusion", file=sys.stderr, flush=True)
    return None


_STOP = False


def _sig(signum, frame):  # graceful shutdown on SIGTERM/SIGINT
    global _STOP
    del signum, frame  # required by the signal-handler API; unused here
    _STOP = True


def _git(repo: str, *args: str, timeout: int = 30) -> str:
    # §3046 — `errors="replace"`: `git show` of a diff carrying non-UTF-8 bytes is NOT
    # re-encoded by git (a subject is; a diff is not), and a strict decode raised
    # UnicodeDecodeError out of every caller — under `--since-ledger` that one commit was a
    # permanent head-of-line block with no ledger trace, because the exception fired before
    # `_review` could write anything. A U+FFFD in the reviewed text is the right price.
    out = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True,
                         errors="replace", timeout=timeout)
    return out.stdout if out.returncode == 0 else ""


def _changed_lines(repo: str) -> int | None:
    """Lines added + deleted in the uncommitted diff, or None when it cannot be read.

    §2116 — the size gate's input. Cheap (one git call, no diff text) and deliberately
    counts BOTH directions: a large deletion is as reviewable as a large addition.

    ⚠ None means UNKNOWN, and the caller must treat unknown as "review it". Returning 0
    for an unparseable `--shortstat` would make the gate fail CLOSED — silently skipping
    every review the moment git's output shape changed or the call failed. That is the
    §703 shape (a detector's zero read as a fact about the tree), and it was not
    hypothetical: it turned two existing tests red the first time this ran, because their
    git stub answers every call with one fixed string.
    """
    stat = _git(repo, "diff", "--shortstat", "HEAD")
    if not stat.strip():
        return None
    found = re.findall(r"(\d+) (?:insertion|deletion)", stat)
    if not found:
        return None
    return sum(int(n) for n in found)


def _critical_section(md: str) -> str:
    """Extract the '## Critical Issues (Blocking)' body from a driver code-review output."""
    lines, grab, buf = md.splitlines(), False, []
    for ln in lines:
        if ln.strip().startswith("## Critical Issues"):
            grab = True
            continue
        if grab and ln.strip().startswith("## "):
            break
        if grab:
            buf.append(ln)
    return "\n".join(buf).strip()


#: §2108 — THE LEDGER IS THE CURSOR (`--since-ledger`).
#:
#: The default anchor is a LOCAL VARIABLE: `last_sha = cfg.since or rev-parse HEAD`,
#: advanced in the tick loop and written nowhere. Nothing reads `advice.jsonl` back.
#: Two consequences, both measured before this was written:
#:   * a fresh one-shot with no `--since` anchors at HEAD and reviews NOTHING, so the
#:     process is the only thing that knows where it got to;
#:   * a commit the retry budget gives up on is "advanced PAST … never reviewed"
#:     (the §2082 / §2088 / §2089 loss class), because the anchor moved and no record
#:     of the gap survives anywhere.
#: Deriving the cursor from the ledger removes both. A commit with no `kind: "commit"`
#: entry is unreviewed BY DEFINITION, so a failed review leaves the commit selected and
#: the next tick retries it; nothing is ever advanced past. It is idempotent under
#: concurrent invocation (two callers compute the same set, `.advice.lock` serialises the
#: append), and it needs no marker file that could go stale or be lost.
#: Measured at §2108: 1,195 refs read in 5 ms; the unreviewed answer in 10 ms total.
#: §2110 — A FAILED REVIEW IS NOT A REVIEW, and §2108 shipped believing otherwise.
#:
#: `_review` appends its entry INSIDE `_advice_lock` before the caller ever inspects
#: `driver_exit`, so a failed attempt writes a `kind: "commit"` line with a real `ref`
#: just like a successful one. §2108's predicate counted any such line, which meant a
#: failed review marked the commit reviewed FOREVER — zero retries, where the `--since`
#: path gave it `_MAX_REVIEW_RETRIES`. That is the §2082/§2088/§2089 loss class made
#: WORSE inside the commit that claimed to close it, and the claim was in its message.
#:
#: MEASURED on the live ledger at §2110: 1,340 commit entries carry 207 `ERROR` verdicts
#: and 19 empty `results`, and **101 shas have ONLY ever failed** — every one of them
#: silently written off. Correcting the predicate makes 18 of the last 400 commits
#: reviewable again.
#:
#: The vocabulary is not invented here: `watch_drain.OWED_VERDICTS` is
#: `{"NEEDS_REVISION", "ERROR"}` — the drain already treats an ERROR entry as UNRESOLVED
#: rather than done. This is the same judgement, one file over.
FAILED_VERDICTS = frozenset({"ERROR"})


#: §2178 — a failure the COMMIT causes and REPEATING CANNOT FIX. §2627 and §2628 each
#: answered `note: "Prompt is too long"` on four attempts across seven days; three of them
#: were the retry budget being spent on an outcome that was decided before the first.
#:
#: ⚠ Substring matches on vendor text, and the same deliberate trade `_ACCOUNT_DOWN_MARKERS`
#: records: an unrecognised note simply takes the ordinary per-commit retry, which is what
#: every note took before this existed. The failure is safe in the right direction.
#:
#: With §2177's splitter in front of it this should be unreachable for a normal commit —
#: the dispatch cuts an oversized diff before sending it. It stays because the splitter has
#: a floor (a single line longer than the whole cap) and because a model's real limit is not
#: a constant we control.
_TERMINAL_MARKERS = ("prompt is too long",)


def _terminally_unreviewable(entry: dict) -> str | None:
    """The note saying no number of retries will help, or None."""
    texts = [(r.get("note") or "") for r in (entry.get("results") or [])]
    texts.append(entry.get("driver_stderr_tail") or "")
    for text in texts:
        low = text.lower()
        if any(marker in low for marker in _TERMINAL_MARKERS):
            return " ".join(text.split())[:160]

    return None


def _is_real_review(entry: dict) -> bool:
    """Did this entry actually produce a verdict, or only a record that it tried?

    ⚠ §2178 — A SPLIT ENTRY IS REAL ONLY WHEN EVERY PART CARRIED ONE. Four parts APPROVED
    and one ERROR is not a reviewed commit: the unreviewed fifth is exactly the region a
    reader would assume had been looked at. `any()` over the flat results list would have
    said yes and marked the ref done, which is the §2110 defect — a failed review counting
    as done — reintroduced through a new door. An error is not a verdict (§2165).
    """
    results = entry.get("results") or ()
    split = entry.get("split")
    if isinstance(split, dict) and isinstance(split.get("parts"), int) and split["parts"] > 1:
        got = {result.get("part") for result in results
               if isinstance(result.get("verdict"), str)
               and result["verdict"] not in FAILED_VERDICTS and result["verdict"]}

        return len(got - {None}) == split["parts"]
    for result in results:
        verdict = result.get("verdict")
        if isinstance(verdict, str) and verdict and verdict not in FAILED_VERDICTS:
            return True
    return False


def reviewed_refs(advice_dir: Path) -> set[str]:
    """Every commit sha with a ledger entry that actually CARRIES a verdict.

    An entry whose only result is `ERROR`, or whose `results` is empty, does not count:
    see `FAILED_VERDICTS` above for what that cost when it did.
    """
    out: set[str] = set()
    files = [advice_dir / "advice.jsonl", *sorted((advice_dir / "archive").glob("*.jsonl"))]
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue  # a missing or unreadable ledger means "nothing reviewed yet"
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue  # a torn append is not a reviewed commit; the drain reports it
            if (entry.get("kind") == "commit" and isinstance(entry.get("ref"), str)
                    and _is_real_review(entry)):
                out.add(entry["ref"])
    return out


def worktree_state(advice_dir: Path) -> tuple[set[str], float]:
    """(content hashes already reviewed, epoch of the newest worktree entry).

    §2116 — THE WORKTREE DEBOUNCE, MADE DURABLE. `last_wt_hash` / `last_wt_review` are
    locals in `main()`; a `--once` dispatch resets both, so under the §2109 hook the same
    diff would be re-reviewed on every fire at ~151s each. This is the §2108 fix applied
    to the second increment type: the ledger already records what was reviewed and when,
    so nothing needs to be remembered between processes.

    ⚠ THIS REQUIRED CHANGING WHAT A WORKTREE ENTRY'S `ref` IS, and the old value was
    unusable for two independent reasons. It was `f"wt@{ticks}"` — a TICK COUNTER, which
    means nothing outside the process that wrote it, so it could not dedupe across
    dispatches. And `wt@0` is FOUR characters while `watch_drain.MIN_REF_PREFIX` is 12,
    so a worktree entry could never be addressed by the drain: a NEEDS_REVISION on one
    could never be rowed in RESOLVED.md and `rotate` would refuse forever. The ref is now
    the diff's sha1, which is 40 characters and is the natural dedupe key. Safe to change
    because nothing consumed the old shape (one producer, zero consumers) and there are
    ZERO worktree entries in the ledger or its archives — the mode has never run.
    """
    hashes: set[str] = set()
    newest = 0.0
    files = [advice_dir / "advice.jsonl", *sorted((advice_dir / "archive").glob("*.jsonl"))]
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("kind") != "worktree":
                continue
            ref = entry.get("ref")
            if isinstance(ref, str) and _is_real_review(entry):
                hashes.add(ref)          # a FAILED review must not retire the diff
            ts = entry.get("ts")
            if isinstance(ts, str):
                try:
                    newest = max(newest, calendar.timegm(
                        time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
                except ValueError:
                    pass
    return hashes, newest


def failed_attempts(advice_dir: Path) -> dict[str, int]:
    """How many verdict-less attempts each commit already has, FROM THE LEDGER.

    ⚠ §2112 — THIS REPLACES A PROCESS-LOCAL DICT THAT `--once` COULD NEVER INCREMENT.
    `review_failures` lives in `main()`, so it counts within one process. The daemon ran
    for hours and the count meant something; the §2109 hook spawns a FRESH `--once` per
    dispatch, so `n` was always 1, `n < _MAX_REVIEW_RETRIES` was always true, and the
    "giving up and advancing PAST it" branch was unreachable. Combined with §2110's
    corrected predicate — which correctly stops a failed review counting as done — one
    deterministically-failing commit would be retried on every dispatch AND block every
    newer commit behind it, because `unreviewed_commits` returns oldest-first.

    The ledger already records the history faithfully: measured at §2112, of 101 refs
    that only ever failed, 76 have one attempt and 25 have exactly three — which is
    `_MAX_REVIEW_RETRIES`, the old daemon's give-up point. Counting from the ledger
    reproduces those semantics and makes them survive a process, which the dict never did.
    """
    counts: dict[str, int] = {}
    files = [advice_dir / "advice.jsonl", *sorted((advice_dir / "archive").glob("*.jsonl"))]
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("kind") != "commit" or not isinstance(entry.get("ref"), str):
                continue
            if _is_real_review(entry):
                continue
            # ⚠ §2114 — AN OUTAGE IS CHARGED TO NOBODY, and §2112 forgot that when it
            # moved the budget onto the ledger. §2089 established the rule for the
            # process-local counter: an account-level failure (session/weekly limit,
            # `failed to authenticate`, a missing binary) is not the COMMIT's fault, so
            # spending its retries on one is how seven commits were lost on 2026-09-08.
            # The old dict could not make this mistake — the account-down branch `break`s
            # BEFORE the counter increments — but a ledger entry records the attempt
            # whoever was at fault, so the discrimination has to be re-applied here.
            #
            # Measured on the live ledger at §2114: of 226 verdict-less entries, 99 are
            # account-down, and 30 refs already sat at or over the retry cap on those
            # alone — permanently excluded from review by §2112, having never once been
            # reviewed. `_account_is_down` is reused rather than re-defined, so there is
            # one definition of "outage" in this file, not two.
            if _account_is_down(entry) is not None:
                continue
            # §2178 — A DETERMINISTIC REFUSAL COSTS ONE ATTEMPT, NOT THREE. The budget
            # exists to stop a broken commit wedging the queue; spending two more
            # dispatches on an outcome that was decided by the diff's SIZE buys nothing
            # and costs ~151s of quota each. Saturating rather than skipping, because the
            # ref must still be excluded from selection — it just stops paying for that
            # exclusion three times over.
            if _terminally_unreviewable(entry) is not None:
                counts[entry["ref"]] = _MAX_REVIEW_RETRIES
                continue
            counts[entry["ref"]] = counts.get(entry["ref"], 0) + 1
    return counts


def terminal_refs(advice_dir: Path) -> set[str]:
    """Commits whose review failed for a reason RETRYING CANNOT FIX, and which no reader
    should see reported as merely "abandoned unreviewed" — that name says the watcher gave
    up, and this says nothing could have succeeded. Refs that later earned a real verdict
    are excluded: a diff that was too large before the §2177 splitter is not too large now.
    """
    out: set[str] = set()
    files = [advice_dir / "advice.jsonl", *sorted((advice_dir / "archive").glob("*.jsonl"))]
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if (entry.get("kind") == "commit" and isinstance(entry.get("ref"), str)
                    and _terminally_unreviewable(entry) is not None):
                out.add(entry["ref"])

    return out - reviewed_refs(advice_dir)


def unreviewed_commits(repo: str, advice_dir: Path, scan: int,
                       *, retry_abandoned: bool = False,
                       ignore_armed_at: bool = False) -> tuple[list[str], bool]:
    """(oldest-first commits on HEAD with no ledger entry, window-may-be-too-small).

    ⚠ `scan` is a HARD CAP and it is a safety device, not a tuning knob. Against an
    EMPTY ledger every commit in history is "unreviewed", so an uncapped scan would
    queue thousands of reviews at ~151s each.

    §3067 — TWO MORE FILTERS, both fail-OPEN. (1) The arming boundary: with an `armed-at`
    marker in RESOLVED.md that is an ancestor of HEAD, the window is `<armed>..HEAD`; a
    marker that is NOT an ancestor (rewritten history) is reported on stderr and the plain
    window applies — never `[]`, which is what `_git`'s "" on a failed `rev-list` would
    silently produce. `ignore_armed_at` is the operator's way to reach pre-boundary refs.
    (2) The upstream exclusion: `^<upstream_ref>` when one resolves (see `upstream_ref`).
    `-{scan}` stays on every form, so `truncated` keeps its meaning.

    ⚠ THE SECOND RETURN IS DELIBERATELY NOT "how many commits fell outside the window".
    That was the first version and it is useless: this repo has 5,621 commits, so a
    100-commit window "drops" 5,521 of them on every tick and the warning fires forever
    while meaning nothing — a scary number that carries no signal, which is the class of
    defect the last three batches were spent removing. The honest signal is narrower:
    the window is only too SMALL when its OLDEST commit is itself unreviewed, because
    that is the one case where older unreviewed commits may exist just beyond it.
    """
    if scan <= 0:
        return [], False
    args = ["rev-list", "--reverse", f"-{scan}"]
    boundary = None if ignore_armed_at else armed_at(advice_dir)
    if boundary and _git(repo, "merge-base", boundary, "HEAD").strip() == boundary:
        args.append(f"{boundary}..HEAD")
    else:
        if boundary:
            print(f"[watch] WARN: armed-at {boundary[:12]} is not an ancestor of HEAD (rewritten "
                  f"history?) — selecting from the {scan}-commit window instead; re-run "
                  f"`eugo-skills arm-review --set-armed-at` to move the boundary",
                  file=sys.stderr, flush=True)
        args.append("HEAD")
    up = upstream_ref(repo)
    if up:
        args.append(f"^{up}")
    shas = _git(repo, *args).split()
    done = reviewed_refs(advice_dir)
    # §2112 — a commit that has already burned its retries is NOT selected again. Without
    # this, a deterministically-failing commit is re-reviewed on every dispatch (~151s of
    # quota each) and blocks every newer commit behind it, because this list is oldest-first.
    spent = {} if retry_abandoned else failed_attempts(advice_dir)
    pending = [s for s in shas
               if s not in done and spent.get(s, 0) < _MAX_REVIEW_RETRIES]
    truncated = bool(shas) and len(shas) == scan and shas[0] not in done
    return pending, truncated


#: §833 — the exact shape `_review` writes: `<kind>-<ref>-<epoch>`. The
#: pruner deletes ONLY names matching this, so a hand-dropped note or a
#: differently-named directory under `raw/` is never touched by retention.
_RAW_TICK_DIR = re.compile(r"^(?:commit|worktree)-.+-\d+$")

#: §2202 — a `git log --format=%H` commit boundary.
_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")


#: §2177 — MAX BYTES OF DIFF BODY PER REVIEW PART.
#:
#: MEASURED, not chosen. Joining every ref the ledger carries a real verdict for against
#: `git show <ref> | wc -c` on 2026-09-14: the largest diff `opus` has ever reviewed to a
#: verdict is 1,896,944 bytes (48358df3b2e5, APPROVED that same day), behind it 1,716,424
#: / 1,421,871 / 1,365,962, all opus. The two the reviewer refuses are 4,955,315 and
#: 4,951,068 (§2627 / §2628), each answering `verdict: ERROR, note: "Prompt is too long"`
#: on every one of four attempts. 1.5 MB sits ~20% under the largest measured success and
#: splits those two into 5 parts — MEASURED, not divided: `split_diff` packs whole
#: line-runs greedily, so the last run of a split hunk starts a part of its own and
#: 4.95 MB / 1.5 MB = 3.3 does not round to the answer. The live ledger records
#: `"split": {"parts": 5, "bytes": 4955315, "cap": 1500000}` for both refs and
#: `test_the_two_commits_no_reviewer_can_read_split_under_the_cap` pins 5.
#:
#: ⚠ §2187 — this block said 4 until now. §2177's commit message recorded the correction
#: and its test pinned it, but the CONSTANT's own doc — the artifact a reader consults
#: when tuning the cap — kept the pre-measurement estimate, inside a block headed
#: "MEASURED, not chosen", where every other figure is real. It ships to consumer repos.
#:
#: ⚠ A part is a REVIEW, so parts cost wall-clock (~150s p50 each) AND they land in
#: `_review_durations`, which discards anything >= 3600s. A ref split into enough parts to
#: cross an hour would vanish from the duration median that `review took` and `cost` are
#: built on — the figure §2172 just made honest. That is the reason a part budget exists
#: at all, not merely the spend.
_DIFF_PART_BYTES = 1_500_000

#: Every part of a split diff opens with exactly ONE line of this shape. It is not part of
#: the diff: `part_body()` strips it, and the concatenated bodies reproduce the input
#: byte for byte (except where a single line had to be elided — see `split_diff`).
_PART_BANNER = "<<< review part {i}/{n} — a CONTIGUOUS SLICE of one diff, not an applicable patch{ctx} >>>"
_PART_BANNER_BYTES = 400
#: What an over-long single line is replaced by. The count is the bytes REMOVED, so the
#: reviewer can see how much of the line it is not being shown.
_ELIDED = "… [{n} bytes elided: a single line longer than the part cap]\n"

_DIFF_FILE_HEAD = re.compile(r"^diff --git .*$", re.M)
_DIFF_HUNK_HEAD = re.compile(r"^@@ ", re.M)


def _nbytes(text: str) -> int:
    return len(text.encode("utf-8", "surrogateescape"))


def _split_at(text: str, pattern: re.Pattern[str]) -> tuple[str, list[str]]:
    """(everything before the first match, one chunk per match)."""
    starts = [m.start() for m in pattern.finditer(text)]
    if not starts:
        return text, []
    bounds = [*starts, len(text)]

    return text[: starts[0]], [text[a:b] for a, b in zip(bounds, bounds[1:])]


def _by_line(blob: str, cap: int) -> list[str]:
    """`blob` as runs of whole lines, each at most `cap` bytes.

    The floor of the whole scheme: a SINGLE line longer than `cap` cannot be split further
    without corrupting it, so it is elided down to `cap` with a marker naming the bytes
    removed. That is the only place content is lost, it is visible in the text the reviewer
    reads, and on the diffs this was built for it never fires — the longest line in
    §2628's 4.95 MB is 29,734 bytes.
    """
    out: list[str] = []
    cur: list[str] = []
    held = 0
    for line in blob.splitlines(keepends=True):
        size = _nbytes(line)
        if size > cap:
            if cur:
                out.append("".join(cur))
                cur, held = [], 0
            keep = line.encode("utf-8", "surrogateescape")[:cap]
            out.append(keep.decode("utf-8", "replace")
                       + _ELIDED.format(n=size - len(keep)))
            continue
        if cur and held + size > cap:
            out.append("".join(cur))
            cur, held = [], 0
        cur.append(line)
        held += size
    if cur:
        out.append("".join(cur))

    return out


def _pieces(text: str, cap: int) -> list[tuple[str, str]]:
    """`(context label, chunk)` pairs, each chunk at most `cap` bytes.

    Three levels, because two are not enough: by FILE (`diff --git`), then by HUNK (`@@`)
    for a file that is still too big, then by LINE for a hunk that is. Measured on
    §2628 — the diff this exists for — 2 hunks, the larger 3,659,299 bytes, so a
    file/hunk split alone leaves a piece 2.4x over the cap.
    """
    preamble, sections = _split_at(text, _DIFF_FILE_HEAD)
    out: list[tuple[str, str]] = []
    # `git show` opens with the commit header; it is context for every part that follows,
    # and it is small, so it rides along as an ordinary piece rather than being repeated.
    out.extend(("", chunk) for chunk in _by_line(preamble, cap) if chunk)
    for section in sections:
        # `diff --git a/<path> b/<path>` — the b-side is the file as it is after the
        # commit, and one path reads better in a banner than the pair.
        head_line = section.split("\n", 1)[0]
        label = head_line.partition(" b/")[2].strip() or head_line[len("diff --git "):].strip()
        if _nbytes(section) <= cap:
            out.append((label, section))
            continue
        head, hunks = _split_at(section, _DIFF_HUNK_HEAD)
        for chunk in ([head, *hunks] if hunks else [section]):
            if not chunk:
                continue
            if _nbytes(chunk) <= cap:
                out.append((label, chunk))
            else:
                out.extend((label, piece) for piece in _by_line(chunk, cap))

    return out


def split_diff(text: str, cap: int = _DIFF_PART_BYTES) -> list[str]:
    """One diff as a list of parts, each at most ~`cap` bytes of body.

    A diff that already fits is returned UNCHANGED, as a single element with no banner —
    the overwhelmingly common case, and the one where any decoration would be a change in
    what every review sees. Only an oversized diff is banded.

    INVARIANT, and the property the tests pin: `"".join(part_body(p) for p in parts)` is
    the input, byte for byte, unless a single line exceeded `cap` — the one case where
    content is dropped, and it says so in the text where it happened.
    """
    if cap <= 0:
        raise ValueError(f"cap must be positive, got {cap}")
    if _nbytes(text) <= cap:
        return [text]

    budget = max(1, cap - _PART_BANNER_BYTES)
    packed: list[list[tuple[str, str]]] = []
    held = 0
    for label, chunk in _pieces(text, budget):
        size = _nbytes(chunk)
        if packed and held + size > budget:
            packed.append([])
            held = 0
        if not packed:
            packed.append([])
        packed[-1].append((label, chunk))
        held += size

    parts = []
    for i, group in enumerate(packed, start=1):
        seen = [lbl for lbl in dict.fromkeys(lbl for lbl, _ in group) if lbl]
        shown = seen[:3] + (["…"] if len(seen) > 3 else [])
        ctx = f" · {', '.join(shown)}" if shown else ""
        banner = _PART_BANNER.format(i=i, n=len(packed), ctx=ctx)
        parts.append(banner + "\n" + "".join(chunk for _, chunk in group))

    return parts


def part_body(part: str) -> str:
    """The diff text of a part, with the banner `split_diff` added removed."""
    if part.startswith("<<< review part "):
        return part.split("\n", 1)[1] if "\n" in part else ""

    return part


def _dir_size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file() and not f.is_symlink())


def prune_raw(
    raw_root: Path,
    *,
    max_age_days: float = 0.0,
    max_total_bytes: int = 0,
    now: float | None = None,
) -> tuple[int, int]:
    """Bound the watch daemon's `raw/` tree in TIME, then in SPACE.

    `_review` writes one directory per reviewed increment and nothing ever
    removed them, so a daemon left running accumulated the full diff plus every
    model's output for every commit and worktree change, forever. That is the
    row's defect: the tree has no retention at all.

    TWO BOUNDS, applied in that order, because they answer different questions.
    Age is the principled one — advice about a commit from three weeks ago is
    not consulted. The size cap is the backstop for a burst that is young but
    huge (a rebase replaying 200 commits inside the age window).

    Deletes OLDEST-FIRST and NEVER the newest directory, so a cap smaller than a
    single tick's output degrades to "keep one" instead of erasing everything
    the daemon just wrote. Both bounds are opt-out with 0.

    SAFETY. Only direct children of `raw_root` whose names match the shape
    `_review` itself writes are candidates; symlinks are skipped, never
    followed. Returns `(dirs_removed, bytes_freed)` so the caller can say what
    it did rather than deleting silently.
    """
    if not raw_root.is_dir() or raw_root.name != "raw":
        return (0, 0)
    now = time.time() if now is None else now

    entries = []
    for child in raw_root.iterdir():
        if child.is_symlink() or not child.is_dir():
            continue
        if not _RAW_TICK_DIR.match(child.name):
            continue
        entries.append((child.stat().st_mtime, child, _dir_size(child)))
    entries.sort()  # oldest first

    removed = freed = 0

    def drop(item) -> None:
        nonlocal removed, freed
        _, path, size = item
        shutil.rmtree(path)
        removed += 1
        freed += size

    if max_age_days > 0:
        cutoff = now - max_age_days * 86400
        # `entries[:-1]` — the newest is exempt from BOTH bounds.
        for item in list(entries[:-1]):
            if item[0] < cutoff:
                drop(item)
                entries.remove(item)

    if max_total_bytes > 0:
        total = sum(e[2] for e in entries)
        while total > max_total_bytes and len(entries) > 1:
            item = entries.pop(0)
            total -= item[2]
            drop(item)

    return (removed, freed)


#: §2124 — ONE LOCK PER REVIEW KIND, because one lock made the frequent kind starve the
#: rare one by construction.
#:
#: §1650 added a single-instance lock for the right problem: two DAEMONS both ticking and
#: both spending. Under the §2109/§2116 one-shot hooks the same lock has a different
#: effect. A commit dispatch holds it for its whole serial drain (~151s per pending
#: commit), and `Stop` fires AFTER a turn's last Bash call — so the worktree probe always
#: arrives second. MEASURED: the ledger holds **zero** `kind:"worktree"` entries and
#: `review-turn-end.log` does not exist, so the dispatch has never once been ATTEMPTED.
#:
#: The split is asymmetric on purpose: only the starving kind moves. A run that reviews
#: commits — the legacy daemon, every commit one-shot — keeps `.watch.lock` and today's
#: exact semantics, so `watch_drain.daemon_state`, `check_daemon`, the owed hook's
#: "daemon up" and every existing pin are untouched by construction.
#:
#: ⚠ AND THE SINGLE LOCK WAS ACCIDENTALLY PREVENTING RECURSION. A review subprocess loads
#: the reviewed repo's hooks, so its own `Stop` would dispatch another review; the shared
#: lock refused it. Splitting the lock removes that accident, which is why this landed
#: only AFTER §2121 made the hooks exit inside a review subprocess. The order was a
#: prerequisite, not a preference.
WATCH_LOCK = ".watch.lock"
WORKTREE_LOCK = ".watch.worktree.lock"
#: §2131 — one sentinel per lane, named beside the locks they pair with. `STOP` keeps its
#: meaning (the commit lane, the documented `touch STOP`); the worktree lane gets its own
#: so a turn-end one-shot cannot consume a stop aimed at the daemon.
STOP_SENTINEL = "STOP"
WORKTREE_STOP = "STOP.worktree"


def _flock_held(fd: int, wait_s: float) -> str:
    """Take the exclusive lock on `fd`. Returns "held", "busy" or "stopped".

    ⚠ §2155 — KERNEL-QUEUED, NEVER POLLED, and the distinction is the entire fix. Retrying
    `LOCK_NB` on a timer leaves a blind window at every release, and on this checkout a hook
    dispatch arrives within it: the review hook fires on every Bash call across three
    sessions, so a poller loses the same race it loses today, only faster. A blocking
    `flock(LOCK_EX)` puts this process in the KERNEL's wait queue, so it is woken when the
    holder releases rather than having to be looking at the right moment.

    ⚠ §2171 — AND A PARKED RUN HAD TO BE STOPPABLE, WHICH §2155 MADE IT NOT BE. `_sig` is a
    FLAG-ONLY handler: it sets `_STOP` and returns. Under PEP 475 CPython retries a syscall
    interrupted by a handler that returns normally, so the blocking flock below was RESTARTED
    and both documented stop signals were swallowed for the whole wait. Measured: SIGTERM at
    t=2s and SIGINT at t=3s against `wait_s=8` returned at 8.00s with `_STOP=True` — the
    handler ran, the flag was set, and nothing stopped. At `--wait-for-lock 3600` that is an
    hour in which Ctrl-C, `kill <pid>` and the STOP sentinel all do nothing. So for the
    duration of this wait ONLY, SIGTERM and SIGINT are handled by a handler that RAISES,
    which PEP 475 does not retry; the previous handlers go back in `finally`.

    ⚠ AND THE CALLER'S TIMER IS RESTORED RATHER THAN ZEROED. §2155 wrote a literal 0, which
    silently cancels any alarm the caller had pending, while its own docstring promised it
    "leaves no trace". `setitimer` returns the displaced (value, interval); it is put back.
    The restored value is re-armed from the moment of restore, so a caller's deadline is
    extended by however long this waited — an approximation, stated rather than hidden.

    ⚠ SIGNAL HANDLERS FIRE ONLY ON THE MAIN THREAD. `main()` is the main thread here (this
    module imports no threading and creates no Thread), so the timeout arrives. Called from
    a worker thread the `setitimer` would still fire but the handler would run on the main
    thread, the flock would NOT be interrupted, and `wait_s` would silently become
    "forever" — which is why this says so rather than leaving it to be discovered.
    """
    # ⚠ §2171 — `not (wait_s > 0)`, NOT `wait_s <= 0`: NaN compares False to BOTH, so
    # `--wait-for-lock nan` slipped past the old guard into the waiting branch, where
    # `setitimer` rejects it. This form sends every non-positive value, NaN included, down
    # the non-blocking path that has always been the default.
    if not (wait_s > 0):
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return "busy"
        return "held"

    class _Stopped(Exception):
        """An operator asked this to stop. A DISTINCT type, because the timer expiring and
        someone pressing Ctrl-C are different outcomes and the caller reports them apart."""

    def _expired(_signum, _frame):
        raise TimeoutError          # SIGALRM: waited long enough

    def _stop_now(_signum, _frame):
        raise _Stopped              # SIGTERM / SIGINT: asked to stop

    stopped = False
    prev_timer: tuple[float, float] = (0.0, 0.0)
    installed: list[tuple[int, object]] = []
    try:
        for sig_no, handler in ((signal.SIGALRM, _expired),
                                (signal.SIGTERM, _stop_now),
                                (signal.SIGINT, _stop_now)):
            installed.append((sig_no, signal.signal(sig_no, handler)))
        prev_timer = signal.setitimer(signal.ITIMER_REAL, wait_s)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except _Stopped:
            stopped = True
            return "stopped"
        except (OSError, TimeoutError):
            return "busy"
        else:
            return "held"
    finally:
        signal.setitimer(signal.ITIMER_REAL, prev_timer[0], prev_timer[1])
        for sig_no, prev in reversed(installed):
            signal.signal(sig_no, prev)
        if stopped:
            global _STOP
            _STOP = True


def _acquire_single_instance(advice_dir: Path, lock_name: str = WATCH_LOCK, *,
                             wait_s: float = 0.0) -> int | None:
    """§1650 (§1.57-F6) — one daemon per advice directory.

    Two watchers on a shared checkout both tick, both spend, and both append to
    `advice.jsonl` — interleaved, so neither transcript reads straight. Nothing
    stopped that: there was no guard of any kind.

    Returns the held fd (kept open for the process lifetime — closing it releases
    the lock) or None when another instance holds it, having explained itself.
    `flock` is advisory and per open-file-description, so a second `open()` in the
    SAME process also conflicts, which is what makes this testable without
    spawning one.

    Deliberately non-blocking BY DEFAULT: a queued second daemon would start hours later
    at an unpredictable moment, which is worse than refusing now. That reasoning is about
    a DAEMON, and §2155 found the case it does not cover — see `wait_s`.

    `wait_s > 0` waits for the lock instead of refusing. It exists for an
    operator-launched one-shot BACKLOG pass, which is the opposite situation: it is not a
    second daemon racing to start, it is a single job that has been asked to run and whose
    whole purpose is to run once, to completion, whenever the lane is free. Measured over
    ~20 hours on 2026-09-14: hook-dispatched commit reviews took this lock 55 times and a
    `--ledger-scan 1000 --retry-abandoned` pass took it 8, refused 15 — the hook fires on
    every Bash call across three sessions, so a caller that refuses and re-races loses
    roughly seven times in eight, indefinitely. 67 commits and 15 abandoned stayed unreviewed
    for two days because of it.
    """
    lock_path = _transient(advice_dir, lock_name)
    try:
        # ⚠ §2110 — 0664, NOT 0644, and the mode is the whole point. This file must be
        # acquirable by EVERY user who reviews in a shared checkout: athena has three
        # concurrent Claude Code sessions running as three different UNIX users, all in
        # group `eugo`. At 0644 whoever creates the lock first silently excludes the
        # others FOREVER — measured on 2026-09-09, a `slava`-owned lock gave `slava3`
        # `[Errno 13] Permission denied` on every attempt, 301 times in a few minutes,
        # so dispatch depended on which session happened to commit first.
        # `_advice_lock` below never had this bug because it opens O_RDONLY; this one
        # cannot, since it records the holder's pid.
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o664)
    except OSError as error:  # noqa: BLE001 — an unlockable dir is reported, not fatal-by-traceback
        print(f"ERROR: cannot open {lock_path}: {error}. If this is a PERMISSION error, "
              f"the lock was created by another user at a stricter mode — remove the "
              f"stale {lock_path} and it will be recreated group-writable.",
              file=sys.stderr)
        return None
    # ⚠ §2131 — THE MODE ARGUMENT ABOVE IS MASKED BY UMASK, so §2110's guarantee held only
    # where the umask happened to be permissive. On athena it is 0002 and the live locks
    # ARE 0664, which is exactly why this went unnoticed: the invariant was environmental,
    # not enforced. Under the common 0022 the file lands 0644 and §2110's defect returns in
    # full — whoever creates the lock first silently excludes every other user forever.
    # `fchmod` is NOT umask-masked. It fails with EPERM when another user owns the file,
    # which is fine: that file already exists and its mode is not ours to set.
    with contextlib.suppress(OSError):
        os.fchmod(fd, 0o664)
    outcome = _flock_held(fd, wait_s)
    if outcome != "held":
        try:
            holder = os.read(fd, 64).decode("utf-8", "replace").strip() or "?"
        except OSError:
            holder = "?"
        os.close(fd)
        if outcome == "stopped":
            # §2171 — an operator asked this to stop while it was queued. Saying "another
            # codex_watch already holds the lock" would be true and beside the point: they
            # know, that is why they were waiting, and reporting contention for a
            # deliberate stop is how a log stops being read.
            print(f"[watch] stopped while waiting for {lock_path} (held by pid {holder}).",
                  file=sys.stderr)
        else:
            waited = f" after waiting {wait_s:g}s" if wait_s > 0 else ""
            print(
                f"ERROR: another codex_watch already holds {lock_path} (pid {holder})"
                f"{waited}. Stop it first, or point --advice-dir somewhere else.",
                file=sys.stderr,
            )
        return None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    return fd


#: §A2 — the PER-APPEND lock. `.watch.lock` above is held for the daemon's lifetime and
#: means "one daemon per advice dir", so a drain cannot share it; `watch_drain.py rotate`
#: takes THIS one around its rewrite of advice.jsonl + advice.md, and the daemon takes it
#: around both appends below, so an append never interleaves with a rotation. The name is
#: pinned equal to `watch_drain.ADVICE_LOCK` by `tools/tests/test_watch_drain.py`.
_ADVICE_LOCK = ".advice.lock"

#: §2175 — EVERY transient file this module can create inside an advice dir, in ONE place.
#:
#: The gitignore rules `eugo-skills init-gitignore` writes FLEET-WIDE are checked against
#: this tuple (`tools/tests/test_skills_initgitignore.py`). §2131 split the STOP sentinel
#: into a commit lane and a worktree lane and did not add the matching ignore rule, so the
#: documented stop gesture left an untracked file in a checkout three sessions share; the
#: §2163 gate written to catch that re-listed the five names BY HAND, which can notice a
#: rename and never an addition — it would have missed §2131, the split it cites.
#:
#: Derivation is what makes an ADDITION visible, and `_transient` below is what makes the
#: derivation true rather than decorative: a name that never reaches this tuple cannot
#: reach the filesystem either.
TRANSIENT_FILES = (WATCH_LOCK, WORKTREE_LOCK, STOP_SENTINEL, WORKTREE_STOP, _ADVICE_LOCK)


def _transient(advice_dir: Path, name: str) -> Path:
    """`<advice_dir>/<name>` for a REGISTERED transient file, else ValueError.

    ⚠ THIS RAISES ON A PROGRAMMING ERROR, DELIBERATELY. Both call sites pass a module
    constant, so an unregistered name means a new lane was added without registering its
    file — which is precisely the §2131 defect, and the only moment it can still be caught
    is before the file exists. It is not an environmental condition to be tolerated.

    It is also the half a static scan cannot do. An AST walk over this module sees
    `advice_dir / STOP_SENTINEL`, but not `advice_dir / lock_name` in
    `_acquire_single_instance`, where the constant arrives as a DEFAULT ARGUMENT or from
    the caller — so the registry is enforced here, at the creation site, instead.
    """
    if name not in TRANSIENT_FILES:
        raise ValueError(
            f"{name!r} is not in TRANSIENT_FILES {TRANSIENT_FILES} — register it there, "
            f"or `eugo-skills init-gitignore` will not ignore it in any consumer repo"
        )
    return advice_dir / name


@contextlib.contextmanager
def _advice_lock(advice_dir: Path):
    """Blocking `flock(LOCK_EX)` on `<advice_dir>/.advice.lock`, released on exit.

    O_RDONLY|O_CREAT: flock ignores the open mode, and the file may already exist owned
    by whoever ran the drain — an O_RDWR open of another user's 0644 file would fail and
    the tick handler would swallow the append."""
    fd = os.open(_transient(advice_dir, _ADVICE_LOCK), os.O_RDONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


#: The focus line every review carries, and the variant a SLICE of one carries. A part is
#: not a diff: without this the reviewer reads a truncated hunk and files "this function is
#: never closed" against a cut that the splitter made, not the author.
_REVIEW_EXTRA = ("Continuous companion review of an in-progress increment — "
                 "flag only REAL bugs.")
_REVIEW_EXTRA_PART = (
    "Continuous companion review of an in-progress increment — flag only REAL bugs. "
    "⚠ This is PART {i} OF {n} of one commit's diff, split because the whole exceeds the "
    "model's context. It is a contiguous slice, not an applicable patch: a symbol defined "
    "in another part is NOT undefined, and a hunk that appears to start or end mid-file "
    "was cut by the splitter. Review only what this slice shows."
)


def _results_of(stdout: str, out_dir: Path, *, part: str = "") -> list[dict]:
    """The driver's `model=<m> verdict=<v> [note=<free text to EOL>]` lines as results.

    §A2-drain — CAPTURE `note=`. The driver puts the REASON an ERROR happened there ("no
    output", "timeout after Ns", "claude exited 2", "<bin> not found on PATH", and since
    §2066 "no verdict line"), and the original parser built `parts` from the line and then
    read only model+verdict, so every ERROR reached advice.jsonl as `critical: ""` with no
    cause. The first drain of this log measured the cost: 99 of 815 ticks (12%) were ERROR
    and NOT ONE recorded why.

    The note is split off FIRST: it is free text with spaces, so the `split(" ")` below
    would keep only its first word (`note=no output` -> "no").

    §2178 — extracted from `_review` so the per-part loop has one parser rather than a
    copy, and given `part` so a result says which slice produced it.
    """
    results: list[dict] = []
    for line in stdout.splitlines():
        if not line.startswith("model="):
            continue
        head, sep, note = line.partition(" note=")
        fields = dict(p.split("=", 1) for p in head.split(" ") if "=" in p)
        model, verdict = fields.get("model", "?"), fields.get("verdict", "?")
        md = out_dir / f"{model}.md"
        crit = _critical_section(md.read_text()) if md.exists() else ""
        result = {"model": model, "verdict": verdict,
                  "critical": crit if crit and crit.lower() != "none." else ""}
        if part:
            result["part"] = part
        if sep and note.strip():
            result["note"] = note.strip()
        results.append(result)

    return results


def _review(repo: str, kind: str, ref: str, diff_text: str, cfg: argparse.Namespace,
            advice_dir: Path) -> dict | None:
    """Review one increment via the driver; append advice; return the entry (or None if empty diff)."""
    if not diff_text.strip():
        return None
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    # §1650 (§1.57-F6) — THE PID IS PART OF THE NAME. The timestamp is
    # second-resolution, so two daemons on one shared checkout reviewing the same
    # ref in the same second wrote to the SAME directory and overwrote each
    # other's `<model>.md` files. The flock below makes that pair impossible on
    # one host; the PID keeps the names distinct anyway, because a lock is not a
    # naming scheme and NFS/containers can share an advice dir without sharing a
    # lock table.
    #
    # ⚠ STILL MATCHES `_RAW_TICK_DIR` (`^(?:commit|worktree)-.+-\d+$`): `.+`
    # absorbs the timestamp and `-\d+$` takes the pid. That pruner deletes only
    # names it recognises, so a shape change here would silently STOP retention —
    # pinned by a test rather than left to the reader.
    raw = advice_dir / "raw" / (
        f"{kind}-{ref.replace('/', '_')[:24]}-{int(time.time())}-{os.getpid()}"
    )
    raw.mkdir(parents=True, exist_ok=True)
    # ⚠ §2178 — ONE DISPATCH PER PART. `split_diff` returns the diff UNCHANGED as a
    # single element whenever it fits the cap, so the common path — every commit in this
    # repo's history bar two — is byte-identical to what it was before §2177: one
    # `diff.md` directly in the tick directory, one driver run, `--output-dir` the tick
    # directory itself. Only an oversized diff gains `partNofM/` subdirectories, which the
    # driver needs because it writes `<model>.md` into `--output-dir` and P runs sharing
    # one directory would overwrite each other's review.
    #
    # The subdirectories do not disturb retention: `_RAW_TICK_DIR` matches the PARENT's
    # name, which is unchanged, and `_dir_size` / `_review_durations` both walk with
    # `rglob`, so a part's bytes and mtimes are counted with the tick they belong to.
    parts = split_diff(diff_text, _DIFF_PART_BYTES)
    argv_base = [sys.executable, str(cfg.driver), "--type", "code", "--repo", repo,
                 "--models", cfg.models, "--effort", cfg.effort]
    # §737 — forward the operator's triage invariants. Without this the watch arm
    # had NO override path: `--type code` makes codex_review.py fall through to its
    # built-in _EUGO_INVARIANTS, so every tick in a consumer repo triaged that
    # repo's findings against ATHENA's contracts — its count contract, its
    # commit-trailer rule, paths under skills/eugo/ — and told codex that findings
    # contradicting them were false positives. `invariants` is declared
    # required:true in the base's parameters.json, and on this surface it reached
    # no finding at all. getattr keeps a hand-built cfg Namespace working.
    if getattr(cfg, "invariants_file", ""):
        argv_base += ["--invariants-file", cfg.invariants_file]
    # §1244 — forward the ENGINE. The daemon used to be codex-only, which made it
    # unusable on a box where `codex login status` says `Not logged in`: every tick
    # returned ERROR and the exception handler below swallowed it, so hours of silence
    # looked exactly like hours of quiet. getattr keeps a hand-built cfg Namespace
    # working (the tests supply one).
    if getattr(cfg, "engine", ""):
        argv_base += ["--engine", cfg.engine]
    # Forward the codex BINARY. A driver flag the daemon does not forward is a
    # flag that silently does nothing under the watcher, which is the failure
    # mode --invariants-file and --engine above were both added to fix. Same
    # getattr guard, for the hand-built cfg Namespaces the tests supply.
    if getattr(cfg, "codex_bin", ""):
        argv_base += ["--codex-bin", cfg.codex_bin]

    results: list[dict] = []
    driver_exit = 0
    tails: list[str] = []
    dispatched = len(parts)
    for index, part_text in enumerate(parts, start=1):
        out_dir = raw if len(parts) == 1 else raw / f"part{index}of{len(parts)}"
        out_dir.mkdir(parents=True, exist_ok=True)
        inp = out_dir / "diff.md"
        inp.write_text(part_text)
        extra = _REVIEW_EXTRA if len(parts) == 1 else _REVIEW_EXTRA_PART.format(
            i=index, n=len(parts))
        proc = subprocess.run([*argv_base, "--input", str(inp),
                               "--output-dir", str(out_dir), "--extra", extra],
                              capture_output=True, text=True)
        part_exit = int(getattr(proc, "returncode", 0) or 0)
        driver_exit = driver_exit or part_exit
        if part_exit:
            tail = " | ".join((proc.stderr or "").strip().splitlines()[-3:])
            tails.append(f"part {index}/{len(parts)}: {tail}" if len(parts) > 1 else tail)
        part_results = _results_of(proc.stdout, out_dir,
                                   part=f"{index}/{len(parts)}" if len(parts) > 1 else "")
        results.extend(part_results)
        # ⚠ §2187 — AN OUTAGE IS CHARGED TO NOBODY, AND THIS LOOP WAS CHARGING IT PER PART.
        # `_account_is_down` exists (§2089/§2114) so a session/weekly limit does not spend a
        # commit's retries; nothing consulted it BETWEEN parts, and the reaction lives in
        # `main()`, which only sees the finished entry. Measured on the live ledger, entry
        # 2026-09-14T16:25:00Z for 54a206fc2015: five results, every one
        # `ERROR · "You've hit your session limit · resets 6:20pm (UTC)"`, with the part
        # directories stamped :00 :02 :04 :07 :09 — four dispatches made after part 1 had
        # already reported the account unusable. In the commit whose subject is "stop paying
        # three times for no", multiplied by the part count inside one attempt.
        #
        # Stopping leaves the later parts with NO result, so `_is_real_review` still counts
        # the ref unreviewed (it requires a verdict for every part) and `failed_attempts`
        # still charges the outage to nobody. Nothing about the disposition changes; only
        # the spend does.
        if len(parts) > 1 and _account_is_down({"results": part_results}) is not None:
            print(f"[watch] account down mid-split; dispatched {index}/{len(parts)} part(s) "
                  f"for {kind} {ref[:12]} and stopped", file=sys.stderr, flush=True)
            dispatched = index
            break
    entry = {"ts": ts, "kind": kind, "ref": ref, "results": results}
    if len(parts) > 1:
        # §2178 — WHAT THE READER NEEDS TO KNOW THAT THE VERDICTS DO NOT SAY. Recorded as
        # a structured block rather than a new verdict string: `watch_drain`'s status line
        # reports `other_verdicts`, so an invented value lands there and every downstream
        # count drifts. `_is_real_review` reads `parts` from here to require a verdict for
        # EVERY part before the ref counts as reviewed.
        entry["split"] = {"parts": len(parts), "bytes": len(diff_text.encode("utf-8", "surrogateescape")),
                          "cap": _DIFF_PART_BYTES}
        # §2187 — how many were actually SENT, which is not `parts` once an outage stops
        # the loop. Recorded so the entry cannot be read as five failed reviews when it
        # was one failure and four dispatches that never happened.
        if dispatched != len(parts):
            entry["split"]["dispatched"] = dispatched
    if kind == "commit":
        # §2143 — see `_superseded`. Recorded on the ENTRY so every reader of the ledger
        # sees it, not only whoever happened to be watching the log.
        moved = _superseded(repo, ref)
        if moved:
            entry["superseded"] = moved
    if driver_exit:
        entry["driver_exit"] = driver_exit
        # stderr's TAIL: a traceback's last lines carry the cause, and the whole
        # buffer would bury the tick line this is meant to annotate. With a split diff
        # every failing part contributes its own, labelled, because "which part" is the
        # first question a reader asks.
        tail = " ;; ".join(tails)
        entry["driver_stderr_tail"] = tail
        print(
            f"[watch] ⚠ driver exited {driver_exit} for {kind} {ref[:12]} "
            f"(models={cfg.models}, bin={getattr(cfg, 'codex_bin', '') or 'default'})"
            f"{': ' + tail if tail else ''}",
            file=sys.stderr, flush=True,
        )
    blocking = [r for r in results if r["verdict"] == "NEEDS_REVISION" and r["critical"]]
    _append_entry(advice_dir, entry)
    verdicts = ",".join(
        f"{r['model']}={r['verdict']}" + (f"({r['note']})" if r.get("note") else "")
        for r in results
    ) or "no-result"
    print(f"[watch] {kind} {ref[:12]} → {verdicts}"
          f"{'  ⚠ blocking' if blocking else ''}", flush=True)
    return entry


#: §2195 — a path "dominates" a supersession count when setting it aside leaves at most
#: `1 - SHARE` of the count behind, and the count is at least FLOOR. The floor keeps the
#: extra `rev-list` calls off small counts, where the figure is readable anyway.
#:
#: ⚠ §2200 — THE NUMBERS THAT JUSTIFIED THE SHARE WERE THE METRIC THIS RULE REJECTS. This
#: note read "the measured cases — 214 of 222, 210 of 218, 209 of 254 — all qualify", and
#: those are the PATH'S OWN counts, which is exactly what §2195 stopped using because two
#: paths moving together each own 100% of a shared union. The rule measures what SURVIVES
#: without the path. Re-derived against 77c9c5c4, the same commit the hand-off used:
#:
#:      ref        union  without  only_here  rule: without <= union*0.5
#:      da95625f     222       13    209 (94%)      13 <= 111   ✓
#:      4ea7905c     218       11    207 (95%)      11 <= 109   ✓
#:      cc7af16f     254       98    156 (61%)      98 <= 127   ✓
#:
#: The third is the one that sets the ceiling: it survives at 0.6 (98 <= 101.6) and fails
#: from about 0.62 up (at 0.65, 98 > 88.9), so the case §2194 had to correct would go
#: unmarked there. Anyone tuning this knob from the old figures would read 82% of slack
#: where there is 61%.
#:
#: ⚠ AND THE LINE ABOVE FIRST READ "at 0.6 it would fail (98 > 102)", WHICH IS FALSE —
#: 98 <= 101.6. A false arithmetic claim inside the comment written to remove a false
#: claim, caught by running it rather than reading it. That is the instruction §2192 put
#: in the review prompt, applied to its own author.
_SUPERSEDED_DOMINANCE_FLOOR = 20
_SUPERSEDED_DOMINANCE_SHARE = 0.5


def _superseded(repo: str, sha: str) -> dict | None:
    """What later history has done to the files this commit touched, or None for HEAD.

    ⚠ §2143 — A BACKLOG REVIEW REPORTS AGAINST A DIFF, AND THE READER ACTS AGAINST HEAD.
    Nothing recorded the gap. Measured the day the operator-ruled catch-up pass ran: it
    reviewed `de378095` (§1567, which added `limit: int = Query(200, ge=1, le=1000)`) and
    filed a confident, well-argued finding about code that does not exist — `aaca88b6`
    (§1568) had reverted §1567 IN FULL, and `admin.py` at HEAD has no `Query` at all. The
    review even quoted HEAD correctly for half its evidence and the diff for the other
    half, which is exactly how it reads as current.

    That exposure is the whole backlog's, not one entry's: every commit a `--ledger-scan`
    pass reaches is old by construction, and the older it is the likelier later history
    has moved it. This is the `stale-on-arrival` class the ledger already records twice
    (§2103, §2774), one layer up — the finding is stale rather than the citation.

    MECHANICAL AND HONEST: it counts commits that later touched the same paths. It does
    NOT claim the finding is cured — nothing here can know that — it says the ground moved
    and by how much, so a reader verifies before acting instead of after.
    """
    head = _git(repo, "rev-parse", "HEAD").strip()
    if not head or head.startswith(sha) or sha.startswith(head[:12]):
        return None
    # ⚠ NOTED (not done), §2207 — `.split()` SPLITS ON ALL WHITESPACE, so a tracked path
    # containing a space becomes several bogus pathspecs and `files` below is a count of
    # TOKENS, not of files. Measured: `954afbb3` reports 111 where the commit touched 71,
    # five of them space-containing (an `inputs/claude_exports/…/1. HPC and LLM profiling
    # benchmarks/…` export splits into six fragments). Those fragments match no pathspec, so
    # `commits_since` would also UNDERCOUNT and `wanted` could never name such a path as
    # dominant.
    #
    # LEFT AS IS DELIBERATELY, on measurement rather than taste. The newest commit touching
    # a space path is 2,827 back; the deepest commit ever reviewed in this ledger is 1,014
    # back; `--ledger-scan` defaults to 100 and the deepest pass ever run was 1,000. The
    # `files` field is written here and read NOWHERE — zero hits across `.claude/scripts`,
    # `.claude/hooks`, `.adversarial-review/*.py` and `skills/eugo`. And the failure
    # direction is benign: a count goes LOW or an annotation goes missing, never fabricated
    # high. Operator ruling 2026-09-15: record, do not fix.
    #
    # THE CURE, if a deeper scan ever makes this reachable: `--format= -z` and split on NUL.
    # It needs its own gate and a fixture carrying a space path, because this function now
    # runs in every turn-end hook (§2201/§2202).
    files = [f for f in _git(repo, "show", "--name-only", "--format=", sha).split() if f]
    if not files:
        return None
    out = _git(repo, "rev-list", "--count", f"{sha}..HEAD", "--", *files).strip()
    try:
        touched = int(out)
    except ValueError:
        return None
    if not touched:
        return None
    # ⚠ §2195 — THE COUNT IS OVER EVERY PATH THE COMMIT TOUCHED, AND ONE OF THEM IS OFTEN A
    # STATUS FILE NOBODY REVIEWS. `.claude/data/overnight/breadcrumb.log` is rewritten by
    # every overnight iteration, so any commit that also touched it carries a figure that is
    # mostly that churn. Measured across the ledger: of 38 entries with `commits_since >= 50`
    # that touched it, **32 are inflated more than 2x by that file alone** — the worst reads
    # 344 where the rest of its paths give 132.
    #
    # It is not a hypothetical misreading: §2168 printed "222, 218 and 254 later commits
    # touched those files" into a hand-off for another session, naming two source files whose
    # real counts were 13/11/11 and 39/39/38, and §2194 had to correct it.
    #
    # NOT a denylist, and not a changed headline. `commits_since` keeps its exact meaning —
    # the union, which is the honest answer to "has the ground moved" — and gains the ONE
    # fact that stops it being read as a statement about the code: which single path
    # dominates it, when one does. A list of "churn files" would rot; asking the data which
    # path carries the count cannot.
    #
    # ⚠ THE TEST IS "HOW MUCH SURVIVES WITHOUT IT", NOT "HOW BIG IS ITS OWN COUNT", and the
    # difference is not academic. The first version asked whether a path's individual count
    # exceeded half the union — but when two paths move together in EVERY commit each one
    # individually accounts for 100% of it, so that rule named one of them arbitrarily while
    # removing it would change nothing. Caught by this commit's own control. Removing the
    # path and re-counting answers the question a reader actually has.
    # ⚠ §2202 — ONE `git log` PASS, NOT ONE `rev-list` PER PATH. The first implementation
    # ran `rev-list --count` once for every path in the commit, which is fine for a small
    # commit and is not what this is used on: measured on the three refs the turn-end hook
    # actually annotates, `18d14677` (10 files, 74 commits) cost 598 ms alone and the three
    # together cost 942 ms — paid at EVERY turn end since §2201 put this on that path.
    #
    # `git log --name-only --format=%H` returns every later commit WITH the paths it
    # touched, so the union and the per-path attribution both fall out of one call.
    # Measured equivalent on five real refs — same `commits_since`, same `dominated_by`,
    # same `only_here` — at 90 ms against 611, 59 against 259, 99 against 474.
    #
    # The rule is unchanged, only rearranged: `without = touched - only_here`, so
    # `without <= touched * (1 - SHARE)` is exactly `only_here >= touched * SHARE`.
    #
    # ⚠ §2211 — BOTH SENTENCES ABOVE HOLD ONLY FOR NON-MERGE COMMITS, AND NEITHER SAYS SO.
    # `git log --name-only` emits NO file lines for a merge (it shows no diff against
    # multiple parents by default), so a merge the pathspec keeps IS counted by the
    # `rev-list --count` above — it is inside `touched` — while its block here is EMPTY and
    # it is credited to no path. `only_here` is then low by one per such merge and `touched`
    # is not, so the stated identity `without = touched - only_here` does not hold.
    # Proved by construction rather than by reading: a 2-file repo with one `--no-ff` merge
    # gives touched=3 and three blocks of which the merge's is empty; the pre-§2202 per-path
    # walk scores only_here[A]=2 and this code scores 1.
    #
    # RECORDED, NOT FIXED, and the reason is reach. ⚠ §2215 — §2211 FIRST ARGUED THIS FROM A
    # HISTORICAL MAXIMUM AND GOT THE NUMBER WRONG: it said "the deepest `--ledger-scan`
    # anything has ever run is 330", conflating the depth §2179's two stuck refs needed
    # (`watch_drain.py:262`, `eugo-watch-owed.sh:74`) with the deepest pass actually run —
    # which §2207's comment 67 lines above states as 1,000, with the deepest commit ever
    # reviewed at 1,014 back. A `--ledger-scan 1000` pass really ran on 2026-09-13
    # (`CATCHUP-FINDINGS-2026-09-13.md:3`).
    #
    # The FIX IS NOT SWAPPING THE DIGIT, because no historical maximum can bound this at all:
    # `eugo-watch-owed.sh:76` reads `retry_scan` from `watch_drain.py:248`, computed at
    # RUNTIME from how deep the stuck refs are, and prints `--ledger-scan <computed N>`. The
    # bound that does not decay is structural: athena has 6 merges in 5,858 commits, the
    # SHALLOWEST 3,472 back, against a default of 100 (`--ledger-scan`, below). Reaching one
    # would take refs stuck ~3,472 commits — a ledger state that would itself be the finding.
    # This code is also the only copy running it: of the
    # 37 `codex_watch.py` copies under /opt/eugo, athena's is the sole one that contains
    # `only_here` at all — every consumer is pre-§2195 and has no such field, so the twin
    # "already ships it" is a claim about the NEXT install, not a live site. It becomes
    # reachable the moment `eugo-skills install` puts the twin in a repo whose merges sit
    # inside the scan depth. Cure then: attribute a merge with `--diff-merges=first-parent`,
    # or drop un-attributable commits from the DENOMINATOR as well as the numerator — one
    # without the other just moves the error.
    #
    # ⚠ `rev-list` does NOT accept `--name-only` — it exits with usage text. The prototype
    # for this used it, read `.stdout` without checking the exit code, and silently counted
    # zero. `_git` returns "" on a non-zero exit for the same reason, so an empty parse here
    # means "no attribution", never "no commits": the union above is what counts commits.
    dominant: tuple[str, int] | None = None
    if touched >= _SUPERSEDED_DOMINANCE_FLOOR and len(files) > 1:
        log_out = _git(repo, "log", "--name-only", "--format=%H", f"{sha}..HEAD", "--", *files)
        wanted = set(files)
        # A commit counts toward a path only if it touched NO OTHER path in this set, which
        # is knowable only once the commit's block ends — hence the flush on each boundary
        # and once more after the loop.
        only_here: dict[str, int] = {}
        current: set[str] | None = None
        for line in log_out.splitlines():
            line = line.rstrip()
            if _FULL_SHA.match(line):
                if current is not None and len(current & wanted) == 1:
                    p = next(iter(current & wanted))
                    only_here[p] = only_here.get(p, 0) + 1
                current = set()
            elif line and current is not None:
                current.add(line)
        if current is not None and len(current & wanted) == 1:
            p = next(iter(current & wanted))
            only_here[p] = only_here.get(p, 0) + 1
        if only_here:
            path, n = max(only_here.items(), key=lambda kv: kv[1])
            if n >= touched * _SUPERSEDED_DOMINANCE_SHARE:
                dominant = (path, n)
    out_entry = {"commits_since": touched, "files": len(files)}
    if dominant is not None:
        # `only_here` — commits that touched this path and NONE of the others, i.e. exactly
        # what the headline loses when the path is set aside. Not the path's own count,
        # which double-counts every commit that moved both.
        out_entry["dominated_by"] = {"path": dominant[0], "only_here": dominant[1]}

    return out_entry


def _append_entry(advice_dir: Path, entry: dict) -> None:
    """THE ONE PLACE AN ENTRY REACHES THE LEDGER — the jsonl line and its md section.

    §A2 — ONE lock hold around BOTH appends: a rotation between them would archive the
    jsonl line and then receive the .md section for an entry it no longer holds.

    §2132 — EXTRACTED FROM `_review` so the empty-`git show` record is written by the
    same code, not by a second copy of this template. `watch_drain.render_md` promises
    byte identity with what this writes, and §1966 already cost a silently-dropped line
    when the two drifted by one `f.write`; a second writer would have been a third copy.

    ⚠ §2130 — `ts` IS A START TIME ON AN APPEND-AT-END FILE, and readers that need
    ARRIVAL order must not use it. `_review` stamps `ts` on its first line and the
    reviewer runs ~151s (p50) before reaching here, and since §2124 the commit and
    worktree lanes hold separate locks and run CONCURRENTLY — so a lane that starts
    earlier and finishes later appends an entry whose `ts` is earlier than entries
    already in the file. The live ledger carried two such pairs on the day this was
    written, and the turn-end hook's max(ts) watermark had permanently skipped a real
    NEEDS_REVISION because of one.

    ADDITIVE, NEVER A REDEFINITION OF `ts`: the worktree debounce and review_watch_report
    both read `ts` as a start time and are right to. Stamped INSIDE the lock, so it is the
    moment the entry becomes visible; microseconds because two lanes finishing in the same
    second would otherwise tie, and a tie at the watermark is the same lost finding one
    resolution down.
    """
    ts, kind, ref = entry["ts"], entry["kind"], entry["ref"]
    results = entry["results"]
    with _advice_lock(advice_dir):
        _now = time.time()
        entry["appended"] = (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(_now))
                             + ".%06dZ" % int((_now % 1) * 1_000_000))
        entry["writer"] = _WRITER          # §3043 — the jsonl line only; the md section is unchanged
        with (advice_dir / "advice.jsonl").open("a") as f:
            f.write(json.dumps(entry) + "\n")
        with (advice_dir / "advice.md").open("a") as f:
            f.write(f"\n## {ts} · {kind} · {ref}\n")
            for r in results:
                f.write(f"- **{r['model']}**: {r['verdict']}\n")
                if r.get("note"):
                    f.write(f"  - note: {r['note']}\n")
                if r["critical"]:
                    f.write(f"\n{r['critical']}\n")


def _record_show_failure(advice_dir: Path, sha: str) -> int:
    """Record an empty `git show` IN THE LEDGER; return this commit's attempt count.

    ⚠ §2132 — THE 3-STRIKE ESCAPE ABOVE WAS UNREACHABLE UNDER THE SHIPPED DISPATCH, and
    it is the same defect §2112 fixed one branch over without sweeping the file. `_review`
    had a process-local `review_failures` dict; §2109's hook spawns a FRESH `--once` per
    dispatch, so the count was always 1, `n < _MAX_REVIEW_RETRIES` was always true, and
    "giving up and advancing PAST it" could never run. `show_failures` was the same dict
    with the same lifetime, left behind. `git show` returning empty therefore held the
    anchor on EVERY dispatch, forever, and every newer commit queued behind it —
    `unreviewed_commits` is oldest-first.

    The ledger is the counter because it is the only thing that survives the process. An
    empty `git show` writes no entry of its own, which is exactly why the move did not
    transfer for free: so write one. It is a valid entry under
    `watch_drain._entry_problem`, `failed_attempts` counts it with no new code, and
    `_MAX_REVIEW_RETRIES` supplies the same three strikes the dict was reaching for.
    """
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": "commit",
        "ref": sha,
        "results": [{"model": "-", "verdict": "ERROR", "critical": "",
                     "note": SHOW_EMPTY_NOTE}],
    }
    _append_entry(advice_dir, entry)
    return failed_attempts(advice_dir).get(sha, 0)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Codex continuous-review companion (the /eugo-adversarial-review `watch` mode).")
    ap.add_argument("--repo", default=REPO_ROOT,
                    help="repo root (codex -C working dir); defaults to this repo (/opt/eugo/athena)")
    ap.add_argument("--commits", action="store_true", default=True)
    ap.add_argument("--no-commits", dest="commits", action="store_false")
    ap.add_argument("--worktree", action="store_true", default=True)
    ap.add_argument("--no-worktree", dest="worktree", action="store_false")
    ap.add_argument("--interval", type=int, default=60, help="poll interval seconds")
    ap.add_argument("--wt-min-interval", type=int, default=180, help="min seconds between worktree reviews")
    ap.add_argument("--wt-min-lines", type=int, default=40,
                    help="§2116 — skip a worktree review whose diff changes fewer than "
                         "this many lines (0 = no floor). A review costs ~151s; spending "
                         "it on a trivial diff delays the one that matters")
    ap.add_argument("--since", default="", help="review commits after this sha (default: HEAD at launch)")
    # §2108 — the alternative to `--since`: take the cursor from the LEDGER rather than
    # from this process's memory. Opt-in, so every existing invocation is unchanged.
    ap.add_argument("--wait-for-lock", type=float, default=0.0, metavar="SECONDS",
                    help="wait up to SECONDS for the single-instance lock instead of "
                         "refusing when another run holds it (default 0 = refuse at once). "
                         "For an operator-launched BACKLOG pass: the hook-dispatched commit "
                         "lane re-attempts constantly, so a pass that refuses and re-races "
                         "is starved indefinitely (§2155)")
    ap.add_argument("--since-ledger", action="store_true",
                    help="select commits with no advice.jsonl entry instead of anchoring "
                         "at --since/HEAD; idempotent, survives a restart, and never "
                         "advances past an unreviewed commit")
    # §2125 — the one-off recovery pass the operator ruled on 2026-09-13, made a flag
    # rather than a throwaway script so it is testable and repeatable. ⚠ OPT-IN ONLY:
    # left on, a commit that deterministically produces no verdict is re-reviewed on every
    # dispatch at ~151s a time, which is the head-of-line burn §2112 fixed.
    ap.add_argument("--retry-abandoned", action="store_true",
                    help="ignore the spent retry budget for this run, so commits already "
                         "given up on are reviewed again. Use after fixing whatever made "
                         "their reviews fail — §2121 was one such cause and cost 31 commits")
    ap.add_argument("--ledger-scan", type=int, default=100,
                    help="with --since-ledger, the most recent N commits to consider "
                         "(hard cap: an empty ledger would otherwise queue all of history)")
    # §3067 — the per-tick budget and the boundary override. Both default from the
    # environment / the ledger dir so the hooks never pass them (see TICK_BUDGET_ENV).
    ap.add_argument("--tick-budget", type=int, default=None,
                    help=f"with --since-ledger, review at most N commits per tick, HEAD first "
                         f"(default: ${TICK_BUDGET_ENV} or {DEFAULT_TICK_BUDGET}; 0 = unbounded)")
    ap.add_argument("--ignore-armed-at", action="store_true",
                    help="select from the whole window even when RESOLVED.md carries an "
                         "`armed-at` boundary — for operator passes over pre-arming refs")
    # §port-20260828 — ported from epstein-drive (Ben, 2026-08-14): skip commits whose SUBJECT
    # matches — for work already reviewed elsewhere. The athena-rollout commits landing in a
    # consumer repo are reviewed by athena itself, so re-reviewing them there is pure spend.
    # Matched against the subject line only (`log -1 --format=%s`), never the diff.
    ap.add_argument("--skip-subject-re", default="",
                    help="regex; commits whose subject matches are skipped (already reviewed elsewhere)")
    # §rollout-ed2-0 — ported from epstein-drive (Ben, 2026-08-14: "use opus as a watch backend
    # instead of codex"). The backend is PLUGGABLE: any driver honouring the same contract works —
    # take `--type/--repo/--input/--output-dir/--models/--effort/--extra`, write
    # `<output-dir>/<model>.md` with a `## Critical Issues (Blocking)` section, and print
    # `model=<m> verdict=<v>`. epstein's `opus_review.py` is such a driver (headless `claude -p`);
    # it IMPORTS this file's sibling `codex_review.py` for the prompt, so both grade alike.
    # Distinct from --engine, which is forwarded INTO the default driver.
    ap.add_argument("--driver", default=str(DRIVER),
                    help="review driver path (default: the sibling codex_review.py)")
    ap.add_argument("--engine", default=DEFAULT_ENGINE, choices=("codex", "claude"),
                    help="review backend forwarded to the driver. `codex` (default, "
                         "unchanged) needs an interactive `codex login`; `claude` drives "
                         "the Claude CLI headless and needs no separate auth — the only "
                         "one this daemon can use where codex is not logged in")
    # Empty default, NOT "codex". The forwarding guard below is
    # `if getattr(cfg, "codex_bin", "")`, so a truthy default meant the daemon
    # always fabricated `--codex-bin codex` -- which the driver reads as an
    # explicit choice and which therefore SUPPRESSED the session default from
    # EUGO_SESSION_CODEX_BIN. A daemon launched inside a kiro-claude session
    # would have silently reviewed on the OpenAI binary while the session spent
    # Kiro credits. Empty means "say nothing and let the driver resolve", which
    # is exactly what test_a_cfg_without_codex_bin_still_works already pins.
    ap.add_argument("--codex-bin", default="",
                    help="codex binary forwarded to the driver: a shorthand "
                         "(codex, kiro, kiro2) or a path. `kiro` reaches "
                         "kiro-gateway and needs no `codex login`, which makes it "
                         "a second way to run this daemon on a box where codex is "
                         "not logged in. Omitted (default) forwards nothing, so the "
                         "driver's own resolution applies -- including the session "
                         "default from EUGO_SESSION_CODEX_BIN")
    ap.add_argument("--models", default="",
                    help="models (light default: ONE, per --engine; csv)")
    ap.add_argument("--effort", default="high", choices=("low", "medium", "high", "xhigh"))
    ap.add_argument("--advice-dir", default=".adversarial-review/watch")
    # §833 — retention for the per-tick `raw/` tree. Both opt-out with 0.
    ap.add_argument("--raw-retention-days", type=float, default=7.0,
                    help="delete raw/ tick dirs older than this many days (0 = keep forever)")
    ap.add_argument("--raw-max-mb", type=float, default=200.0,
                    help="cap the total size of raw/, deleting oldest-first (0 = uncapped)")
    ap.add_argument("--invariants-file", default="",
                    help="file whose text REPLACES the built-in eugo_kb triage-invariants "
                    "block in the driver's `code` prompt (consumer repos pass their own; "
                    "forwarded verbatim to codex_review.py's --invariants-file)")
    ap.add_argument("--once", action="store_true", help="run a single tick then exit (the test hook)")
    ap.add_argument("--max-ticks", type=int, default=0, help="stop after N ticks (0 = unbounded)")
    ap.add_argument("--account-backoff", type=int, default=_ACCOUNT_BACKOFF_S,
                    help="seconds to hold the anchor after an ACCOUNT-level review failure "
                         "(quota, weekly limit, expired auth) instead of spending each "
                         "commit's retry budget on an outage")
    cfg = ap.parse_args(argv)
    global _WRITER                         # §3043 — resolved once per process, before the lock
    _WRITER = _resolve_writer(cfg.once)
    # Compiled once at launch so a bad pattern fails immediately and loudly, not on tick N.
    skip_re = re.compile(cfg.skip_subject_re) if cfg.skip_subject_re else None
    # §1244 — resolve the LIGHT one-model default PER ENGINE. Resolved here rather than
    # as an argparse default because the right value depends on --engine, and an omitted
    # flag must not hand codex model ids to the Claude CLI (or the reverse). An explicit
    # --models always wins. Keeping watch at ONE model is the property that makes it
    # cheap enough to run every tick.
    if not cfg.models.strip():
        if cfg.engine != "codex":
            cfg.models = _WATCH_DEFAULT_CLAUDE_MODEL
        elif _is_gateway_binary(getattr(cfg, "codex_bin", "") or ""):
            # §1648 — per BINARY, not only per engine. A gateway binary keeps
            # `engine == "codex"` while serving a different roster entirely.
            cfg.models = _WATCH_DEFAULT_GATEWAY_MODEL
        else:
            cfg.models = _WATCH_DEFAULT_MODEL

    if not Path(cfg.driver).exists():
        print(f"ERROR: driver not found: {cfg.driver}", file=sys.stderr)
        return 1
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    advice_dir = (Path(cfg.repo) / cfg.advice_dir) if not Path(cfg.advice_dir).is_absolute() else Path(cfg.advice_dir)
    advice_dir.mkdir(parents=True, exist_ok=True)
    # §2124 — a WORKTREE-ONLY run takes its own lock so it is not starved by the commit
    # drain. Any run that reviews commits keeps `.watch.lock` unchanged, including the
    # legacy daemon's `--commits --worktree`, whose two kinds still share one process.
    worktree_only = cfg.worktree and not cfg.commits
    lock_name = WORKTREE_LOCK if worktree_only else WATCH_LOCK
    lock_fd = _acquire_single_instance(advice_dir, lock_name,
                                       wait_s=getattr(cfg, "wait_for_lock", 0.0) or 0.0)
    if lock_fd is None:
        return 1
    # ⚠ §2131 — THE SENTINEL IS PER-KIND FOR THE SAME REASON THE LOCK IS. §2124 split the
    # lock so a worktree run and a commit drain stop contending; it left ONE sentinel
    # between them. The line below consumes it at launch — necessary, so a sentinel left
    # by a previous stop cannot kill this launch one tick in — but the turn-end hook
    # dispatches a worktree `--once` at EVERY turn boundary, so from §2124 onward an
    # operator's `touch STOP` was liable to be eaten by a one-shot seconds later while the
    # daemon it was aimed at ran on. `STOP` still means the commit lane, so the documented
    # gesture is unchanged; the worktree lane answers to `STOP.worktree`.
    stop_file = _transient(advice_dir, WORKTREE_STOP if worktree_only else STOP_SENTINEL)
    stop_file.unlink(missing_ok=True)

    last_sha = cfg.since.strip() or _git(cfg.repo, "rev-parse", "HEAD").strip()
    last_wt_hash = ""
    last_wt_review = 0.0
    ticks = 0
    # §934 — per-sha consecutive `git show` failures, so the hold below is bounded.
    # §1700 — per-sha consecutive DRIVER failures, bounded the same way.
    review_failures: dict[str, int] = {}
    account_down_until = 0.0  # §2089 — set by the account-level branch below
    # ⚠ §2139 — THE STARTUP LINE NAMES THE SELECTION THE RUN WILL ACTUALLY USE. It read
    # `since={last_sha[:12]}` unconditionally, and under `--since-ledger` that value decides
    # NOTHING: selection comes from `unreviewed_commits` below and the anchor is untouched.
    # So the one line an operator reads to learn what a pass is doing was false for the pass
    # they are most likely to be reading about — a catch-up. Measured on this repo's own
    # log: a `--retry-abandoned --ledger-scan 1000` pass announced `since=d25cc40a92d8`,
    # which is HEAD, while it was reaching back to commits from 2026-08-30.
    # §2133's lesson one file over: a label outliving the thing it described.
    # §3067 — resolved once per process; the banner below names them because the selection
    # they change is exactly what a reader of a catch-up log asks about (§2139).
    tick_budget = cfg.tick_budget if cfg.tick_budget is not None else resolve_tick_budget()
    ignore_armed = bool(getattr(cfg, "ignore_armed_at", False))
    if cfg.since_ledger:
        selection = f"selection=ledger scan={cfg.ledger_scan}"
        if getattr(cfg, "retry_abandoned", False):
            selection += " +retry-abandoned"
        boundary = None if ignore_armed else armed_at(advice_dir)
        selection += (f" armed-at={boundary[:12] if boundary else '(none)'}"
                      f" upstream={upstream_ref(cfg.repo) or '(none)'} budget={tick_budget}")
    else:
        selection = f"selection=anchor since={last_sha[:12] or '(none)'}"
    print(f"[watch] started repo={cfg.repo} driver={Path(cfg.driver).name} commits={cfg.commits} worktree={cfg.worktree} "
          f"models={cfg.models} effort={cfg.effort} {selection} → advice in {advice_dir}", flush=True)

    while not _STOP:
        ticks += 1
        try:
            # ⚠ §2139 — THE ANCHOR GATES ONLY THE PATH THAT NEEDS ONE. This read
            # `if cfg.commits and last_sha:`, so an empty `last_sha` skipped the whole
            # commit drain — including under `--since-ledger`, which needs no anchor at
            # all. `_git` returns "" on ANY non-zero exit (see its body), so one failed
            # `git rev-parse HEAD` silently disabled every commit review for that run
            # while the banner still said `commits=True`.
            #
            # That is the exact shape `_changed_lines` states the rule against ~760 lines
            # above: "the caller must treat unknown as 'review it' … would make the gate
            # fail CLOSED — silently skipping every review the moment git's output shape
            # changed or the call failed. That is the §703 shape." One function over, the
            # file did it anyway.
            #
            # The anchor path DOES need the anchor — `rev-list ..HEAD` with an empty left
            # side is a different command, not a no-op — so it keeps its guard and gains a
            # voice, because selecting nothing in silence is how this was missed.
            if cfg.commits:
                if cfg.since_ledger:
                    new, truncated = unreviewed_commits(
                        cfg.repo, advice_dir, cfg.ledger_scan,
                        retry_abandoned=getattr(cfg, "retry_abandoned", False),
                        ignore_armed_at=ignore_armed)
                    if truncated:
                        print(f"[watch] --ledger-scan {cfg.ledger_scan}: the OLDEST commit "
                              f"in the window is itself unreviewed, so older unreviewed "
                              f"commits may exist beyond it — raise --ledger-scan to reach "
                              f"them", file=sys.stderr, flush=True)
                elif last_sha:
                    new = _git(cfg.repo, "rev-list", "--reverse", f"{last_sha}..HEAD").split()
                else:
                    new = []
                    print(f"[watch] ERROR: no anchor — `git rev-parse HEAD` failed in "
                          f"{cfg.repo} and --since was not given, so the anchor path has "
                          f"nothing to count from and selected NOTHING this tick. "
                          f"(`--since-ledger` needs no anchor and is unaffected.)",
                          file=sys.stderr, flush=True)
                # §934 — HOLD THE ANCHOR ON A FAILED `git show`, do not step over it.
                # `_git` returns "" on ANY non-zero git exit (see its body), so a
                # transient failure made `_review` a no-op while the anchor still
                # advanced past that sha — the commit was permanently unreviewed. The
                # earlier cure added a WARN and left the behaviour, so the log said
                # "skipped" and meant "lost".
                reviewed_through = None
                # §3067 — LEDGER MODE REVIEWS THE NEWEST FIRST, under the tick budget. The
                # list is oldest-first (the anchor path needs that: anchoring `last_sha` to a
                # newest-first review would skip older commits forever), so under
                # `--since-ledger`, which has no anchor, HEAD is moved to the front: the commit
                # that just landed is reviewed by the dispatch it triggered, and the backlog
                # behind it drains at ≤budget per tick instead of blocking HEAD for its length.
                order = [new[-1], *new[:-1]] if (cfg.since_ledger and new) else list(new)
                dispatched = 0
                for pos, sha in enumerate(order):
                    if cfg.since_ledger and tick_budget and dispatched >= tick_budget:
                        print(f"[watch] tick budget {tick_budget} reached — {len(order) - pos} "
                              f"commit(s) wait for the next dispatch", flush=True)
                        break
                    if skip_re is not None:
                        subject = _git(cfg.repo, "log", "-1", "--format=%s", sha).strip()
                        if skip_re.search(subject):
                            print(f"[watch] skip {sha[:12]} (subject matches --skip-subject-re): "
                                  f"{subject[:80]}", flush=True)
                            reviewed_through = sha
                            continue
                    show = _git(cfg.repo, "show", sha)
                    if not show.strip():
                        n = _record_show_failure(advice_dir, sha)
                        if n < _MAX_SHOW_RETRIES:
                            print(f"[watch] WARN: git show {sha[:12]} returned empty "
                                  f"(attempt {n}/{_MAX_SHOW_RETRIES}) — holding the anchor, "
                                  f"the next tick retries this commit",
                                  file=sys.stderr, flush=True)
                            break
                        # Bounded, so a permanently unreadable sha cannot wedge the
                        # watcher forever. Loud, because this IS the loss the finding
                        # described and it should never be inferred from silence.
                        print(f"[watch] ERROR: git show {sha[:12]} empty {n}x — giving up "
                              f"and advancing PAST it; this commit will never be reviewed",
                              file=sys.stderr, flush=True)
                        reviewed_through = sha
                        continue
                    # §1700 (§1.57-F6) — READ THE RESULT. This was a bare call followed
                    # by an unconditional `reviewed_through = sha`, so a commit whose
                    # review FAILED was anchored past and never reviewed again — the
                    # daemon's whole job skipped, with a warning in a log nobody
                    # re-reads.
                    #
                    # ⚠ §1648 ALREADY RECORDED THE FAILURE. It sets `entry["driver_exit"]`
                    # and prints a ⚠ line; nothing consumed either. Making a failure
                    # VISIBLE is not the same as recovering from it — the same half-cure
                    # shape as §1692, two rows apart.
                    entry = _review(cfg.repo, "commit", sha, show, cfg, advice_dir)
                    dispatched += 1  # §3067 — a `_review` call is the unit the budget counts
                    if entry is not None and entry.get("driver_exit"):
                        # §2089 — an ACCOUNT-level failure is charged to NOBODY. Spending
                        # this commit's budget on an outage is how seven commits were lost
                        # on 2026-09-08: the anchor holds, the daemon backs off, and the
                        # same commit is re-reviewed when the account returns. A held
                        # anchor costs a delay; an advanced one costs the review forever.
                        down = _account_is_down(entry)
                        if down is not None:
                            account_down_until = time.time() + cfg.account_backoff
                            print(f"[watch] ACCOUNT DOWN: {down} — holding the anchor at "
                                  f"{sha[:12]} and backing off {cfg.account_backoff}s; no "
                                  f"commit is advanced past while the account cannot review",
                                  file=sys.stderr, flush=True)
                            break
                        n = review_failures[sha] = review_failures.get(sha, 0) + 1
                        if n < _MAX_REVIEW_RETRIES:
                            print(f"[watch] WARN: review of {sha[:12]} failed "
                                  f"(driver exit {entry['driver_exit']}, attempt "
                                  f"{n}/{_MAX_REVIEW_RETRIES}) — the ERROR entry is on "
                                  f"the ledger and a later dispatch retries this commit",
                                  file=sys.stderr, flush=True)
                            # §2112 — CONTINUE in ledger mode, break otherwise. The `break`
                            # exists to HOLD THE ANCHOR so a failed commit is not stepped
                            # over; with `--since-ledger` there is no anchor, the commit
                            # stays selected by its own missing verdict, and breaking here
                            # would block every NEWER commit behind a failing older one.
                            if cfg.since_ledger:
                                continue
                            break
                        print(f"[watch] ERROR: review of {sha[:12]} failed {n}x — giving "
                              f"up and advancing PAST it; this commit will never be "
                              f"reviewed", file=sys.stderr, flush=True)
                        review_failures.pop(sha, None)
                    else:
                        review_failures.pop(sha, None)
                    reviewed_through = sha
                if cfg.since_ledger:
                    # §2108 — NO ANCHOR TO ADVANCE. The ledger already records what was
                    # reviewed, so a commit whose review failed simply stays selected and
                    # the next tick retries it. This is the branch that makes the
                    # "advancing PAST it; this commit will never be reviewed" loss
                    # impossible rather than merely bounded.
                    pass
                elif reviewed_through:
                    # Anchor to the last REVIEWED sha, never a later HEAD: a commit that
                    # lands while the reviews above run must appear in the next rev-list.
                    last_sha = reviewed_through
                elif not new:
                    head = _git(cfg.repo, "rev-parse", "HEAD").strip()
                    if head and head != last_sha:
                        last_sha = head  # rev-list empty yet HEAD moved: reset/rebase — re-anchor
            if cfg.worktree:
                diff = _git(cfg.repo, "diff", "HEAD")
                h = hashlib.sha1(diff.encode()).hexdigest()
                seen_h, seen_at = (last_wt_hash,), last_wt_review
                if cfg.since_ledger:
                    # §2116 — the ledger is the debounce, for the same reason it is the
                    # commit cursor: a `--once` process has no memory of the last one.
                    hashes, newest = worktree_state(advice_dir)
                    seen_h, seen_at = hashes, newest
                # §2116 — AND A SIZE GATE. A review costs ~151s (p50); spending that on a
                # three-line diff is worse than not reviewing it, because it delays the
                # one that matters. `--wt-min-lines` is the floor, counted from
                # `diff --shortstat`, and 0 disables it.
                changed = _changed_lines(cfg.repo) if cfg.wt_min_lines else None
                big_enough = changed is None or changed >= cfg.wt_min_lines
                if (diff.strip() and h not in seen_h and big_enough
                        and (time.time() - seen_at) >= cfg.wt_min_interval):
                    # §1700 — the DEDUPE HASH is the worktree's anchor, and it advanced
                    # unconditionally too: a failed review marked that exact diff as
                    # done, so it was never retried even though nothing had reviewed it.
                    # `last_wt_review` still advances on failure, so the retry is
                    # throttled by `--wt-min-interval` rather than looping every tick.
                    wt_entry = _review(cfg.repo, "worktree", h, diff, cfg, advice_dir)
                    if not (wt_entry is not None and wt_entry.get("driver_exit")):
                        last_wt_hash = h
                    last_wt_review = time.time()
            # §833 — retention runs INSIDE the try: a prune failure (a racing
            # reader, a permission error) must not kill the daemon any more than
            # a review failure does.
            gone, freed = prune_raw(
                advice_dir / "raw",
                max_age_days=cfg.raw_retention_days,
                max_total_bytes=int(cfg.raw_max_mb * 1024 * 1024),
            )
            if gone:
                print(f"[watch] retention: pruned {gone} raw dir(s), freed {freed // 1024} KiB",
                      flush=True)
        except Exception as exc:  # noqa: BLE001 — a tick failure must never crash the daemon
            print(f"[watch] tick error: {str(exc).splitlines()[0] if str(exc) else type(exc).__name__}",
                  file=sys.stderr, flush=True)
        if cfg.once or (cfg.max_ticks and ticks >= cfg.max_ticks) or stop_file.exists():
            break
        # §2089 — after an account-level failure, wait it out rather than spinning the
        # retry budget down. Still interruptible, so the STOP sentinel is unaffected.
        sleep_s = cfg.interval
        remaining = int(account_down_until - time.time())
        if remaining > sleep_s:
            sleep_s = remaining
        for _ in range(sleep_s):  # interruptible sleep
            if _STOP or stop_file.exists():
                break
            time.sleep(1)

    print(f"[watch] stopped after {ticks} tick(s).", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
