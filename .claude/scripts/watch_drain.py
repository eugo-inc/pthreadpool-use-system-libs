"""Watch-advice drain (1.0.0) — the `drain-watch` companion of /eugo-adversarial-review.

`codex_watch.py` appends one JSON object per reviewed increment to
`<advice-dir>/advice.jsonl` (+ a human `advice.md` mirror), forever. Since §A2 those two
files are TRACKED — they are the synthesis's watch input — so they need a drain: a
ledger that says what became of every blocking verdict, and a rotation that moves the
handled entries into a monthly archive so the live files stay readable. Pure stdlib,
host-`python3`, dev-only (under `.claude/`, outside the conda env + the Docker images),
Linux (`fcntl.flock`, `/proc`).

```
python3 .claude/scripts/watch_drain.py [--repo <dir>] [--advice-dir .adversarial-review/watch]
        [--watch-script <path>] <subcommand> ...

  status                                  counts, cursor, lock + daemon state (key=value lines)
  list [--after-cursor] [--verdict A,B]    one JSON object per entry (the daemon's own shape);
       [--unresolved] [--paths <spec>...]  --paths keeps kind=commit entries whose
                                          `git show --name-only` intersects the pathspecs
  rotate --through <ts> [--lock-timeout N] [--dry-run]
                                          archive every entry APPENDED (else ts) <= through
  resolve --ref <ref> --status <S> --evidence <text> [--ts <ts>]
          [--lock-timeout N] [--dry-run] write ONE RESOLVED.md row for the matched entry
```

THE LEDGER — `<advice-dir>/RESOLVED.md`. A Markdown table keyed `ts · ref` (the entry's
own `ts` and `ref`; a ref of >= 12 leading characters matches, the daemon's own
shorthand), one row per handled entry, status in {FIXED §id, OPEN → FUTURE, REFUTED,
RETRY, UNTRACED}, plus one marker line `<!-- drained-through: <ts> -->` (`(none)` before
the first drain). `rotate` REFUSES while any NEEDS_REVISION/ERROR entry at or before
`--through` has no row: the record is the precondition, not a by-product.

THE WRITE PATH — `resolve`. Until §3070 the ledger had `status`/`list`/`rotate` and no
way to WRITE a row, so dispositioning meant hand-editing a Markdown table and the queue
grew at review speed while it shrank at hand-edit speed (measured here 2026-09-21:
`unresolved=40`, of which most were already fixed or refuted in commits and prose). A
row is DERIVED from the matched entry — `ts`, `kind`, `ref`, `model`, `verdict` all come
from advice.jsonl, never from the caller; only `status` and `evidence` are the caller's,
because only those are a judgement. The row is inserted INSIDE the ledger table rather
than appended at EOF: `read_resolved` only sees rows while `in_table`, so a row written
below later prose would be walked straight past — the §2159 defect, written rather than
read. Every write is verified by RE-READING it with this file's own reader before the
rename, so "the writer emits rows the reader accepts" is a checked precondition rather
than a claim.

⚠ `resolve` DOES NOT DEDUPE A RE-REPORTED DEFECT. A `worktree` ref is a per-snapshot
content hash, so an undispositioned finding re-mints a NEW owed entry at every turn
boundary and needs a fresh row each time. Fingerprinting the finding itself was
considered and REFUSED at §3070: the two live `.gitignore` entries on 2026-09-21
(`66cbea4b3784` 04:03:51Z, `3bd4f1e0b04c` 04:29:53Z) are one defect whose text was
REWRITTEN between rounds — "has been truncated to 0 bytes" vs "is still 0 bytes …
Fifth round, still unaddressed" — so any fingerprint tight enough to be safe misses
them, and one loose enough to catch them can make a genuinely NEW finding inherit a
stale REFUTED and vanish. A stable finding id belongs at EMISSION (the reviewer naming
its own finding), not at disposition time by post-hoc text matching.

`--through` takes the daemon's own `YYYY-MM-DDTHH:MM:SSZ`, or a bare `YYYY-MM-DD` meaning
through the end of that UTC day, and is refused when later than now (§2918).

LOCKS. `rotate` runs under `<advice-dir>/.advice.lock` — the per-append lock the daemon
takes around BOTH its writes (`codex_watch._ADVICE_LOCK`; the name is pinned equal to
`ADVICE_LOCK` below by `tools/tests/test_watch_drain.py`). It cannot share the daemon's
lifetime `.watch.lock`, which is one-daemon-per-directory. A daemon started BEFORE the
installed `codex_watch.py` was last written never takes `.advice.lock` (it predates the
lock), so a rotation would race its appends: `rotate` reads the holder's pid from
`.watch.lock` (the daemon writes it there), its start time from `/proc/<pid>/stat`, and
refuses with "restart the watch daemon first" when that start predates the script's
mtime. Test/diagnostic hook: `WATCH_DRAIN_HOLDER_START=<epoch seconds>` replaces the
`/proc` read of the holder's start time (nothing else).

EXIT CODES. 0 done · 1 failure having written nothing (I/O, malformed input, a cursor
that would move backwards, `in != archived + remaining`, or a `resolve` whose --ref
matches no entry / more than one / whose --status is outside the vocabulary) · 2 an owed
entry has no RESOLVED.md row · 3 `.advice.lock` not acquired within `--lock-timeout` · 4
the watch daemon holding `.watch.lock` predates the installed `codex_watch.py`.

WRITES. Every file `rotate` touches is written to a sibling temp file, fsynced and
renamed into place: `archive/<yyyy-mm>.jsonl` (appended, by entry month), `advice.jsonl`
(the remaining raw lines, byte-for-byte), `advice.md` (regenerated from the remaining
entries with the daemon's exact rendering — `render_md` below IS `codex_watch._review`'s
loop), then `RESOLVED.md` (the marker). A failure between renames can only leave an
entry in BOTH the archive and the live file, never in neither.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from datetime import datetime, timezone
from pathlib import Path

# This repo root (/opt/eugo/athena) — `.claude/scripts/watch_drain.py`.parents[2].
REPO_ROOT = str(Path(__file__).resolve().parents[2])
DEFAULT_ADVICE_DIR = ".adversarial-review/watch"
#: The installed daemon next to this script — the mtime the stale-daemon check compares.
DEFAULT_WATCH_SCRIPT = str(Path(__file__).resolve().parent / "codex_watch.py")

#: MIRRORS `codex_watch._ADVICE_LOCK` — pinned equal by `test_watch_drain.py`. Two names for
#: one file would be two processes each holding "the" lock.
ADVICE_LOCK = ".advice.lock"
#: The daemon's lifetime lock (`codex_watch._acquire_single_instance`); it writes its pid in.
WATCH_LOCK = ".watch.lock"
ADVICE_JSONL = "advice.jsonl"
ADVICE_MD = "advice.md"
RESOLVED_MD = "RESOLVED.md"
ARCHIVE_DIR = "archive"

#: The verdicts a drain OWES a ledger row for. APPROVED needs no trace.
OWED_VERDICTS = frozenset({"NEEDS_REVISION", "ERROR"})
#: §3043 — MIRRORS codex_watch.WRITERS (pinned equal by test_watch_drain.py). `unknown` is
#: every entry written before the field existed (~1,959 rows on 2026-09-19), so the
#: daemon-vs-hook coverage question is answerable forward, not backward.
WRITERS = ("hook-commit", "hook-turn-end", "daemon", "once")
#: §3103 — MIRRORS `codex_watch.SESSION_ENV`, pinned equal by test_watch_drain.py for the
#: same reason WRITERS is: two copies of a name that must agree is how they stop agreeing.
SESSION_ENV = "EUGO_REVIEW_SESSION"
#: §3067 — MIRRORS `codex_watch.ARMED_RE` (the arming boundary in RESOLVED.md, written by
#: `eugo-skills arm-review`); pinned equal by test_watch_drain.py like WRITERS above.
ARMED_RE = re.compile(r"^<!-- armed-at: ([0-9a-f]{40}) -->$", re.M)
#: §3046 — MIRRORS codex_watch._ACCOUNT_DOWN_MARKERS (pinned equal by test_watch_drain.py):
#: the notes that mean the ACCOUNT could not review, as distinct from this commit failing.
#: `status` counts the owed entries that carry one, INFORMATIONALLY — they stay owed (a
#: re-review or a RETRY row is still the cure), the count just says how much of the owed
#: pile is an outage rather than a finding.
ACCOUNT_DOWN_MARKERS = (
    "hit your session limit",
    "hit your weekly limit",
    "hit your usage limit",
    "failed to authenticate",
    "oauth session",
    "not found on path",
    "cli not on path",
)


def account_is_down(obj: dict) -> bool:
    """True when a result note or the driver's stderr tail names an account-level outage."""
    texts = [str(r.get("note") or "") for r in (obj.get("results") or []) if isinstance(r, dict)]
    texts.append(str(obj.get("driver_stderr_tail") or ""))
    return any(marker in t.lower() for t in texts for marker in ACCOUNT_DOWN_MARKERS)
def account_hold_until(advice_dir: Path, now: float | None = None) -> str:
    """§3122 — the persisted quota hold (`.account-down`, written by codex_watch) as
    `YYYY-MM-DDTHH:MM:SSZ` while in force, else `-`. Read with the same fail-OPEN rule as
    its writer's reader: absent, unreadable or junk is `-` (no hold), never an error."""
    try:
        parts = (advice_dir / ".account-down").read_text(encoding="utf-8").split()
        until = float(parts[0])
    except (OSError, ValueError, IndexError):
        return "-"
    if until <= (time.time() if now is None else now):
        return "-"
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(until))
    # §3130 — the hold names the account that hit the limit; say whose it is, so a session
    # on another account reads "not yours" rather than "reviewing is off".
    return stamp if len(parts) < 2 else f"{stamp}(account:{parts[1][:8]})"


#: The status vocabulary — the row's status cell must START with one of these.
#: §3108 adds `CLAIMED` (§1.85 cure 2). Purely ADDITIVE: the reader is a prefix test, so
#: every row written before it stays valid and no existing status changes meaning.
STATUS_VOCAB = ("CLAIMED", "FIXED", "OPEN", "REFUTED", "RETRY", "UNTRACED")

#: §3108 — how long a claim holds the finding before it returns to the pool.
#:
#: ⚠ 24 HOURS IS AN OPERATOR RULING (2026-09-22) AND THE REASON IS NOT FIX DURATION. Asked
#: to choose, I offered 30 min / 90 min / 8 h, all derived from how long WORK takes here
#: (review p50 151 s, ~8.1 min per commit, the >90 min BLOCKED threshold). Every one was
#: wrong by an order of magnitude, because the quantity that actually matters is how long
#: a SESSION SITS PARKED: "sometimes I do not continue the session until some other ends".
#: A claim TTL is a statement about the claimer's availability, not about the task.
#:
#: HARD EXPIRY, no renewal (same ruling). A claim that refreshes itself on activity is one
#: a stuck or looping session renews forever, which is exactly the "stale claims become the
#: next backlog" failure §1.85 warns about. Re-claiming after expiry is one explicit call.
CLAIM_TTL_SECONDS = 24 * 3600

#: §3112 — how far ahead of our clock a claim's stamp may sit and still be believed.
#: Three sessions share this checkout as different UNIX users, and a stamp written a
#: second or two ahead of the reader's clock is ordinary disagreement, not a forgery.
#: Beyond this the stamp is not trusted and the claim FAILS OPEN (finding stays visible),
#: which is what stops a skewed clock or a hand-edited cell parking a finding for a year.
CLAIM_FUTURE_SKEW_SECONDS = 300

