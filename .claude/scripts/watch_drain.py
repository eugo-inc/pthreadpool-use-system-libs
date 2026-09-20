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
```

THE LEDGER — `<advice-dir>/RESOLVED.md`. A Markdown table keyed `ts · ref` (the entry's
own `ts` and `ref`; a ref of >= 12 leading characters matches, the daemon's own
shorthand), one row per handled entry, status in {FIXED §id, OPEN → FUTURE, REFUTED,
RETRY, UNTRACED}, plus one marker line `<!-- drained-through: <ts> -->` (`(none)` before
the first drain). `rotate` REFUSES while any NEEDS_REVISION/ERROR entry at or before
`--through` has no row: the record is the precondition, not a by-product.

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
that would move backwards, or `in != archived + remaining`) · 2 an owed entry has no
RESOLVED.md row · 3 `.advice.lock` not acquired within `--lock-timeout` · 4 the watch
daemon holding `.watch.lock` predates the installed `codex_watch.py`.

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
#: The status vocabulary — the row's status cell must START with one of these.
STATUS_VOCAB = ("FIXED", "OPEN", "REFUTED", "RETRY", "UNTRACED")
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
        try:
            out = subprocess.run(["git", "rev-list", "--count", f"{ref}..HEAD"],
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
        self.malformed: list[str] = []  # "<lineno>: <reason>"
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
        for ref, status in self.by_ts.get(entry.ts, ()):
            if len(ref) >= MIN_REF_PREFIX and entry.ref.startswith(ref):
                return status
        return None


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
            in_table = False
            continue
        cells = row_cells(stripped)
        if cells and cells[0] == "ts":
            in_table = True
            saw_ledger_header = True
            continue
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
        res.by_ts.setdefault(ts, []).append((ref, status))
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


def changed_paths(repo: str, ref: str) -> list[str] | None:
    """Paths a commit touched, or None when git cannot resolve it in `repo`.
    `--first-parent` so a merge commit lists what it brought in (a plain
    `git show --name-only` prints nothing for a merge)."""
    try:
        out = subprocess.run(
            ["git", "show", "--name-only", "--format=", "--first-parent", ref],
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
    unresolved = [e for e in owed if resolved.lookup(e) is None]
    # §3043 — who wrote each entry, and whose entries carry an ERROR verdict.
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
    out = [
        f"advice_dir={advice_dir}",
        f"entries={len(entries)}",
        f"approved={tally['APPROVED']} needs_revision={tally['NEEDS_REVISION']} error={tally['ERROR']} "
        f"other_verdicts={other} no_result={no_result}",
        f"owed={len(owed)} unresolved={len(unresolved)}",
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
        # §2189 — the depth the cure needs, so the banner names a command that reaches
        # what it counts. Empty when nothing is stuck, which is the common path.
        f"retry_scan={retry_scan_depth(advice_dir, Path(args.repo))}",
        f"resolved_md={'present' if resolved.exists else 'absent'} resolved_rows={len(resolved.rows)}"
        + (f" ⚠ UNRECOGNISED: {resolved.unrecognised} table line(s) this parser could not see "
           f"(a different RESOLVED.md schema) — resolved_rows=0 describes THIS PARSER, not the file"
           if resolved.unrecognised else "") + " "
        f"malformed_rows={len(resolved.malformed)}",
        f"cursor={resolved.cursor if resolved.cursor is not None else '(no marker)'}",
        f"ts_min={min(e.ts for e in entries) if entries else '-'} "
        f"ts_max={max(e.ts for e in entries) if entries else '-'}",
        "months=" + (",".join(f"{m}:{n}" for m, n in sorted(months.items())) or "-"),
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
        entries = [e for e in entries if e.owed and resolved.lookup(e) is None]
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

        missing = [e for e in to_archive if e.owed and resolved.lookup(e) is None]
        if missing:
            lines = [f"  {e.ts} · {e.ref} · {','.join(e.verdicts)}" for e in missing[:50]]
            more = f"\n  ... {len(missing) - 50} more" if len(missing) > 50 else ""
            raise DrainError(
                EXIT_UNRESOLVED,
                f"{len(missing)} NEEDS_REVISION/ERROR entr{'y' if len(missing) == 1 else 'ies'} at or "
                f"before {through} lack a {RESOLVED_MD} row (keyed `ts · ref`); nothing written:\n"
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
    ap = argparse.ArgumentParser(
        description="Drain the codex_watch advice files: ledger status, cursor listing, monthly rotation.",
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
                    help="only NEEDS_REVISION/ERROR entries with no RESOLVED.md row")
    lp.add_argument("--paths", nargs="+", default=[],
                    help="pathspecs (dir prefix or fnmatch); keep kind=commit entries whose "
                         "`git show --name-only` intersects them; adds `matched_paths`")
    rp = sub.add_parser("rotate", help="archive entries appended (else ts) <= --through under .advice.lock")
    rp.add_argument("--through", required=True, help="YYYY-MM-DDTHH:MM:SSZ, or YYYY-MM-DD (end of day)")
    rp.add_argument("--lock-timeout", type=float, default=30.0,
                    help="seconds to wait for .advice.lock (0 = one try); exit 3 on timeout")
    rp.add_argument("--dry-run", action="store_true", help="report the counts, write nothing")
    args = ap.parse_args(argv)

    advice_dir = Path(args.advice_dir)
    if not advice_dir.is_absolute():
        advice_dir = Path(args.repo) / advice_dir
    handlers = {"status": cmd_status, "list": cmd_list, "rotate": cmd_rotate}
    try:
        return handlers[args.cmd](args, advice_dir)
    except DrainError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return error.code


if __name__ == "__main__":
    raise SystemExit(main())