#: §3102 (§1.85 cure 1) — the statuses that do NOT take an entry off the queue.
#:
#: ⚠ EVERY QUERY USED TO KEY ON ROW PRESENCE, NOT STATUS: `resolved.lookup(e) is None`. So a
#: session that correctly declined a verdict as not-its-own, and said so in the sanctioned way
#: by writing an `OPEN` row, REMOVED that verdict from every other session's queue — its
#: owner's included. Measured in protomolecule on refs `573138344d32` and `58fadb21bb0b`: both
#: were absent from `list --unresolved` the moment the courtesy row landed, and one of them had
#: been deliberately left rowless by a peer BECAUSE its finding was live.
#:
#: The vocabulary always anticipated this — `OPEN` has been a token since the file was written.
#: Only the queries never honoured it, which is why the cure is a predicate and not a new token.
#: §3108 — `CLAIMED` joins it. A claim says "I am working on this", which is the opposite
#: of a closure: `rotate` must never archive a claimed entry, and `resolve` must still be
#: able to write the real disposition over it when the work lands.
NON_DISCHARGING = ("OPEN", "CLAIMED")


def discharges(status: str | None) -> bool:
    """Does a RESOLVED.md row carrying `status` take its entry OFF the queue?

    None (no row at all) does not discharge. A row whose status begins with a
    NON_DISCHARGING token does not discharge either: it records that somebody looked and
    left the finding live, which is the opposite of closing it.
    """
    return status is not None and not status.startswith(NON_DISCHARGING)


def owns(entry_session: str | None, session: str | None) -> bool:
    """Is an entry stamped `entry_session` owned by `session`?

    ONE definition, imported by every caller — `list --mine`, the turn-end hook's
    blocking partition, and anything later that asks the same question. §3094 said "both
    comparison sites" and there were three; §3102 said "all three predicates" and there
    were four; a second copy of THIS predicate is how that becomes five, so the hook
    imports it rather than re-deriving it in its embedded Python.

    ABSENT IS NOT A MATCH, on either side. An unstamped entry (820 of the 822 in athena's
    ledger on 2026-09-22, every one written before §3103) is owned by NOBODY rather than
    by everybody, and a caller with no session of its own owns nothing. Both directions
    matter: the first stops a cold session inheriting the whole backlog as "its" work,
    the second stops an unidentified caller claiming it.

    ⚠ OWNERSHIP OF A `worktree` ENTRY MEANS "DISPATCHED IT", NEVER "WROTE IT". That ref is
    a content hash over the SHARED dirty tree, which several sessions and accounts write
    at once, so the stamp records who asked for the review and nothing about authorship.
    §3085's wording already refuses to claim an owner for those; this predicate is what
    decides whose turn gets INTERRUPTED, which is a different question and a fair one.
    """
    a = (entry_session or "").strip()
    b = (session or "").strip()
    return bool(a) and a == b


#: `CLAIMED <session> <ISO8601>` — the two cells a claim carries inside its status.
CLAIM_RE = re.compile(r"^CLAIMED\s+(\S+)\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")


def parse_claim(status: str | None) -> tuple[str, float] | None:
    """`(claimant, claimed_at_epoch)` for a well-formed claim row, else None.

    A `CLAIMED` row this cannot parse is deliberately treated as NO claim by
    `claim_is_live` below, so a hand-edited or truncated cell fails OPEN — the finding
    stays visible to everyone. The opposite default would let one malformed row park a
    finding permanently, which is the failure mode §1.85 names.
    """
    m = CLAIM_RE.match((status or "").strip())
    if not m:
        return None
    try:
        when = datetime.strptime(m.group(2), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return m.group(1), when.timestamp()


def claim_is_live(status: str | None, now: float | None = None) -> bool:
    """Is this row a claim that has NOT yet expired?"""
    got = parse_claim(status)
    if got is None:
        return False
    _who, at = got
    # ⚠ §3112 — A CLAIM CAN NEVER HAVE STARTED LATER THAN NOW, AND §3108's COMMENT HERE
    # ASSERTED A BOUND IT DID NOT IMPLEMENT. It read: "it expires TTL after its own stamp,
    # and clock skew ... must not make one immortal. Comparing to `at + TTL` rather than to
    # `now - at` keeps that bounded." Both halves were false. The two forms are the SAME
    # inequality — `now < at + TTL` ⟺ `now - at < TTL` — so the distinction it drew does
    # not exist; and neither bounds a FUTURE stamp. Measured on the shipped code: a row
    # stamped one year ahead reported live=True, i.e. live for a year, which is exactly the
    # "stale claims that never expire become the next backlog" failure §1.85 names the TTL
    # to prevent. A wrong comment is bad; this one was worse, because it told the next
    # reader the hazard was already handled.
    #
    # ⚠ AND THE FIRST FIX FOR IT WAS ALSO WRONG, caught by this function's own new test
    # before it shipped. It read `now < min(at, now) + TTL` — clamping the start to `now`.
    # But `now` is the EVALUATION time, so the clamp moves with every call: at now+10*TTL
    # the effective start is also now+10*TTL, and the claim is live again. A bound measured
    # from a moving reference is not a bound. Demonstrated at three evaluation times, all
    # live.
    #
    # A claim must have STARTED to be live, and only a stamp that is plausibly in the past
    # counts as started. `CLAIM_FUTURE_SKEW_SECONDS` is the tolerance for ordinary clock
    # disagreement between machines sharing this checkout; beyond it the stamp is not
    # trusted, and an untrusted claim FAILS OPEN — the finding stays visible to everyone,
    # exactly as an unparseable claim does in `parse_claim`. Hiding a finding is the
    # privilege this function grants, so anything it cannot vouch for must not get it.
    now = time.time() if now is None else now
    return at - CLAIM_FUTURE_SKEW_SECONDS <= now < at + CLAIM_TTL_SECONDS


def hides(status: str | None, now: float | None = None) -> bool:
    """Does this row take the entry off the QUEUE right now?

    Two different questions live here and conflating them is how `rotate` would delete
    work somebody is doing:

    * `discharges` — is it CLOSED? Permanent, and the only thing that may let `rotate`
      archive an entry away.
    * `hides` — should the queue stop showing it right now? Closed OR live-claimed, and
      the claim half is TEMPORARY by construction.

    So `list --unresolved` and `status` ask THIS, and `rotate` keeps asking `discharges`.
    """
    return discharges(status) or claim_is_live(status, now)
#: A ref this short or longer identifies an entry (the daemon logs `ref[:12]`).
MIN_REF_PREFIX = 12

#: §2183 — the hook that DISPATCHES review under the §2109 regime, and the event that
#: makes it a trigger rather than a backstop. One script holds two rows (`PostToolUse`
#: with no arguments, `SessionStart --full`); the trigger is the one whose absence means
#: new commits are not reviewed at all, so it is the one `review_wired` asks about.
REVIEW_HOOK_REL = ".claude/hooks/eugo-review-on-commit.sh"
REVIEW_HOOK_EVENT = "PostToolUse"
SETTINGS_REL = ".claude/settings.json"
#: ⚠ COUPLED TO `codex_watch`'s `--ledger-scan` DEFAULT, deliberately. The hook dispatches
#: `--once --since-ledger` with that default, so a count taken over a different window
#: would answer a question nobody asked: `unreviewed` means "what the next dispatch would
#: select", which is the only version of it a reader can act on.
REVIEW_SCAN = 100

CURSOR_NONE = "(none)"
CURSOR_RE = re.compile(r"^<!-- drained-through: (\S+) -->$", re.M)
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ENV_HOLDER_START = "WATCH_DRAIN_HOLDER_START"

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_UNRESOLVED = 2
EXIT_LOCK_TIMEOUT = 3
EXIT_STALE_DAEMON = 4

LOCK_POLL_SECONDS = 0.1


class DrainError(Exception):
    """A refusal with its exit code; `main` prints the message and returns the code."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def row_cells(line: str) -> list[str]:
    """Cells of a markdown table row, split the way GFM does — on every `|` EXCEPT `\\|`.

    ⚠ §2180 — THE LAST LEDGER READER STILL SPLITTING ON THE BARE PIPE, four commits after
    the class was closed everywhere else. §2050 retired `str.split("|")` from
    `pickable._cells` and §2068 from `gap-check.py` / `ledger-audit.py` /
    `orphan-findings.py`; this parser kept `stripped.strip("|").split("|")`, which does
    BOTH of the things `pickable.row_cells`'s own docstring names — the bare split, and a
    `strip("|")` that would eat the pipe of a trailing `\\|`.

    Not latent: measured on this repo's live RESOLVED.md, line 76 splits into 8 cells the
    old way and 7 the GFM way, the divergence falling in the EVIDENCE cell. The six fields
    read below are unaffected there — but `len(cells) < 7`, the malformed-row detector, is
    not: an escaped pipe inflates the count, so a genuinely short row carrying one passes a
    check written to catch it.

    COPIED, NOT IMPORTED, and that is forced rather than preferred: `pickable.py` lives in
    athena's `.adversarial-review/` and this script ships to every consumer repo, which has
    no such sibling. `tools/tests/test_watch_drain.py` pins the two byte-for-byte in
    behaviour, the same way `ADVICE_LOCK` is pinned equal to `codex_watch._ADVICE_LOCK`.
    """
    s = line.strip()
    # The body rule is the table gate's: strip ONE leading pipe and, when present, ONE
    # trailing pipe — never `strip("|")`.
    body = s[1:-1] if s.endswith("|") else s[1:]
    out: list[str] = []
    cur: list[str] = []
    i, n = 0, len(body)
    while i < n:
        if body[i] == "\\" and i + 1 < n:
            cur.append(body[i:i + 2])
            i += 2
            continue
        if body[i] == "|":
            out.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(body[i])
        i += 1
    out.append("".join(cur))

    return [c.strip() for c in out]


def _abandoned_count(advice_dir: Path) -> "int | str":
    """Commits the watcher GAVE UP ON — reviewed by nobody, and excluded from ever being.

    ⚠ §2123 — THIS NUMBER EXISTED ONLY IN THE LEDGER'S FAILURE HISTORY AND NOTHING READ IT.
    `owed`/`unresolved` above count ledger ROWS that need a RESOLVED.md row; a commit whose
    review failed its way to the retry cap produces no owed row at all, so it left no trace
    anywhere a human looks. Measured on 2026-09-13: **31 commits on athena's own branch had
    been abandoned unreviewed**, including §2116-§2120 — the commits that built this
    system — and the only way anyone found out was by writing this query by hand.
    §2066's three-strike rule is deliberate and stays; being silent about its result is not.

    THE PREDICATE IS IMPORTED, NEVER RE-DERIVED. `codex_watch` owns what counts as a real
    review, what counts as an outage (charged to nobody, §2089/§2114) and what the cap is;
    a second copy here would be the two-definitions defect that §2110 and §2112 each shipped.
    Returns "?" rather than raising when the sibling is absent or too old to have the
    helpers — every consumer repo ships a `codex_watch.py` that predates them, and `status`
    must keep working there.
    """
    counts = _stuck_split(advice_dir)

    return counts if isinstance(counts, str) else counts[0]


def _unreviewable_count(advice_dir: Path) -> "int | str":
    """Commits no retry could ever have reviewed — a REFUSAL, not a give-up.

    ⚠ §2179 — `abandoned` FUSED TWO STATES AND THE LOUDER READING WAS THE WRONG ONE.
    "ABANDONED unreviewed" says the watcher stopped trying and a human should push it;
    §2627 and §2628 are a ~4.95 MB `runlog.jsonl` reformat that answered "Prompt is too
    long" on every attempt, where no amount of pushing would have helped. Reported as one
    number, the session banner asked for an action that did not exist, every session, for
    days — and the actual action (split the diff, §2177/§2178) was invisible in it.

    Returns "?" on an older sibling for the same reason `_abandoned_count` does: every
    consumer repo ships a `codex_watch.py` that predates `terminal_refs`.
    """
    counts = _stuck_split(advice_dir)

    return counts if isinstance(counts, str) else counts[1]


def _stuck_refs(advice_dir: Path) -> "tuple[set[str], set[str]] | None":
    """(refs review gave up on, of which these were REFUSED) — ONE import of the predicates."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import codex_watch  # noqa: PLC0415 — sibling script, resolved beside this file
        done = codex_watch.reviewed_refs(advice_dir)
        spent = codex_watch.failed_attempts(advice_dir)
        cap = codex_watch._MAX_REVIEW_RETRIES
        # §2179 — an older sibling has no `terminal_refs`, and an empty set is the right
        # answer there: it reproduces exactly what `abandoned` meant before this split.
        terminal = (codex_watch.terminal_refs(advice_dir)
                    if hasattr(codex_watch, "terminal_refs") else set())
    except Exception:  # noqa: BLE001 — a missing/stale sibling is reported, not fatal
        return None

    return {ref for ref, n in spent.items() if n >= cap and ref not in done}, terminal


def _stuck_split(advice_dir: Path) -> "tuple[int, int] | str":
    """(gave up, could never have succeeded) — the two counts, split once."""
    got = _stuck_refs(advice_dir)
    if got is None:
        return "?"
    stuck, terminal = got

    return len(stuck - terminal), len(stuck & terminal)


def retry_scan_depth(advice_dir: Path, repo_root: Path) -> str:
    """How deep `--ledger-scan` must go to REACH the stuck refs, "" when none, or "?".

    ⚠ §2189 — §2179'S BANNER NAMED A CURE ITS OWN DEFAULT CANNOT REACH. The line reads
    "rerun with --retry-abandoned", and the comment above it asserts "the cure named here
    is one that works". The COUNT is ledger-wide and unbounded (`_stuck_refs` walks
    advice.jsonl plus every archive). The CURE is bounded: `--retry-abandoned` only empties
    the exclusion filter, while the candidate set is still
    `rev-list --reverse -{scan} HEAD` with `--ledger-scan` defaulting to 100 — built BEFORE
    the filter is applied.

    That is not a corner. §2178 saturates a terminal refusal at the cap on its FIRST
    occurrence, so such a ref is permanently excluded from ordinary selection and can only
    leave the count via `--retry-abandoned` — which stops reaching it the moment it ages
    past 100 commits. The two refs §2179's own message counted were 307 and 308 commits
    back when it was written, and clearing them took `--ledger-scan 330`. The
    window-too-small warning does not cover it either: `truncated` is False whenever the
    window's oldest commit IS reviewed, which is the normal case.

    One `git rev-list --count` per stuck ref, and only when there ARE stuck refs — zero
    git calls on the common path. "?" on any failure, and the hook stays silent on it.
    """
    got = _stuck_refs(advice_dir)
    if got is None:
        return "?"
    stuck = got[0]
    if not stuck:
        return ""
    depth = 0
    for ref in sorted(stuck):
        if not is_hex_ref(ref):          # §3129 — never an option on git's argv
            return "?"
        try:
            out = subprocess.run(["git", "rev-list", "--count", "--end-of-options", f"{ref}..HEAD"],
                                 cwd=str(repo_root), capture_output=True, text=True,
                                 timeout=30)
        except (OSError, subprocess.SubprocessError):
            return "?"
        if out.returncode != 0 or not out.stdout.strip().isdigit():
            return "?"
        depth = max(depth, int(out.stdout.strip()) + 1)   # +1: the ref itself

    return str(depth)


def review_wired(repo_root: Path) -> str:
    """"yes" | "no" | "unrunnable" | "?" — can this checkout dispatch a review at all?

    ⚠ §2183 — THE QUESTION THE SESSION BANNER WAS ACTUALLY TRYING TO ASK. It reported
    daemon liveness from the watch lock, which §2109 made meaningless; what a reader needs
    to know is whether review is WIRED (this) and whether anything is UNREVIEWED
    (`unreviewed_count`). A held lock is neither.

    FOUR values, not a bool, because §2173 is two commits old: a registered hook sitting
    at mode 0644 is a different fault from an unregistered one, and printing "install it"
    at a file that is already there sends the reader to the wrong cure.

      yes         — registered on REVIEW_HOOK_EVENT and executable
      no          — no such registration (settings.json absent, or the row is not there)
      unrunnable  — registered, but the script is missing or not executable
      ?           — settings.json is present and cannot be read or parsed; §1726's rule, one file
                    over: ABSENT IS SILENCE, UNREADABLE IS A FINDING, and a corrupt file
                    must never read as "not wired"

    ⚠ THE PREDICATE IS COPIED FROM `hookcfg._row_of_command`, NOT IMPORTED, and that is
    forced: `hookcfg` lives in `tools/eugo_kb/skills/` and this script ships to consumer
    repos with no `eugo_kb` package. `tools/tests/test_watch_drain.py` pins it against
    `hookcfg.script_problem` where that module IS present — the same arrangement §2180 made
    for `row_cells` vs `pickable.row_cells`, and `ADVICE_LOCK` vs `codex_watch._ADVICE_LOCK`.
    Matching is on the script tail with NO arguments, because one script holds two rows and
    only the argument-less `PostToolUse` one is the trigger.
    """
    settings_path = repo_root / SETTINGS_REL
    try:
        raw = settings_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "no"          # absent is not wired — a real, actionable state
    except (OSError, UnicodeDecodeError):
        # §2918 (§1.72 row 11) — PRESENT BUT UNREADABLE IS "?", NEVER "no". `except OSError`
        # used to catch EACCES, EISDIR and EIO beside ENOENT, so a registered hook behind an
        # unreadable file was reported as not wired, naming a cure for the wrong fault. And a
        # file that is not UTF-8 raised UnicodeDecodeError straight through `status`.
        return "?"
    try:
        settings = json.loads(raw)
    except ValueError:
        return "?"
    if not isinstance(settings, dict):
        return "?"
    hooks = settings.get("hooks")
    groups = hooks.get(REVIEW_HOOK_EVENT) if isinstance(hooks, dict) else None
    registered = False
    for group in groups or []:
        if not isinstance(group, dict):
            continue
        for entry in group.get("hooks") or []:
            if not isinstance(entry, dict):
                continue
            parts = str(entry.get("command", "")).split()
            if parts and parts[0].endswith(REVIEW_HOOK_REL) and not parts[1:]:
                registered = True
    if not registered:
        return "no"
    script = repo_root / REVIEW_HOOK_REL
    if not script.is_file() or not os.access(script, os.X_OK):
        return "unrunnable"

    return "yes"


def unreviewed_count(repo_root: Path, advice_dir: Path) -> "str":
    """How many commits the next dispatch would select, as a string, or "?".

    ⚠ §2183 — THE OUTCOME, WHICH NOTHING REPORTED. `owed`/`unresolved` count ledger rows
    awaiting a RESOLVED.md row; `abandoned`/`unreviewable` count commits review gave up on
    or refused. None of them answers "is review keeping up", which is what a reader looks
    at the session line for.

    THE PREDICATE IS IMPORTED, NEVER RE-DERIVED — `codex_watch` owns what "unreviewed"
    means and has been corrected three times (§2110, §2112, §2114). Measured at 17 ms
    against `status`'s own 88 ms, so it is affordable in a SessionStart hook.

    ⚠ IT SHELLS OUT TO GIT, which `status` did not before. `changed_paths` below already
    does, with the same rule: any failure degrades to "?" rather than raising, because this
    runs in a hook in checkouts that may not be a git repo at all — and "?" must never be
    read as zero (`abandoned` and `unreviewable` already carry that rule, and the hook
    stays silent on it).

    A trailing "+" means the scan window was itself exhausted: its oldest commit is also
    unreviewed, so older ones may exist beyond it and the number is a FLOOR, not a total.
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import codex_watch  # noqa: PLC0415 — sibling script, resolved beside this file
        # ⚠ ASK GIT A QUESTION IT MUST ANSWER, FIRST. `codex_watch._git` returns "" on a
        # non-zero exit rather than raising, so `unreviewed_commits` on a tree that is not
        # a checkout returns `([], False)` — BYTE-IDENTICAL to "nothing is unreviewed".
        # The try/except below cannot see that: there is no exception. Measured on a tmp
        # directory: `unreviewed_commits(...) -> ([], False)`, and this function returned
        # "0". That is §703's shape, and `_changed_lines` states the rule three lines under
        # `_git` itself — a detector's zero must never be read as a fact about the tree.
        if not codex_watch._git(str(repo_root), "rev-parse", "HEAD").strip():
            return "?"
        pending, truncated = codex_watch.unreviewed_commits(
            str(repo_root), advice_dir, REVIEW_SCAN)
    except Exception:  # noqa: BLE001 — no git binary, or a sibling too old: report, never fail
        return "?"

    return f"{len(pending)}{'+' if truncated else ''}"


def unreviewed_oldest_h(repo_root: Path, advice_dir: Path) -> str:
    """Hours since the OLDEST pending commit was committed, "0" when none, or "?".

    §3109 (§1.85) — THE DEPTH WAS NEVER THE URGENT NUMBER. `unreviewed=N` says how much
    is queued; it cannot distinguish six commits from the last ten minutes (healthy, they
    drain at ≤budget per tick) from six that have been waiting since yesterday (the queue
    is not keeping up). Measured on this repo's own ledger 2026-09-22: commit-to-review
    p90 of 63.9 min since 2026-09-21 with six over an hour, and NOTHING reported it —
    which is exactly why the operator noticed it as "arrived almost an hour or two later"
    rather than from any line this tooling prints.

    Same degradation rule as `unreviewed_count`: "?" on any failure, and "?" is never zero.
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import codex_watch  # noqa: PLC0415 — sibling script, resolved beside this file
        if not codex_watch._git(str(repo_root), "rev-parse", "HEAD").strip():
            return "?"
        pending, _truncated = codex_watch.unreviewed_commits(
            str(repo_root), advice_dir, REVIEW_SCAN)
        if not pending:
            return "0"
        # `unreviewed_commits` returns OLDEST-FIRST, so pending[0] is the one that has
        # been waiting longest. Its committer date, not its author date: a rebased or
        # cherry-picked commit keeps an author date from days earlier and would report a
        # backlog that never existed.
        when = codex_watch._git(str(repo_root), "log", "-1", "--format=%ct", pending[0]).strip()
        if not when:
            return "?"
        hours = (time.time() - float(when)) / 3600.0
    except Exception:  # noqa: BLE001 — same contract as the count above
        return "?"

    return f"{hours:.1f}"


def selection_fields(repo_root: Path, advice_dir: Path) -> str:
    """§3067 — `armed_at=… upstream_ref=… tick_budget=…`, the three things that decide what
    the next dispatch selects, read from the sibling `codex_watch`; "" when the sibling
    predates them (the "" rule `eugo-watch-owed.sh` already follows for `unreviewed`)."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import codex_watch  # noqa: PLC0415 — sibling script, resolved beside this file
        armed = codex_watch.armed_at(advice_dir)
        upstream = codex_watch.upstream_ref(str(repo_root))
        return (f"armed_at={armed[:12] if armed else '(none)'} "
                f"upstream_ref={upstream or '(none)'} "
                f"tick_budget={codex_watch.resolve_tick_budget()}")
    except Exception:  # noqa: BLE001 — a sibling too old for §3067: report nothing, never fail
        return ""


def _fmt_epoch(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _pad(raw: object) -> str:
    """§2918 — ONE COMPARABLE SHAPE for `ts` (whole seconds) and `appended` (microseconds).

    Compared raw, `...:05.4Z` sorts BEFORE `...:05Z` ('.' < 'Z'), so an entry appended half a
    second after a cursor would read as drained. Copied from the turn-end hook's `_pad`, which
    solved the same comparison; this script ships to repos without that hook. "" for anything
    that is not a Z-suffixed string, which sorts before every real stamp.
    """
    if not isinstance(raw, str) or not raw.endswith("Z"):
        return ""
    return raw if "." in raw else raw[:-1] + ".000000Z"


def parse_through(value: str, now: str | None = None) -> str:
    """Normalise `--through`: a full daemon ts, or a date meaning the end of that UTC day.

    §2918 (§1.72 row 10) — AND NEVER LATER THAN NOW. The cursor becomes this value, and
    `list --after-cursor` shows only entries appended after it, so a future cursor hides every
    verdict appended between now and then from the synthesis, with no race needed. A bare
    date means 23:59:59, so TODAY'S date is the easy way to do it. `now` is for tests.
    """
    value = value.strip()
    if TS_RE.match(value):
        through = value
    elif DATE_RE.match(value):
        through = f"{value}T23:59:59Z"
    else:
        raise DrainError(
            EXIT_FAIL, f"--through must be YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD, got {value!r}"
        )
    now = now or _fmt_epoch(time.time())
    if through > now:
        raise DrainError(
            EXIT_FAIL,
            f"--through {through} is later than now ({now}): every verdict appended before then "
            f"would sit at or before the cursor and never be listed by `list --after-cursor`. "
            f"Pass a full timestamp no later than now; nothing written",
        )
    return through


# ---------------------------------------------------------------------------
# advice.jsonl
# ---------------------------------------------------------------------------


class Entry:
    """One advice.jsonl line: the parsed object AND the raw line it came from.

    The raw line is what gets written back (to the archive or the rewritten live
    file), so a rotation never re-serialises an entry — byte identity is not a
    property of `json.dumps` this script has to keep proving.
    """

    __slots__ = ("lineno", "raw", "obj")

    def __init__(self, lineno: int, raw: str, obj: dict):
        self.lineno = lineno
        self.raw = raw
        self.obj = obj

    @property
    def ts(self) -> str:
        return self.obj["ts"]

    @property
    def session(self) -> str:
        """§3103 — the session whose hook DISPATCHED this review, or "" when unrecorded.

        ⚠ Not authorship, and for `kind="worktree"` not even close: that ref is a content
        hash over the shared dirty tree, so every session in the checkout contributed to it
        and this field names only whose turn-end fired. For `kind="commit"` it is the best
        owner signal this system has — git cannot attribute an author on a shared clone.
        """
        val = self.obj.get("session")
        return val if isinstance(val, str) else ""

    @property
    def visible_at(self) -> str:
        """§2918 (§1.72 row 10) — when this entry became VISIBLE, padded for comparison.

        `ts` is the review START; the entry is appended ~151 s later (p50), and lanes run
        concurrently (§2124), so a review started before a rotation can land after it with
        `ts <= cursor` and vanish from `list --after-cursor` for good. §2130 added
        `appended` (stamped inside the ledger lock) for exactly this; the drain never read
        it. Entries written before §2130 have no `appended` and fall back to `ts`, the best
        they carry. RESOLVED.md rows stay keyed on `ts`, which is the entry's identity.
        """
        return _pad(self.obj.get("appended") or self.obj["ts"])

    @property
    def ref(self) -> str:
        return self.obj["ref"]

    @property
    def kind(self) -> str:
        return self.obj["kind"]

    @property
    def verdicts(self) -> list[str]:
        return [str(r.get("verdict", "?")) for r in self.obj["results"]]

    @property
    def owed(self) -> bool:
        return any(v in OWED_VERDICTS for v in self.verdicts)

    @property
    def month(self) -> str:
        return self.ts[:7]


def load_entries(path: Path) -> list[Entry]:
    """Parse advice.jsonl strictly: a line this cannot account for is a refusal, because
    `rotate`'s conservation promise (`in == archived + remaining`) is over LINES."""
    if not path.exists():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise DrainError(EXIT_FAIL, f"cannot read {path}: {error}") from error
    entries: list[Entry] = []
    for lineno, raw in enumerate(text.split("\n"), 1):
        if not raw.strip():
            # The daemon terminates every line, so only the final split remainder is
            # empty. Conservation is over NON-BLANK lines: a blank line carries nothing.
            continue
        try:
            obj = json.loads(raw)
        except ValueError as error:
            raise DrainError(EXIT_FAIL, f"{path}:{lineno}: not JSON ({error})") from error
        problem = _entry_problem(obj)
        if problem:
            raise DrainError(EXIT_FAIL, f"{path}:{lineno}: {problem}")
        entries.append(Entry(lineno, raw, obj))
    return entries


def _entry_problem(obj: object) -> str:
    if not isinstance(obj, dict):
        return "not a JSON object"
    for key in ("ts", "kind", "ref"):
        if not isinstance(obj.get(key), str):
            return f"missing or non-string {key!r}"
    if not TS_RE.match(obj["ts"]):
        return f"ts {obj['ts']!r} is not YYYY-MM-DDTHH:MM:SSZ"
    results = obj.get("results")
    if not isinstance(results, list) or not all(isinstance(r, dict) for r in results):
        return "'results' is not a list of objects"
    for r in results:
        for key in ("model", "verdict", "critical"):
            if not isinstance(r.get(key), str):
                return f"a result lacks a string {key!r}"
    return ""


def render_md(entry: dict) -> str:
    """EXACTLY what `codex_watch._review` appends to advice.md for one entry.

    Copied from the daemon (`codex_watch.py`, the two `open("a")` blocks) rather than
    described: a regenerated advice.md must be byte-identical to what the daemon would
    have written for the same entries. Measured at draft time against the live file:
    783 entries, 561,198 characters, identical. Every template literal is pinned equal
    in both files by `test_watch_drain.py`, which now DERIVES the set from the daemon's
    own AST rather than listing it — §1966, after §1962 added a fourth line here and the
    three-literal list could not see it. A rotate would have regenerated advice.md
    without the notes, on exactly the ERROR ticks §1962 exists to make legible.

    ⚠ `r.get("note")`, not `r["note"]`: every entry written before §1962 lacks the key.
    """
    ts, kind, ref, results = entry["ts"], entry["kind"], entry["ref"], entry["results"]
    out = [f"\n## {ts} · {kind} · {ref}\n"]
    for r in results:
        out.append(f"- **{r['model']}**: {r['verdict']}\n")
        if r.get("resolved_model", r["model"]) != r["model"]:
            out.append(f"  - model: {r['resolved_model']}\n")
        if r.get("note"):
            out.append(f"  - note: {r['note']}\n")
        if r["critical"]:
            out.append(f"\n{r['critical']}\n")
    return "".join(out)


# ---------------------------------------------------------------------------
# RESOLVED.md
# ---------------------------------------------------------------------------


class Resolved:
    """The parsed ledger: cursor, rows keyed (ts, ref), and what could not be parsed."""

    def __init__(self) -> None:
        self.cursor: str | None = None  # None = no marker line at all
        self.rows: dict[tuple[str, str], str] = {}  # (ts, ref) -> status cell
        self.by_ts: dict[str, list[tuple[str, str]]] = {}  # ts -> [(ref, status)]
        #: §3102 — 1-based line of the row for each key, so `resolve` can REPLACE a
        #: non-discharging row instead of appending a second one for the same entry.
        self.row_lines: dict[tuple[str, str], int] = {}  # (ts, ref) -> lineno
        self.malformed: list[str] = []  # "<lineno>: <reason>"
        #: 1-based line number of the LAST line of the ledger table (its header when the
        #: table is empty), or None when no ledger header was found. `resolve` inserts
        #: after it — see the §2159 note below for why appending at EOF is not the same
        #: thing the moment anything is written under the table.
        self.table_end: int | None = None
        self.exists = False
        self.text = ""
        #: §2159 — table LINES present in a file whose ledger table this parser never
        #: found. Lines, not rows: in a schema this parser does not know, its header is
        #: indistinguishable from its data, and guessing would be the same overreach that
        #: produced the defect. The number is a floor on what went unseen, not a row count.
        #: NOT the same as `malformed`, which is a row inside a RECOGNISED table that failed
        #: validation: these are rows the parser walked straight past without noticing.
        self.unrecognised = 0

    def lookup(self, entry: Entry) -> str | None:
        """The row's status for this entry, or None. Exact `ref`, else a >=12-char
        prefix of it — the daemon's own `ref[:12]` shorthand, nothing shorter."""
        exact = self.rows.get((entry.ts, entry.ref))
        if exact is not None:
            return exact
        found = None
        for ref, status in self.by_ts.get(entry.ts, ()):
            if len(ref) >= MIN_REF_PREFIX and entry.ref.startswith(ref):
                found = status  # §3102 — LAST match, so this path agrees with the exact one
        return found


def read_resolved(path: Path) -> Resolved:
    res = Resolved()
    if not path.exists():
        return res
    res.exists = True
    try:
        res.text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise DrainError(EXIT_FAIL, f"cannot read {path}: {error}") from error
    markers = CURSOR_RE.findall(res.text)
    if len(markers) == 1:
        res.cursor = markers[0]
    elif len(markers) > 1:
        res.malformed.append(f"{len(markers)} drained-through markers (need exactly one)")
    # Only the table headed `| ts | ... |` is the ledger; any other table in the file
    # (the status vocabulary, say) is prose. A table ends at a blank or non-`|` line.
    in_table = False
    saw_ledger_header = False
    skipped_rows = 0
    for lineno, line in enumerate(res.text.split("\n"), 1):
        stripped = line.strip()
        if not stripped.startswith("|"):
            # ⚠ §3092 — AN INDENTED CONTINUATION IS INSIDE THE TABLE, NOT THE END OF IT.
            # This read `in_table = False` for any line not starting with `|`, and a
            # ledger row's evidence cell may span several lines whose continuations start
            # with SPACES. So the first multi-line row closed the table and every row
            # appended after it was walked past — well-formed, present in the file, and
            # absent from `res.rows`. Found by hitting it: `grep -c '^| 20'` said 429 and
            # this parser said 427, with `malformed=0` and `unrecognised=0`, so nothing
            # reported a problem. Only a BLANK line or prose at column 0 ends a table.
            if not stripped or not line[:1].isspace():
                in_table = False
            continue
        cells = row_cells(stripped)
        if cells and cells[0] == "ts":
            in_table = True
            saw_ledger_header = True
            res.table_end = lineno
            continue
        if in_table:
            # The separator and every row — malformed ones included, because a row this
            # parser rejected still OCCUPIES the table and an insert must land after it.
            res.table_end = lineno
        separator = bool(cells and cells[0] and set(cells[0]) <= {"-", ":"})
        if not in_table or separator:
            if not separator:
                skipped_rows += 1
            continue  # outside the ledger table / its separator row
        if len(cells) < 7:
            res.malformed.append(f"{lineno}: {len(cells)} cells, need 7 (ts kind ref model verdict status evidence)")
            continue
        ts, _kind, ref, _model, _verdict, status = cells[:6]
        if not TS_RE.match(ts):
            res.malformed.append(f"{lineno}: ts {ts!r} is not YYYY-MM-DDTHH:MM:SSZ")
            continue
        if not ref:
            res.malformed.append(f"{lineno}: empty ref")
            continue
        if not status.startswith(STATUS_VOCAB):
            res.malformed.append(f"{lineno}: status {status!r} not in {'/'.join(STATUS_VOCAB)}")
            continue
        res.rows[(ts, ref)] = status
        res.row_lines[(ts, ref)] = lineno
        # ⚠ §3102 — LAST WINS, matching `res.rows` one line above. This appended, and
        # `lookup`'s prefix path then returned the FIRST match while the exact path
        # returned the LAST — the two disagreed for any duplicated key. Nothing had
        # ever exercised it (the live ledger carries 489 rows and zero duplicate keys),
        # and `resolve` replacing in place keeps it that way; the ordering is made
        # consistent anyway, because a HAND-written duplicate is still reachable.
        res.by_ts.setdefault(ts, [])
        res.by_ts[ts] = [(r, s) for r, s in res.by_ts[ts] if r != ref] + [(ref, status)]
    # ⚠ §2159 — A TOOL'S ZERO IS A STATEMENT ABOUT THE TOOL'S UNIVERSE (§703), and this
    # parser reported one as a fact about a colleague's repo. `in_table` turns on only at a
    # row whose first cell is literally `ts`; epstein-drive's RESOLVED.md is headed
    # `| Log line | Commit | Finding | Status |`, so the header never matched, all 24 of its
    # rows were walked past, and `malformed` stayed EMPTY because nothing had entered a
    # recognised table to fail validation. `status` then printed
    # `resolved_md=present resolved_rows=0`, which is true of the parser and false of the
    # file — and a hand-off written on 2026-09-13 read it as "nobody has ever read this
    # ledger" about an 11 KB reconciliation index its owner had maintained since 2026-08-26.
    #
    # Only when NO ledger header was found anywhere: athena's own file carries other tables
    # (the status vocabulary) whose rows are legitimately outside the ledger, and counting
    # those would make this fire on every healthy repo.
    if not saw_ledger_header:
        res.unrecognised = skipped_rows
    return res


def _set_cursor(text: str, through: str) -> str:
    new, n = CURSOR_RE.subn(f"<!-- drained-through: {through} -->", text, count=1)
    if n != 1:
        raise DrainError(EXIT_FAIL, f"{RESOLVED_MD}: no `<!-- drained-through: ... -->` marker to update")
    return new


# ---------------------------------------------------------------------------
# locks + the daemon
# ---------------------------------------------------------------------------


@contextlib.contextmanager
def advice_lock(advice_dir: Path, timeout: float) -> Iterator[None]:
    """`flock(LOCK_EX)` on `<advice_dir>/.advice.lock`, polled non-blocking until
    `timeout` seconds have passed (0 = exactly one try). O_RDONLY|O_CREAT so the file
    a different user created is still lockable (flock ignores the open mode)."""
    lock_path = advice_dir / ADVICE_LOCK
    try:
        fd = os.open(lock_path, os.O_RDONLY | os.O_CREAT, 0o644)
    except OSError as error:
        raise DrainError(EXIT_FAIL, f"cannot open {lock_path}: {error}") from error
    deadline = time.monotonic() + max(0.0, timeout)
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
                    raise DrainError(EXIT_FAIL, f"cannot lock {lock_path}: {error}") from error
                if time.monotonic() >= deadline:
                    raise DrainError(
                        EXIT_LOCK_TIMEOUT,
                        f"{lock_path} still held after {timeout:g}s (the daemon appends under "
                        "it; retry, or raise --lock-timeout)",
                    ) from None
                time.sleep(LOCK_POLL_SECONDS)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _holder_pid(lock_path: Path) -> int | None:
    try:
        head = lock_path.read_text(encoding="utf-8", errors="replace").split()
    except OSError:
        return None
    if not head or not head[0].isdigit():
        return None
    return int(head[0])


def _holder_kind(pid: int | None) -> str:
    """"once" | "daemon" | "?" — what KIND of process holds the watch lock.

    ⚠ §2183 — "LOCK HELD" STOPPED MEANING "A DAEMON IS UP" AT §2109 and nothing noticed.
    Review is dispatched by hooks now: `codex_watch.py --once --since-ledger` runs, takes
    this lock for ~150s, and exits. So a held lock means "a review happens to be running
    this second" and a free lock is the NORMAL, healthy, idle state — while the banner
    read them as "daemon up" and "⚠ DAEMON NOT RUNNING". Measured on this checkout inside
    one minute: three session-start fires said `daemon up` and one said `DAEMON NOT
    RUNNING`, with nothing wrong either time.

    The two are distinguishable exactly: `--once` is in the argv. `/proc/<pid>/cmdline` is
    world-readable (verified from `slava3` against a root-owned and a `slava`-owned
    process on this box), which matters because the lock holder is routinely another UNIX
    user on a checkout three sessions share.

    "?" — not Linux, the process exited between the flock probe and this read, or the
    argv is unreadable. Never guessed as either kind: the deliberate `--interval` daemon
    still exists and its stale-code warning applies only to it.
    """
    if pid is None:
        return "?"
    try:
        argv = Path(f"/proc/{pid}/cmdline").read_bytes().decode("utf-8", "replace")
    except OSError:
        return "?"
    if not argv:
        return "?"

    return "once" if "--once" in argv.split("\0") else "daemon"


def _proc_start_epoch(pid: int) -> float | None:
    """When `pid` started, from /proc: btime + starttime/CLK_TCK. None when unreadable."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="ascii", errors="replace")
        # `comm` (field 2) is parenthesised and may contain spaces; fields resume after
        # the LAST ')' with state (field 3), so starttime (field 22) is index 19 there.
        rest = stat[stat.rindex(")") + 2 :].split()
        ticks = int(rest[19])
        btime = next(
            int(line.split()[1])
            for line in Path("/proc/stat").read_text(encoding="ascii").splitlines()
            if line.startswith("btime ")
        )
    except (OSError, ValueError, IndexError, StopIteration):
        return None
    return btime + ticks / os.sysconf("SC_CLK_TCK")


def daemon_state(advice_dir: Path, watch_script: Path) -> dict:
    """What holds `.watch.lock`, when it started, and whether it predates `watch_script`.

    `held` is decided by a non-blocking flock probe (released at once), never by the
    pid file alone — the lock file outlives every daemon and keeps its last pid.
    """
    state: dict = {
        "lock": "absent", "pid": None, "start": None, "script_mtime": None,
        "stale": None, "reason": "", "holder": "?",
    }
    lock_path = advice_dir / WATCH_LOCK
    if not lock_path.exists():
        return state
    try:
        fd = os.open(lock_path, os.O_RDONLY)
    except OSError as error:
        state.update(lock="unreadable", stale=None, reason=f"cannot open {lock_path}: {error}")
        return state
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            state["lock"] = "held"
        else:
            fcntl.flock(fd, fcntl.LOCK_UN)
            state["lock"] = "free"
            return state
    finally:
        os.close(fd)
    pid = _holder_pid(lock_path)
    state["pid"] = pid
    state["holder"] = _holder_kind(pid)
    try:
        state["script_mtime"] = watch_script.stat().st_mtime
    except OSError as error:
        state.update(reason=f"cannot stat {watch_script}: {error}")
        return state
    injected = os.environ.get(ENV_HOLDER_START, "")
    if injected:
        try:
            state["start"] = float(injected)
        except ValueError:
            state.update(reason=f"{ENV_HOLDER_START}={injected!r} is not a number")
            return state
    elif pid is None:
        state.update(reason=f"{lock_path} holds no pid to inspect")
        return state
    else:
        state["start"] = _proc_start_epoch(pid)
        if state["start"] is None:
            state.update(reason=f"cannot read /proc/{pid}/stat for the holder's start time")
            return state
    state["stale"] = state["start"] < state["script_mtime"]
    return state


def check_daemon(advice_dir: Path, watch_script: Path) -> dict:
    """Raise EXIT_STALE_DAEMON when a running daemon predates the installed script — or
    when that cannot be determined: an unknown holder is treated as a pre-lock one."""
    state = daemon_state(advice_dir, watch_script)
    if state["lock"] in ("absent", "free"):
        return state
    if state["stale"] is None:
        raise DrainError(
            EXIT_STALE_DAEMON,
            f"{WATCH_LOCK} is held but the holder cannot be aged ({state['reason']}); "
            "restart the watch daemon first",
        )
    if state["stale"]:
        raise DrainError(
            EXIT_STALE_DAEMON,
            f"the watch daemon (pid {state['pid']}, started {_fmt_epoch(state['start'])}) "
            f"predates {watch_script} (written {_fmt_epoch(state['script_mtime'])}) and so "
            f"never takes {ADVICE_LOCK}; restart the watch daemon first",
        )
    return state


# ---------------------------------------------------------------------------
# git (for `list --paths`)
# ---------------------------------------------------------------------------


#: §3129 (§1.93 leg 1) — EVERY ledger ref is hex: a commit sha, or a worktree content hash
#: (sha1 of the diff). `advice.jsonl` is tracked and model-derived, so a ref is untrusted
#: text, and a ref starting with `-` reaches git's argv as an OPTION — `--output=<path>` made
#: `git show` and `git log` each CREATE a file (reproduced 2026-09-22, eugo-ray-meson's
#: hand-off and again here). Anything not hex is refused before git runs, and every git call
#: that takes a ledger ref also carries `--end-of-options` (a bare `--` would turn the ref
#: into a pathspec). MIRRORED in codex_watch.py and the turn-end hook, pinned by tests.
_HEX_REF = re.compile(r"[0-9a-f]{7,64}")


def is_hex_ref(ref: object) -> bool:
    """§3129 — True only for a string that can be a ledger ref: 7-64 lowercase hex digits."""
    return isinstance(ref, str) and _HEX_REF.fullmatch(ref) is not None


def changed_paths(repo: str, ref: str) -> list[str] | None:
    """Paths a commit touched, or None when git cannot resolve it in `repo`.
    `--first-parent` so a merge commit lists what it brought in (a plain
    `git show --name-only` prints nothing for a merge). §3129 — None for a non-hex ref."""
    if not is_hex_ref(ref):
        return None
    try:
        out = subprocess.run(
            ["git", "show", "--name-only", "--format=", "--first-parent", "--end-of-options", ref],
            cwd=repo, capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return [line for line in out.stdout.splitlines() if line.strip()]


def path_matches(path: str, specs: list[str]) -> bool:
    for spec in specs:
        spec = spec.rstrip("/") or spec
        if path == spec or path.startswith(spec + "/") or fnmatch.fnmatchcase(path, spec):
            return True
    return False


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------


def _require_dir(advice_dir: Path) -> None:
    if not advice_dir.is_dir():
        raise DrainError(EXIT_FAIL, f"advice dir not found: {advice_dir}")


def _archive_counts(advice_dir: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    root = advice_dir / ARCHIVE_DIR
    if not root.is_dir():
        return counts
    for f in sorted(root.glob("*.jsonl")):
        try:
            counts[f.name] = sum(1 for line in f.read_text(encoding="utf-8").split("\n") if line.strip())
        except OSError:
            counts[f.name] = -1
    return counts


def cmd_status(args: argparse.Namespace, advice_dir: Path) -> int:
    _require_dir(advice_dir)
    entries = load_entries(advice_dir / ADVICE_JSONL)
    resolved = read_resolved(advice_dir / RESOLVED_MD)
    tally = {"APPROVED": 0, "NEEDS_REVISION": 0, "ERROR": 0}
    other = no_result = 0
    for e in entries:
        vs = e.verdicts
        if not vs:
            no_result += 1
        for v in vs:
            if v in tally:
                tally[v] += 1
            else:
                other += 1
    owed = [e for e in entries if e.owed]
    # §3108 — `hides`, not `discharges`: a live claim takes an entry off the QUEUE without
    # closing it. `rotate` below deliberately keeps asking `discharges`.
    unresolved = [e for e in owed if not hides(resolved.lookup(e))]
    claimed = sum(1 for e in owed if claim_is_live(resolved.lookup(e)))
    down_unresolved = sum(1 for e in unresolved if account_is_down(e.obj))
    # §3043 — who wrote each entry, and whose entries carry an ERROR verdict.
    # §3103 — how many DISTINCT sessions this ledger holds, and how many entries carry no
    # session at all. The second number is the one that matters while the stamp rolls out:
    # an entry with no owner is one every session still sees.
    sessions = {e.session for e in entries if e.session}
    unowned = sum(1 for e in entries if not e.session)
    unowned_owed = sum(1 for e in owed if not e.session)
    writers = {w: 0 for w in (*WRITERS, "unknown")}
    writer_errors = {w: 0 for w in (*WRITERS, "unknown")}
    for e in entries:
        w = e.obj.get("writer")
        key = w if w in WRITERS else "unknown"
        writers[key] += 1
        if "ERROR" in e.verdicts:
            writer_errors[key] += 1
    months: dict[str, int] = {}
    for e in entries:
        months[e.month] = months.get(e.month, 0) + 1
    # §3118 — which model ACTUALLY reviewed: the exact id when recorded, else the settings
    # value marked `(unrecorded)` (every entry before §3118, and any run that could not tell).
    reviewers: dict[str, int] = {}
    for e in entries:
        for r in e.obj.get("results") or []:
            if isinstance(r, dict):
                key = r.get("resolved_model") or f"{r.get('model', '?')}(unrecorded)"
                reviewers[key] = reviewers.get(key, 0) + 1
    out = [
        f"advice_dir={advice_dir}",
        f"entries={len(entries)}",
        f"approved={tally['APPROVED']} needs_revision={tally['NEEDS_REVISION']} error={tally['ERROR']} "
        f"other_verdicts={other} no_result={no_result}",
        # §3122 (§1.88) — the HONEST headline beside the two it refines: an unresolved entry
        # whose note is an account outage is a review that never happened, not a finding.
        # Counted over `unresolved` (claims already hidden), so work + account_down ==
        # unresolved always; `owed`/`unresolved` keep their meaning for every other reader.
        f"owed={len(owed)} unresolved={len(unresolved)} unresolved_work={len(unresolved) - down_unresolved} "
        f"unresolved_account_down={down_unresolved}",
        # §3122 — a persisted quota hold is invisible otherwise: reviewing is paused until it.
        f"account_hold_until={account_hold_until(advice_dir)}",
        f"sessions={len(sessions)} unowned={unowned} unowned_owed={unowned_owed}",
        # §3108 — claimed entries are HIDDEN from `unresolved`, so without this line the
        # queue would appear to shrink with no account of where the work went.
        f"claimed={claimed} claim_ttl_h={CLAIM_TTL_SECONDS // 3600}",
        # §3046 — informational: how many owed entries are an account outage, not a finding.
        f"owed_account_down={sum(1 for e in owed if account_is_down(e.obj))}",
        f"abandoned={_abandoned_count(advice_dir)} "
        f"unreviewable={_unreviewable_count(advice_dir)}",
        # §2183 — is review WIRED, and is anything UNREVIEWED. The two questions the
        # session banner was reaching for when it reported daemon liveness from a lock.
        # §2918 — `--repo`, not the advice dir's grandparent, which is the repo root only at
        # the default `--advice-dir` depth.
        f"review_wired={review_wired(Path(args.repo))} "
        f"unreviewed={unreviewed_count(Path(args.repo), advice_dir)} "
        # §3109 — the AGE beside the depth. Six queued commits from the last ten minutes
        # and six waiting since yesterday print the same depth and mean opposite things.
        f"unreviewed_oldest_h={unreviewed_oldest_h(Path(args.repo), advice_dir)} "
        # §2189 — the depth the cure needs, so the banner names a command that reaches
        # what it counts. Empty when nothing is stuck, which is the common path.
        f"retry_scan={retry_scan_depth(advice_dir, Path(args.repo))}",
        # §3067 — the boundary, the exclusion and the budget the next dispatch will honour.
        selection_fields(Path(args.repo), advice_dir),
        f"resolved_md={'present' if resolved.exists else 'absent'} resolved_rows={len(resolved.rows)}"
        + (f" ⚠ UNRECOGNISED: {resolved.unrecognised} table line(s) this parser could not see "
           f"(a different RESOLVED.md schema) — resolved_rows=0 describes THIS PARSER, not the file"
           if resolved.unrecognised else "") + " "
        f"malformed_rows={len(resolved.malformed)}",
        f"cursor={resolved.cursor if resolved.cursor is not None else '(no marker)'}",
        f"ts_min={min(e.ts for e in entries) if entries else '-'} "
        f"ts_max={max(e.ts for e in entries) if entries else '-'}",
        "months=" + (",".join(f"{m}:{n}" for m, n in sorted(months.items())) or "-"),
        "reviewers=" + (",".join(f"{k}:{n}" for k, n in sorted(reviewers.items())) or "-"),
        "archive=" + (",".join(f"{k}:{v}" for k, v in _archive_counts(advice_dir).items()) or "-"),
        "writers=" + ",".join(f"{k}:{v}" for k, v in writers.items()),
        "writer_errors=" + ",".join(f"{k}:{v}" for k, v in writer_errors.items()),
    ]
    lock_path = advice_dir / ADVICE_LOCK
    if lock_path.exists():
        try:
            with advice_lock(advice_dir, 0):
                out.append("advice_lock=free")
        except DrainError as error:
            out.append("advice_lock=held" if error.code == EXIT_LOCK_TIMEOUT else f"advice_lock=? ({error})")
    else:
        out.append("advice_lock=absent")
    st = daemon_state(advice_dir, Path(args.watch_script))
    line = f"watch_lock={st['lock']}"
    if st["lock"] == "held":
        start = _fmt_epoch(st["start"]) if st["start"] is not None else "?"
        mtime = _fmt_epoch(st["script_mtime"]) if st["script_mtime"] is not None else "?"
        stale = {True: "yes", False: "no", None: "unknown"}[st["stale"]]
        line += (f" pid={st['pid']} holder={st['holder']} start={start} "
                 f"script_mtime={mtime} stale={stale}")
        if st["reason"]:
            line += f" ({st['reason']})"
    out.append(line)
    for m in resolved.malformed:
        out.append(f"malformed_row={m}")
    print("\n".join(out))
    return EXIT_OK


def cmd_list(args: argparse.Namespace, advice_dir: Path) -> int:
    _require_dir(advice_dir)
    entries = load_entries(advice_dir / ADVICE_JSONL)
    resolved = read_resolved(advice_dir / RESOLVED_MD)
    if args.after_cursor:
        if resolved.cursor is None and resolved.exists:
            raise DrainError(EXIT_FAIL, f"{RESOLVED_MD} has no `<!-- drained-through: ... -->` marker")
        if resolved.cursor not in (None, CURSOR_NONE):
            # §2918 — keyed on when an entry became visible, not when its review started.
            entries = [e for e in entries if e.visible_at > _pad(resolved.cursor)]
    if args.verdict:
        wanted = {v.strip() for v in args.verdict.split(",") if v.strip()}
        entries = [e for e in entries if wanted & set(e.verdicts)]
    if args.unresolved:
        # §3108 — a live claim hides an entry from the queue without closing it.
        entries = [e for e in entries if e.owed and not hides(resolved.lookup(e))]
    if args.mine:
        # ⚠ §3103 — `--mine` WITH NO SESSION MATCHES NOTHING, NEVER EVERYTHING. Written as
        # `want = env.get(...)` and then `if want:`, an unset variable falls through to no
        # filter at all and the command returns the whole queue — which is how a session
        # ends up working a peer's findings while believing it is scoped. Asking to see only
        # your own and being handed everyone's is the failure this flag exists to prevent.
        # §3106 — through `owns`, which encodes that same rule: an empty side never
        # matches. The filter reads as the question it answers, and the definition lives
        # in one place that the turn-end hook imports rather than re-deriving.
        mine = os.environ.get(SESSION_ENV, "").strip()
        entries = [e for e in entries if owns(e.session, mine)]
    elif args.session:
        # `none` is a real query ("what carries no owner?"), not a missing argument — and
        # it is the one question `owns` cannot express, by construction.
        entries = [e for e in entries
                   if (e.session == "" if args.session == "none" else owns(e.session, args.session))]
    unresolvable = 0
    for e in entries:
        obj = e.obj
        if args.paths:
            if e.kind != "commit":
                continue
            paths = changed_paths(args.repo, e.ref)
            if paths is None:
                unresolvable += 1
                continue
            hit = [p for p in paths if path_matches(p, args.paths)]
            if not hit:
                continue
            obj = dict(obj, matched_paths=hit)
        print(json.dumps(obj))
    if unresolvable:
        print(f"list: {unresolvable} commit ref(s) not resolvable in {args.repo} — excluded",
              file=sys.stderr)
    return EXIT_OK


class _Staged:
    """Temp files written next to their targets; renamed together or removed together."""

    def __init__(self) -> None:
        self.pending: list[tuple[Path, Path]] = []  # (tmp, target)

    def write(self, target: Path, text: str, mode: int) -> Path:
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".tmp", dir=target.parent)
        tmp = Path(tmp_name)
        self.pending.append((tmp, target))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        return tmp

    def commit(self) -> None:
        for tmp, target in self.pending:
            os.replace(tmp, target)
        self.pending.clear()

    def discard(self) -> None:
        for tmp, _target in self.pending:
            with contextlib.suppress(OSError):
                tmp.unlink()
        self.pending.clear()


def _mode_of(path: Path, default: int = 0o664) -> int:
    """Keep the target's mode so the daemon (another user, same group) can still append."""
    try:
        return path.stat().st_mode & 0o777
    except OSError:
        return default


# ---------------------------------------------------------------------------
# resolve — the ledger's write path
# ---------------------------------------------------------------------------


def _cell(text: object) -> str:
    """One GFM table cell: whitespace flattened, `|` escaped the way `row_cells` reads it.

    ⚠ A cell is ONE LINE, and `row_cells` splits on every UNESCAPED `|`. An evidence
    sentence carrying a raw pipe would shift every cell after it — the §2180 divergence,
    committed by the writer instead of tripped over by the reader. Idempotent: an input
    that already spells `\\|` is normalised first, so escaping twice is a no-op rather
    than a `\\\\|` the reader would split on.
    """
    flat = " ".join(str(text).split())

    return flat.replace(r"\|", "|").replace("|", r"\|")


def parse_status(raw: str) -> str:
    """The status cell, validated STRICTER than `read_resolved` reads it.

    The reader asks `status.startswith(STATUS_VOCAB)`, which accepts `FIXEDLY` and
    `OPENING`. A writer may only emit what the vocabulary actually means, so the FIRST
    WHITESPACE-SEPARATED TOKEN must be a vocabulary word exactly — `FIXED b808e4893f`
    and `OPEN -> FUTURE F123` pass, `FIXEDLY` does not. Stricter than the reader is the
    safe direction: every row this emits is one the reader classifies.
    """
    cell = _cell(raw)
    if not cell:
        raise DrainError(EXIT_FAIL, "--status is empty")
    head = cell.split()[0]
    if head not in STATUS_VOCAB:
        raise DrainError(
            EXIT_FAIL,
            f"--status {raw!r} starts with {head!r}, which is not one of "
            f"{'/'.join(STATUS_VOCAB)}; a row the reader cannot classify is worse than no row",
        )

    return cell


def select_by_ref(entries: list[Entry], ref: str, ts: str = "") -> list[Entry]:
    """Entries this `--ref` identifies — exact, else a >=12-char prefix.

    The MIRROR of `Resolved.lookup`, which matches when `entry.ref.startswith(row_ref)`
    and the row's ref is at least `MIN_REF_PREFIX` long. A shorter ref still matches
    EXACTLY, because `wt@2` is a real ref and four characters long.
    """
    ref = ref.strip()
    if not ref:
        raise DrainError(EXIT_FAIL, "--ref is empty")
    hits = [e for e in entries
            if e.ref == ref or (len(ref) >= MIN_REF_PREFIX and e.ref.startswith(ref))]
    if ts:
        hits = [e for e in hits if e.ts == ts]

    return hits


def primary_verdict(entry: Entry) -> str:
    r"""The ONE verdict word the row carries: the first OWED one, else the first.

    ⚠ ONE WORD, NOT THE SET, AND THAT IS A CONTRACT WITH AN EXISTING GATE rather than a
    style choice. `test_no_resolved_row_claims_a_verdict_its_ledger_entry_does_not_carry`
    (§2169) reads rows with `^\| (\S+) \| (\w+) \| ([0-9a-f]{12,40}) \| \w+ \| (\w+) \|` and
    asserts the verdict cell is one the entry carries. `\w+` matches no comma, so a cell
    spelling the whole set is not FAILED by that gate — it is SKIPPED, silently, and the
    row leaves the population the gate exists to police. Measured at §3070 on a real
    12-result entry (`eac712233616` 05:53:45Z): the comma form was skipped while the
    one-word form was matched.

    The OWED verdict first, because that is the verdict the row is a disposition OF: an
    8-result review spanning APPROVED/NEEDS_REVISION/ERROR is in this ledger because of
    the NEEDS_REVISION, and `APPROVED` in the cell would key the disposition to the half
    that needed none. Ties inside the owed set go to appearance order — deterministic, and
    the rest of the picture is one `list --verdict` away.
    """
    verdicts = entry.verdicts
    for v in verdicts:
        if v in OWED_VERDICTS:
            return v

    return verdicts[0] if verdicts else "?"


def format_row(entry: Entry, status: str, evidence: str) -> str:
    """The ledger row for one entry: 7 cells, five of them DERIVED.

    `ts`/`kind`/`ref`/`model`/`verdict` come from the entry, never from the caller —
    `lookup` keys on `(ts, ref)`, so a caller-supplied ts could silently key a row to an
    entry that does not exist, which is §2169's defect handed a tool to repeat it with.
    `model` is the entry's models deduped in first-appearance order (one word on every
    entry measured here); `verdict` is `primary_verdict`, one word by contract.
    """
    models: list[str] = []
    for r in entry.obj["results"]:
        model = str(r.get("model", "?"))
        if model not in models:
            models.append(model)

    return (f"| {entry.ts} | {_cell(entry.kind)} | {_cell(entry.ref)} | {_cell(','.join(models))} "
            f"| {_cell(primary_verdict(entry))} | {status} | {evidence} |")


def replace_row(text: str, lineno: int, row: str) -> str:
    """`row` REPLACES line `lineno` (1-based).

    §3102 — `resolve` over a non-discharging row rewrites it rather than appending a second
    row for the same `(ts, ref)`. One row per entry keeps every consumer simple — `rotate`'s
    counts, the §2169 verdict gate, and both `lookup` paths — and the previous status is not
    lost: `RESOLVED.md` is tracked, so `git log -p` carries the OPEN -> FIXED transition.
    """
    lines = text.split("\n")
    if not 1 <= lineno <= len(lines):
        raise ValueError(f"line {lineno} is outside the file ({len(lines)} lines)")
    lines[lineno - 1] = row
    return "\n".join(lines)


def insert_row(text: str, table_end: int, row: str) -> str:
    """`row` placed immediately after line `table_end` (1-based), inside the table."""
    lines = text.split("\n")
    lines.insert(table_end, row)

    return "\n".join(lines)


def cmd_resolve(args: argparse.Namespace, advice_dir: Path) -> int:
    _require_dir(advice_dir)
    status = parse_status(args.status)
    evidence = _cell(args.evidence)
    if not evidence:
        raise DrainError(EXIT_FAIL, "--evidence is empty; a row nobody can audit is not a disposition")
    # The lock serialises this read-modify-write against `rotate`'s cursor write and
    # against another `resolve`. It does NOT need `check_daemon`: advice.jsonl is only
    # READ here, so a daemon appending underneath can lose nothing.
    with advice_lock(advice_dir, args.lock_timeout):
        entries = load_entries(advice_dir / ADVICE_JSONL)
        resolved_path = advice_dir / RESOLVED_MD
        resolved = read_resolved(resolved_path)
        if not resolved.exists:
            raise DrainError(EXIT_FAIL, f"{resolved_path} absent — seed the ledger first")
        if resolved.table_end is None:
            raise DrainError(
                EXIT_FAIL,
                f"{resolved_path} has no ledger table headed `| ts | kind | ref | model | verdict | "
                f"status | evidence |` ({resolved.unrecognised} unrecognised table line(s)); this "
                "writer will not invent a schema for a file it cannot read (§2159)",
            )
        hits = select_by_ref(entries, args.ref, args.ts)
        if not hits:
            where = f" at ts {args.ts}" if args.ts else ""
            raise DrainError(
                EXIT_FAIL,
                f"--ref {args.ref!r} matches no entry in {advice_dir / ADVICE_JSONL}{where}; "
                "a row for a finding that does not exist is worse than no row",
            )
        if len(hits) > 1:
            lines = [f"  --ts {e.ts}  {e.kind} · {e.ref} · {','.join(e.verdicts)}" for e in hits[:20]]
            more = f"\n  ... {len(hits) - 20} more" if len(hits) > 20 else ""
            raise DrainError(
                EXIT_FAIL,
                f"--ref {args.ref!r} matches {len(hits)} entries; refusing rather than picking one "
                "(they are distinct findings and one evidence sentence cannot speak for both). "
                "Re-run once per entry with --ts:\n" + "\n".join(lines) + more,
            )
        entry = hits[0]
        already = resolved.lookup(entry)
        # ⚠ §3102 — IDEMPOTENT ONLY WHEN THE EXISTING ROW ACTUALLY CLOSED THE ENTRY. This
        # read `if already is not None`, so ANY row was terminal — and an `OPEN` row is not a
        # closure, it is a record that somebody looked and left the finding live. A later
        # session that HAD the fix got `unchanged … already resolved: OPEN` at exit 0 and no
        # way to say so. So today `OPEN` did not mean "still live", it meant "closed,
        # silently, forever" — the write-path half of the same defect the read paths carried.
        if discharges(already):
            print(f"unchanged {entry.ts} · {entry.ref} already resolved: {already}")
            return EXIT_OK
        return _write_status_row(resolved, resolved_path, entry, status, evidence,
                                 already, args.dry_run, verb="resolved")


def _write_status_row(resolved: Resolved, resolved_path: Path, entry, status: str,
                      evidence: str, already: str | None, dry_run: bool,
                      *, verb: str) -> int:
    """Write one status row for `entry`, replacing a non-discharging row in place.

    §3108 — EXTRACTED so `claim` and `resolve` share ONE copy. They differ only in what
    they refuse BEFORE this point; everything from here — the replace-vs-insert decision,
    the staged write, and the four on-disk assertions that re-read the file with this
    module's own parser — is identical, and a second copy of it is how the predicate
    defects of §3094 / §3102 / §3104 / §3107 each happened. The caller holds the lock.
    """
    if resolved.table_end is None:
        # Both callers check this before taking the lock; asserted again because this
        # function is the only thing that WRITES, and an insert at `None` is a crash
        # inside a staged write rather than a refusal the operator can read.
        raise DrainError(EXIT_FAIL, "refusing: no ledger table to write into (§2159)")
    row = format_row(entry, status, evidence)
    # REPLACE a non-discharging row rather than appending a second one for the same key:
    # one row per entry keeps `rotate`, the §2169 gate and both `lookup` paths simple, and
    # the OPEN -> FIXED transition survives in the tracked file's git history.
    replacing = resolved.row_lines.get((entry.ts, entry.ref)) if already is not None else None
    if dry_run:
        where = (f"dry-run replace {resolved_path}:{replacing} (was {already!r})" if replacing
                 else f"dry-run insert after {resolved_path}:{resolved.table_end}")
        print(f"{where}\n{row}")
        return EXIT_OK
    staged = _Staged()
    try:
        tmp = staged.write(
            resolved_path,
            replace_row(resolved.text, replacing, row) if replacing
            else insert_row(resolved.text, resolved.table_end, row),
            _mode_of(resolved_path),
        )
        # THE CONTRACT, CHECKED ON DISK: a writer whose rows the reader drops is the
        # whole defect this subcommand exists to end, so it is asserted here rather
        # than left to a test. Re-read the staged file with this file's own reader.
        after = read_resolved(tmp)
        if after.malformed:
            raise DrainError(EXIT_FAIL,
                             "refusing: the row written is unparseable — " + "; ".join(after.malformed[:5]))
        # §3102 — an INSERT adds a key, a REPLACE rewrites one in place. This asserted
        # +1 unconditionally, which would have refused every replace with a message about
        # a count the operation never intended to change.
        want = len(resolved.rows) + (0 if replacing else 1)
        if len(after.rows) != want:
            raise DrainError(EXIT_FAIL,
                             f"refusing: rows went {len(resolved.rows)} -> {len(after.rows)}, "
                             f"expected {want} ({'replace' if replacing else 'insert'})")
        back = after.lookup(entry)
        if back != status:
            raise DrainError(EXIT_FAIL,
                             f"refusing: the reader resolves this entry to {back!r}, not {status!r}")
        if after.cursor != resolved.cursor:
            raise DrainError(EXIT_FAIL,
                             f"refusing: the drained-through cursor moved {resolved.cursor!r} -> "
                             f"{after.cursor!r}; {verb} never moves it")
        staged.commit()
    except OSError as error:
        staged.discard()
        raise DrainError(EXIT_FAIL, f"write failed, nothing renamed: {error}") from error
    except DrainError:
        staged.discard()
        raise
    print(f"{verb} {entry.ts} · {entry.ref} · {status}")
    return EXIT_OK


def cmd_claim(args: argparse.Namespace, advice_dir: Path) -> int:
    """§3108 (§1.85 cure 2) — take an UNOWNED finding so peers stop seeing it.

    The owner column (§3103) answers "whose was this?" only for entries stamped since it
    existed. The 820 that predate it, and every entry whose dispatching session is long
    gone, are owned by nobody — and `owns` deliberately refuses to hand those to whoever
    starts next. A claim is how one of those gets picked up on purpose.

    It EXPIRES, and that is the whole safety property: §1.85's warning is that stale
    claims become the next backlog, so a session that dies holding one must not park the
    finding forever. Hard expiry, no renewal — see CLAIM_TTL_SECONDS for the ruling.
    """
    _require_dir(advice_dir)
    me = resolve_session_for_claim(args)
    if not me:
        raise DrainError(
            EXIT_FAIL,
            f"no session id: set ${SESSION_ENV} or pass --as. A claim names WHO holds the "
            "finding, and an anonymous one cannot be released, audited, or told apart "
            "from a second anonymous claim.",
        )
    with advice_lock(advice_dir, args.lock_timeout):
        entries = load_entries(advice_dir / ADVICE_JSONL)
        resolved_path = advice_dir / RESOLVED_MD
        resolved = read_resolved(resolved_path)
        if not resolved.exists or resolved.table_end is None:
            raise DrainError(EXIT_FAIL,
                             f"{resolved_path} has no ledger table to claim in (§2159)")
        hits = select_by_ref(entries, args.ref, args.ts)
        if not hits:
            raise DrainError(EXIT_FAIL, f"--ref {args.ref!r} matches no entry")
        if len(hits) > 1:
            lines = [f"  --ts {e.ts}  {e.kind} · {e.ref}" for e in hits[:20]]
            raise DrainError(EXIT_FAIL,
                             f"--ref {args.ref!r} matches {len(hits)} entries; re-run with "
                             "--ts:\n" + "\n".join(lines))
        entry = hits[0]
        already = resolved.lookup(entry)
        if discharges(already):
            print(f"unchanged {entry.ts} · {entry.ref} already resolved: {already}")
            return EXIT_OK
        held = parse_claim(already)
        if held is not None and claim_is_live(already):
            who, at = held
            if not owns(who, me):
                # ANOTHER session holds it and the claim is still live. Refusing is the
                # point: two sessions fixing one finding is the collision this subcommand
                # exists to prevent. The expiry is printed so the caller knows the wait is
                # bounded rather than indefinite.
                left = (at + CLAIM_TTL_SECONDS - time.time()) / 3600.0
                raise DrainError(
                    EXIT_FAIL,
                    f"{entry.ref[:12]} is claimed by {who} for another {left:.1f}h "
                    f"({already!r}). Claims expire — they are never permanent — so either "
                    "wait, or resolve it directly if you have the fix.",
                )
            # Our own live claim: a no-op rather than a refresh, because refreshing on
            # re-claim is the renewal the operator ruled against (CLAIM_TTL_SECONDS).
            print(f"unchanged {entry.ts} · {entry.ref} already yours: {already}")
            return EXIT_OK
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        status = f"CLAIMED {me} {stamp}"
        evidence = _cell(args.note) or (
            f"claimed for up to {CLAIM_TTL_SECONDS // 3600}h; it returns to the queue "
            "automatically if no disposition is written by then")
        return _write_status_row(resolved, resolved_path, entry, status, evidence,
                                 already, args.dry_run, verb="claimed")


def resolve_session_for_claim(args: argparse.Namespace) -> str:
    """`--as` beats the environment; both are trimmed, and `|` can never enter a cell."""
    raw = (getattr(args, "as_session", "") or os.environ.get(SESSION_ENV, "") or "").strip()
    return "".join(c for c in raw if c.isprintable() and c != "|")[:128]


def cmd_rotate(args: argparse.Namespace, advice_dir: Path) -> int:
    _require_dir(advice_dir)
    through = parse_through(args.through)
    with advice_lock(advice_dir, args.lock_timeout):
        check_daemon(advice_dir, Path(args.watch_script))
        jsonl = advice_dir / ADVICE_JSONL
        if not jsonl.exists():
            raise DrainError(EXIT_FAIL, f"nothing to rotate: {jsonl} absent")
        entries = load_entries(jsonl)
        resolved_path = advice_dir / RESOLVED_MD
        resolved = read_resolved(resolved_path)
        if not resolved.exists:
            raise DrainError(EXIT_FAIL, f"{resolved_path} absent — seed the ledger first")
        if resolved.cursor is None:
            raise DrainError(EXIT_FAIL, f"{resolved_path} has no `<!-- drained-through: ... -->` marker")
        if resolved.cursor != CURSOR_NONE and through < resolved.cursor:
            raise DrainError(
                EXIT_FAIL, f"--through {through} is before the cursor {resolved.cursor}; nothing written"
            )
        if resolved.malformed:
            raise DrainError(
                EXIT_UNRESOLVED,
                f"{resolved_path} has {len(resolved.malformed)} unparseable row(s); fix them first:\n  "
                + "\n  ".join(resolved.malformed[:50]),
            )

        # §2918 — partition on `visible_at`, the same key `list --after-cursor` reads: an entry
        # whose review started before `through` but appended after it stays live.
        to_archive = [e for e in entries if e.visible_at <= _pad(through)]
        remaining = [e for e in entries if e.visible_at > _pad(through)]
        n_in, n_arch, n_rem = len(entries), len(to_archive), len(remaining)
        if n_in != n_arch + n_rem:
            raise DrainError(EXIT_FAIL, f"partition lost entries: in={n_in} archived={n_arch} remaining={n_rem}")

        # ⚠ §3104 — THE FOURTH SITE, AND THE ONLY DESTRUCTIVE ONE. §3102 converted the two
        # read paths and the resolve short-circuit and its message said "all three
        # predicates"; there were FOUR. This one still asked `lookup(e) is None`, so an
        # entry carrying an `OPEN` row — a row that records a live finding somebody
        # declined, not a closure — passed rotate's gate, was written to the archive and
        # DROPPED from advice.jsonl. The read paths only hid such a finding; this removes
        # it. Second time in two runs that a predicate replaced "everywhere" missed a copy
        # (§3094 said "both comparison sites" and doctor held a third).
        #
        # ⚠ §3107 — AND "THE FOURTH SITE" WAS ITSELF WRONG: there was a FIFTH, in
        # `.claude/hooks/eugo-review-turn-end.sh`, the first consumer of these findings.
        # §3104's message claimed the shape was cured rather than the site; the ratchet it
        # added `ast.parse`s THIS FILE ONLY, and a hook is shell with embedded Python, so
        # the scan could not reach it. Third repetition of §3094's lesson that a second
        # TOOL holds a copy. The count is left in the sentence above because correcting it
        # to "fifth" would hide that the miscount is the recurring defect, not the number.
        missing = [e for e in to_archive if e.owed and not discharges(resolved.lookup(e))]
        if missing:
            lines = [f"  {e.ts} · {e.ref} · {','.join(e.verdicts)}" for e in missing[:50]]
            more = f"\n  ... {len(missing) - 50} more" if len(missing) > 50 else ""
            raise DrainError(
                EXIT_UNRESOLVED,
                f"{len(missing)} NEEDS_REVISION/ERROR entr{'y' if len(missing) == 1 else 'ies'} at or "
                f"before {through} are not CLOSED by a {RESOLVED_MD} row (keyed `ts · ref`; an "
                f"`OPEN` row records a look, not a closure); nothing written:\n"
                + "\n".join(lines) + more,
            )

        summary = f"in={n_in} archived={n_arch} remaining={n_rem} resolved_rows={len(resolved.rows)}"
        if args.dry_run:
            print(f"dry-run {summary} through={through}")
            return EXIT_OK

        staged = _Staged()
        try:
            by_month: dict[str, list[Entry]] = {}
            for e in to_archive:
                by_month.setdefault(e.month, []).append(e)
            jsonl_mode = _mode_of(jsonl)
            written_archive = 0
            for month, batch in sorted(by_month.items()):
                target = advice_dir / ARCHIVE_DIR / f"{month}.jsonl"
                existing = ""
                if target.exists():
                    existing = target.read_text(encoding="utf-8")
                    if existing and not existing.endswith("\n"):
                        existing += "\n"
                text = existing + "".join(e.raw + "\n" for e in batch)
                tmp = staged.write(target, text, _mode_of(target, jsonl_mode))
                # CONSERVATION, re-read from disk: the new lines beyond what was there.
                have = sum(1 for line in tmp.read_text(encoding="utf-8").split("\n") if line.strip())
                had = sum(1 for line in existing.split("\n") if line.strip())
                written_archive += have - had
            tmp_jsonl = staged.write(jsonl, "".join(e.raw + "\n" for e in remaining), jsonl_mode)
            written_remaining = sum(1 for line in tmp_jsonl.read_text(encoding="utf-8").split("\n") if line.strip())
            if written_archive + written_remaining != n_in:
                raise DrainError(
                    EXIT_FAIL,
                    f"conservation failed on disk: in={n_in} archived={written_archive} "
                    f"remaining={written_remaining}; nothing renamed",
                )
            md = advice_dir / ADVICE_MD
            staged.write(md, "".join(render_md(e.obj) for e in remaining), _mode_of(md, jsonl_mode))
            staged.write(resolved_path, _set_cursor(resolved.text, through), _mode_of(resolved_path))
            staged.commit()
        except OSError as error:
            staged.discard()
            raise DrainError(EXIT_FAIL, f"write failed, nothing renamed: {error}") from error
        except DrainError:
            staged.discard()
            raise
        print(summary)
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    # §3123 (§1.89) — the module docstring states the ledger's contract, and a hand-written
    # one-line description kept it out of `--help`; the status vocabulary rides as the epilog.
    ap = argparse.ArgumentParser(
        description=__doc__,
        epilog="RESOLVED.md status vocabulary — the status cell must START with one of: "
               + ", ".join(STATUS_VOCAB)
               + ". A prefix test: `FIXED — already at HEAD by <sha>` passes; "
                 "`ALREADY FIXED BY <sha>` is a malformed row (see `status`: malformed_rows=).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--repo", default=REPO_ROOT,
                    help="repo root (git cwd for --paths; the advice dir is relative to it)")
    ap.add_argument("--advice-dir", default=DEFAULT_ADVICE_DIR)
    ap.add_argument("--watch-script", default=DEFAULT_WATCH_SCRIPT,
                    help="the installed codex_watch.py whose mtime a running daemon must post-date")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="counts, cursor, lock + daemon state as key=value lines")
    lp = sub.add_parser("list", help="entries as JSON lines, filtered")
    lp.add_argument("--after-cursor", action="store_true",
                    help="only entries after RESOLVED.md's drained-through marker")
    lp.add_argument("--verdict", default="", help="csv of verdicts; keep entries carrying any of them")
    lp.add_argument("--unresolved", action="store_true",
                    help="only NEEDS_REVISION/ERROR entries no RESOLVED.md row has CLOSED "
                         "(an `OPEN` row records a look, not a closure — §3102)")
    lp.add_argument("--session", default="",
                    help="only entries whose review was DISPATCHED by this session id; "
                         "`--session none` keeps only entries carrying no session at all")
    lp.add_argument("--mine", action="store_true",
                    help=f"shorthand for --session ${SESSION_ENV}; with no such env var set "
                         "this matches nothing, which is the honest answer rather than everything")
    lp.add_argument("--paths", nargs="+", default=[],
                    help="pathspecs (dir prefix or fnmatch); keep kind=commit entries whose "
                         "`git show --name-only` intersects them; adds `matched_paths`")
    rp = sub.add_parser("rotate", help="archive entries appended (else ts) <= --through under .advice.lock")
    rp.add_argument("--through", required=True, help="YYYY-MM-DDTHH:MM:SSZ, or YYYY-MM-DD (end of day)")
    rp.add_argument("--lock-timeout", type=float, default=30.0,
                    help="seconds to wait for .advice.lock (0 = one try); exit 3 on timeout")
    rp.add_argument("--dry-run", action="store_true", help="report the counts, write nothing")
    sp = sub.add_parser("resolve", help="write ONE RESOLVED.md disposition row for the matched entry")
    sp.add_argument("--ref", required=True, help="the entry's ref: exact, or a >=12-char prefix of it")
    sp.add_argument("--status", required=True,
                    help="one of " + "/".join(STATUS_VOCAB) + ", optionally with a qualifier "
                         "(\"FIXED b808e4893f\", \"OPEN -> FUTURE F123\")")
    sp.add_argument("--evidence", required=True,
                    help="commit sha, doc path or one sentence — what makes that status true")
    sp.add_argument("--ts", default="",
                    help="disambiguate a --ref that matches entries at more than one ts")
    sp.add_argument("--lock-timeout", type=float, default=30.0,
                    help="seconds to wait for .advice.lock (0 = one try); exit 3 on timeout")
    sp.add_argument("--dry-run", action="store_true", help="print the row that would be written, write nothing")

    # §3108 (§1.85 cure 2) — claim an UNOWNED finding so peers stop seeing it, for a
    # BOUNDED time. Deliberately not a flag on `resolve`: a claim is not a disposition.
    cp = sub.add_parser("claim", help="take an unowned finding for "
                                      f"{CLAIM_TTL_SECONDS // 3600}h; it returns automatically")
    cp.add_argument("--ref", required=True, help="the entry's ref: exact, or a >=12-char prefix of it")
    cp.add_argument("--ts", default="",
                    help="disambiguate a --ref that matches entries at more than one ts")
    cp.add_argument("--as", dest="as_session", default="",
                    help=f"claim as this session id (default: ${SESSION_ENV}). A claim must "
                         "name a holder, so an empty value is refused rather than anonymised")
    cp.add_argument("--note", default="",
                    help="optional evidence cell — what you intend to do with it")
    cp.add_argument("--lock-timeout", type=float, default=30.0,
                    help="seconds to wait for .advice.lock (0 = one try); exit 3 on timeout")
    cp.add_argument("--dry-run", action="store_true", help="print the row that would be written, write nothing")
    args = ap.parse_args(argv)

    advice_dir = Path(args.advice_dir)
    if not advice_dir.is_absolute():
        advice_dir = Path(args.repo) / advice_dir
    handlers = {"status": cmd_status, "list": cmd_list, "rotate": cmd_rotate,
                "resolve": cmd_resolve, "claim": cmd_claim}
    try:
        return handlers[args.cmd](args, advice_dir)
    except DrainError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return error.code


if __name__ == "__main__":
    raise SystemExit(main())
