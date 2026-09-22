#!/usr/bin/env bash
# §2116 — the TURN BOUNDARY hook: surface what review found, and review the work so far.
#
# WHY THIS EXISTS. Reviewing only at commit time is too late. Measured across four repos:
# the median commit gap is 3-12 minutes, but 75-96% of elapsed WORKING TIME sits in gaps
# of >=20 minutes (epstein-drive's p90 gap is 182 minutes). Agents commit after a long
# test-and-iterate cycle, so a design defect found at the commit costs the whole
# iteration. Those long gaps were entirely unreviewed.
#
# `Stop` is the trigger because it is the only event guaranteed to sit BETWEEN turns —
# the current one has ended and the next has not begun — which is both the cheapest
# moment for an agent to change direction and the moment a finding can be read.
#
# VERIFIED EMPIRICALLY BEFORE THIS WAS WRITTEN (§2116 probe, since removed), because the
# documentation was wrong about `PostToolUse` in two places at §2109:
#   - the Stop family fires and carries `stop_hook_active`, `last_assistant_message`,
#     `session_id`, `transcript_path`, `cwd`;
#   - EXIT 2 FEEDS stderr BACK TO THE MODEL AND THE AGENT CONTINUES — proved on
#     `SubagentStop`: a probe blocked once, and the agent's next message was the text the
#     hook had asked for;
#   - `stop_hook_active` is True on that second call, which is the loop guard.
#
# Contract (each line is a test in tools/tests/test_review_turn_end_hook.py):
#   - `stop_hook_active` true -> exit 0 at once. Without this a finding could block every
#     turn forever; this is the ONLY thing standing between a blocking verdict and a loop.
#   - every other path exits 0 or 2 — never anything else, and never a traceback
#   - it INTERRUPTS (exit 2) only on NEEDS_REVISION carrying a Critical Issues body, and
#     INFORMS otherwise. ~24% of captures produce no usable output, so anything
#     unparseable, empty or ERROR informs — it must never interrupt on a non-finding.
#   - a missing repo/ledger/script is silent and exit 0
#   - bash 3.2 safe
set -u

ROOT="${CLAUDE_PROJECT_DIR:-.}"
WATCH="$ROOT/.claude/scripts/codex_watch.py"
ADVICE="$ROOT/.adversarial-review/watch"
STATE="$ROOT/outputs/_state/review-turn-end"

IN="$(cat 2>/dev/null || true)"

# ⚠ §2121 — THE REVIEWER IS NOT A SESSION TO REVIEW. This guard is first because it is
# the one that was missing, and its absence cost 31 commits.
#
# `codex_review.py` spawns the reviewer with `cwd=repo`, so a review of THIS repo loads
# THIS file. When that reviewer finished a turn, this hook fired inside it — and a `Stop`
# hook that exits 2 makes the agent CONTINUE. The continuation became the reviewer's final
# message, which carries no verdict line, so the review was recorded as
# ERROR "no verdict line" and the reviewed commit was charged a failed attempt. Measured
# at the minute §2116 landed: verdict-less captures 1.3% -> 20.4%, and 31 commits were
# abandoned unreviewed — §2116 through §2120 among them.
#
# It also fixes a quieter defect: each review subprocess is a fresh session whose `.seen`
# mark is empty, so this hook was re-surfacing old findings INTO THE REVIEWER'S CONTEXT.
# An `if`, not `[ … ] && exit 0`: that form leaves the compound command returning 1 when
# the test is false, which would terminate the script the day anyone adds `set -e` — and
# a non-zero exit from a Stop hook is not a silent no-op.
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi

# THE LOOP GUARD, and it comes first for a reason: if a blocking verdict is outstanding
# and this hook blocked to report it, the agent's very next stop must be allowed through.
case "$IN" in
  *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;;
esac

[ -d "$ADVICE" ] || exit 0

# ⚠ §3105 — TWO USES, TWO VARIABLES, AND §3103 CONFLATED THEM. `$SID` names the
# seen-marker FILE, so it must never be empty and has carried a `nosession` placeholder
# since long before the ledger had an owner column. The LEDGER stamp is an IDENTITY and
# must stay EMPTY when the payload carried none: `codex_watch.resolve_session` omits the
# key on "" precisely so a reader can tell "no session was recorded" from "a session
# called nosession". Reusing the one variable for both stamped that placeholder as a real
# id, and two payload-less sessions would then OWN each other's entries — the exact
# collision the owner column was added to prevent.
SESSION_ID="$(printf '%s' "$IN" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
SID="$SESSION_ID"
[ -n "$SID" ] || SID="nosession"
mkdir -p "$STATE" 2>/dev/null || exit 0
MARK="$STATE/$SID.seen"

# ---- surface anything that landed since this session last looked -------------------
# §3106 — `$SESSION_ID` (never `$SID`: §3105) decides which findings may INTERRUPT.
OUT="$(python3 - "$ADVICE" "$MARK" "$ROOT/.claude/scripts" "$SESSION_ID" <<'PY' 2>/dev/null
import importlib.util, json, sys, time
from pathlib import Path
advice, mark = Path(sys.argv[1]), Path(sys.argv[2])
#: §3114 — the checkout `advice` sits in: `<root>/.adversarial-review/watch`.
root = advice.parents[1]
scripts = Path(sys.argv[3]) if len(sys.argv) > 3 else None
#: §3106 — the session this turn belongs to, "" when the payload carried none (§3105).
me = sys.argv[4] if len(sys.argv) > 4 else ""
_wd_cache = []


def _wd():
    """`watch_drain` as a module, loaded at most once, or None.

    §2142 loaded it inside `_resolved` and threw it away; §3106 needs `owns` from the
    same module, and re-loading per call would pay the import twice while re-deriving
    the predicate would be the second copy this file exists to avoid.
    """
    if _wd_cache:
        return _wd_cache[0]
    mod = None
    if scripts is not None:
        try:
            spec = importlib.util.spec_from_file_location("_wd", scripts / "watch_drain.py")
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception:
            mod = None
    _wd_cache.append(mod)
    return mod


def _discharged(e):
    """Has a RESOLVED.md row CLOSED this entry? Imported, never re-derived (§3107).

    The distinction `discharges` encodes: a row exists is not a row that closes. `OPEN`
    is in the vocabulary precisely so a session can record a look without ending the
    finding, and every query that asked about PRESENCE silently converted that courtesy
    into a deletion.

    Degrades to NOT discharged — the noisy direction, for the same reason as `_owns`: a
    finding shown twice costs a line, a finding closed wrongly is gone from this channel
    for good.
    """
    wd = _wd()
    if wd is None or resolved is None:
        return False
    try:
        return wd.discharges(resolved.lookup(_Ref(ts_of(e), str(e.get("ref") or ""))))
    except Exception:
        return False


#: §3114 (§1.81 cure 3) — how far back a commit may sit and still count as THIS session's
#: news on a cold start. A session commits, the review lands ~151s later (p95 390s), and
#: the commit itself was written some minutes before that — so the window has to be
#: comfortably wider than the review latency, and an hour is. Anything older than this was
#: committed before the session existed: inherited backlog, not news.
COLD_START_NEWS_SECONDS = 3600


def _commit_epoch(ref):
    """Committer date of `ref` as an epoch, or None when git cannot say.

    Committer, not author: a rebased or cherry-picked commit carries an author date from
    days earlier and would be misread as backlog — the same rule §3109 follows.
    """
    import subprocess  # noqa: PLC0415 — only reached on the cold-start path
    try:
        out = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%ct", str(ref)],
                             capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    raw = (out.stdout or "").strip()
    return float(raw) if out.returncode == 0 and raw else None


def _is_inherited_backlog(e, cold):
    """§3114 — was this entry's COMMIT written before this session existed?

    ⚠ THE CURSOR KEYS ON REVIEW TIME, WHICH IS WHY THIS IS NEEDED AT ALL. `_key` reads
    `appended` — stamped when the review LANDED — so a catch-up re-reviewing a three-day-old
    commit mints an entry that reads as brand new, and §3106 does not help: this session
    DISPATCHED that review, so it owns the entry and would be interrupted by it. Measured in
    protomolecule 2026-09-21: two of the commits named were 8½ hours older than the addressed
    session's first commit.

    Only on a COLD start, and that is the whole trick. A cold session's `since` is "" so it
    scans the entire ledger (§2130 calls this the dominant shape), and its first look IS
    now — so "before the session existed" needs no stored start time, no marker file, and no
    ledger derivation. A warm session is already bounded by its own cursor.

    Fails toward NEWS: no ref, an unparseable date, a worktree entry (no commit to date), or
    git declining all leave the entry blocking. Suppressing a real finding costs more than
    showing an old one, which is the direction every degradation in this file takes.
    """
    if not cold or str(e.get("kind")) != "commit":
        return False
    when = _commit_epoch(e.get("ref") or "")
    if when is None:
        return False
    return when < time.time() - COLD_START_NEWS_SECONDS


def _owns(e):
    """Is this entry THIS session's to be interrupted by? Imported, never re-derived.

    ⚠ DEGRADES TOWARDS NOISE, DELIBERATELY. If `watch_drain` cannot be loaded the answer
    is unknown, and the two ways to be wrong are not symmetric: suppressing a finding
    that was this session's loses it silently, while showing one that was not costs a
    line the reader can dismiss. A review channel survives the second failure and not the
    first, and the same file already degrades this way for §2142's rowed-finding filter.
    """
    wd = _wd()
    if wd is None:
        return True
    try:
        return wd.owns(e.get("session"), me)
    except Exception:
        return True


class _Ref:
    """The two fields `watch_drain.Resolved.lookup` reads off an entry."""

    __slots__ = ("ts", "ref")

    def __init__(self, ts, ref):
        self.ts, self.ref = ts, ref


def _resolved():
    """RESOLVED.md rows via watch_drain's OWN parser, or None if it cannot be loaded.

    ⚠ §2142 — THIS BLOCK USED TO INTERRUPT WITH FINDINGS ALREADY MARKED FIXED. It
    classified from the ledger alone, so a finding triaged and rowed days ago still
    counted, still printed, and still exited 2 — while genuinely open ones sat inside the
    remainder count. Every fresh session is a cold start (`since=""` scans the whole
    ledger), so that was the DOMINANT shape, not an edge.

    Worse, §2130's remainder line names `watch_drain.py list --unresolved`, and that
    command DOES filter on RESOLVED.md — so the two halves of one channel disagreed by
    construction: the count included rowed findings, the command it pointed at excluded
    exactly those.

    IMPORTED, NEVER RE-DERIVED — the rule `watch_drain._abandoned_count` already states
    for the predicate it borrows from `codex_watch`. `lookup` matches an exact `ref` or a
    >=12-char prefix of it, and a second copy of that would be the two-definitions defect
    §2110 and §2112 each shipped. Degrades silently to the old behaviour, because a hook
    must never fail a turn over its own bookkeeping.
    """
    wd = _wd()  # §3106 — the one load, shared with `_owns`.
    if wd is None:
        return None
    try:
        return wd.read_resolved(advice / wd.RESOLVED_MD)
    except Exception:
        return None


def _superseded_now(ref):
    """What later history has done to `ref`'s files AS OF NOW, or None.

    ⚠ §2201 — THE STORED MARKER IS STAMPED AT REVIEW TIME AND THE READER ACTS AT TURN END.
    `codex_watch._superseded` runs when the review is dispatched, so a commit that was HEAD
    then carries `superseded: None` forever — even after its own successor cures the finding
    minutes later. Measured on §2860 (`a3e64ded`): the ledger entry stamped 09:08:08Z has
    `superseded: None`, because it WAS head; §2861 landed next and fixed the arm the finding
    named, and its docstring says so. The blocking line still arrived bare, and the check
    that would have settled it in one read — "1 later commit touched these files" — is
    exactly what `_superseded` returns when asked NOW.

    Not a rare shape: of the blocking findings routed to this session, §2164 was cured by
    §2169 and §2860 by §2861, both before the reader saw them.

    ⚠ §2203 — THE COST FIGURES THAT USED TO SIT HERE WERE WRONG AND SURVIVED THE COMMIT
    WRITTEN TO CORRECT THEM. This said "~7 ms per call measured, and `CAP` bounds it to
    three, so the turn pays ~25 ms". Neither half held: `blocking[:CAP]` caps the PRINTING,
    and 7 ms is what the `return None` short-circuit costs — the arm taken for a worktree
    entry or a commit that is still HEAD — not what a real lookup costs.

    MEASURED over all 45 NEEDS_REVISION-with-critical entries in this ledger, warm (module
    already imported): total 2,328 ms, mean 51.7, min 2.0, max 191.5. The spread is the
    point: cost scales with how deep the ref is and how many paths it touched, so a single
    number cannot describe it. What IS bounded is the count — §2202 moved the lookup inside
    the capped print loop, so a turn pays for three, measured at 233 ms for this ledger's
    first three.

    End to end, round-robin against the pre-§2201 hook, mean of 3: 54 ms before any live
    marker, 1,427 ms as §2201 shipped it, 347 ms now.

    Degrades to the stored value on any failure — a hook must never fail a turn over its
    bookkeeping.
    """
    if scripts is None:
        return None
    try:
        cw = _superseded_now.mod
    except AttributeError:
        try:
            spec = importlib.util.spec_from_file_location("_cw", scripts / "codex_watch.py")
            cw = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cw)
        except Exception:
            cw = None
        _superseded_now.mod = cw
    if cw is None:
        return None
    try:
        return cw._superseded(str(scripts.parent.parent), ref)
    except Exception:
        return None


resolved = _resolved()
#: §2202 — what the ledger stamped at review time, kept per ref so the capped print loop
#: can fall back to it without re-walking the entries.
_stored_superseded = {}
try:
    since = mark.read_text(encoding="utf-8").strip()
except OSError:
    since = ""


def _pad(raw):
    """One comparable shape for both stamps, so string order IS time order."""
    if not isinstance(raw, str) or not raw.endswith("Z"):
        return ""
    return raw if "." in raw else raw[:-1] + ".000000Z"


def ts_of(e):
    """The entry's own `ts`, which is what a RESOLVED.md row is keyed on."""
    raw = e.get("ts")
    return raw if isinstance(raw, str) else ""


def _key(e):
    # §2130 — `appended` (stamped at APPEND time, inside the ledger lock) in preference
    # to `ts` (stamped at review START, ~151s earlier). Entries written before §2130
    # carry no `appended` and fall back to `ts`, which is the best they have.
    return _pad(e.get("appended") or e.get("ts") or "")


since = _pad(since)
# §3114 — a COLD start is one that has never looked: `since` is "" and the scan covers the
# whole ledger. Captured BEFORE the loop, because `since` is a moving target inside it.
cold_start = not since.strip()
newest, blocking, informational = since, [], []
try:
    lines = (advice / "advice.jsonl").read_text(encoding="utf-8").splitlines()
except OSError:
    lines = []
for line in lines:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        e = json.loads(line)
    except ValueError:
        continue
    k = _key(e)
    if not k or k <= since:
        continue
    newest = max(newest, k)
    # §2142 — a finding already rowed in RESOLVED.md has been triaged; it is not this
    # turn's work. The cursor still advances over it, so it never comes back.
    #
    # ⚠ §3107 — THE FIFTH SITE, AND THE CURSOR ABOVE IS WHAT MADE IT DESTRUCTIVE. This
    # asked `lookup(...) is not None` — row PRESENCE — after §3102/§3104 had replaced that
    # question everywhere in `watch_drain.py` with `discharges`. So an entry rowed `OPEN`
    # ("I looked, it is still live") was skipped HERE while `list --unresolved` correctly
    # kept holding it: the two halves of one channel disagreeing by construction, which is
    # §2142's own stated defect, re-introduced in the reverse direction. And because
    # `newest = max(newest, k)` runs two lines ABOVE this `continue`, the skipped entry is
    # marked seen — so the finding went silent on this channel PERMANENTLY for that
    # session, not merely for one turn.
    #
    # The §3104 ratchet could not catch it: it `ast.parse`s `watch_drain.py`, and this is
    # shell with embedded Python. "Cured at the SHAPE rather than the site" was therefore
    # false as written in §3104's message — the shape had a fifth instance in another
    # file, which is §3094's recorded lesson ("a second TOOL held a copy") a third time.
    if resolved is not None and _discharged(e):
        continue
    for r in e.get("results") or ():
        v, crit = r.get("verdict"), (r.get("critical") or "").strip()
        label = "%s %s" % (str(e.get("kind"))[:8], str(e.get("ref"))[:12])
        # INTERRUPT only on a real finding: NEEDS_REVISION carrying a critical body.
        # ~24% of captures produce nothing usable, so everything else informs.
        if v == "NEEDS_REVISION" and crit and _is_inherited_backlog(e, cold_start):
            # §3114 (§1.81 cure 3) — this session DISPATCHED the review, so §3106's owner
            # check passes and would interrupt on it; but the COMMIT predates the session,
            # so it is inherited work, not news. Placed before the ownership branch because
            # it is the case ownership cannot see, and before `_superseded_now` because
            # that costs a measured 51.7 ms (§2203) this branch never needs to pay.
            informational.append("%s: NEEDS_REVISION (backlog — committed before this session)"
                                 % label)
        elif v == "NEEDS_REVISION" and crit and not _owns(e):
            # ⚠ §3106 (§1.81 cure 2) — A REAL FINDING, AND NOT THIS TURN'S TO BE STOPPED BY.
            # The queue is repo-wide and had no owner column until §3103, so every session
            # was interrupted by every session's findings. Measured in protomolecule
            # 2026-09-21: 17 blocking items named, ZERO written by the session addressed.
            # §3085 fixed the SENTENCE that claimed authorship; this fixes the SET.
            #
            # It informs rather than vanishing: the finding is real, it is still owed a
            # row, and `list --unresolved` still holds it. What changes is whose turn pays
            # the interrupt. An UNSTAMPED entry is owned by nobody (`owns`), so the whole
            # pre-§3103 backlog informs — which is the intended reading of it as backlog.
            #
            # Placed BEFORE `_superseded_now`: that call costs a measured 51.7 ms per
            # entry (§2203) and this branch is the common one, so the filter that removes
            # the most work now runs before the work. §2202 shipped the opposite ordering.
            informational.append("%s: NEEDS_REVISION (another session's finding)" % label)
        elif v == "NEEDS_REVISION" and crit:
            # §2143 — say so when the reviewed commit's files have moved since. A backlog
            # review argues against a diff and the reader acts against HEAD; without this
            # a finding about reverted code reads exactly like a finding about live code.
            #
            # ⚠ §2195 — AND SAY WHAT THE NUMBER IS MOSTLY MADE OF, WHEN ONE PATH CARRIES IT.
            # `commits_since` counts EVERY path the reviewed commit touched, and a commit
            # that also touched `.claude/data/overnight/breadcrumb.log` — rewritten by every
            # overnight iteration — carries a figure that is mostly that churn. Measured:
            # of 38 ledger entries at >=50, 32 are inflated more than 2x by that one file.
            # §2168 read three such numbers as a fact about two source files and printed
            # "222, 218 and 254" into another session's hand-off, where the real counts were
            # 13/11/11 and 39/39/38 (§2194 corrected it). The headline keeps its meaning;
            # the dominant path is named beside it so nobody reads it as code movement again.
            # §2201 — ask NOW, not at review time; fall back to what was stamped then.
            # ⚠ §2202 — DEFERRED UNTIL AFTER THE CAP. §2201 derived this inside the loop and
            # its comment claimed "CAP bounds it to three, so the turn pays ~25 ms". Both
            # halves were false: `blocking[:3]` caps the PRINTING, not this, so the call ran
            # for every NEEDS_REVISION entry carrying a critical body — 44 of them in this
            # ledger — and the ~7 ms I quoted was measured with the module already imported
            # while the helper re-exec'd `codex_watch.py` on every call, which costs 13 ms.
            # A cold session (the dominant shape, per §2130 below: `since=""` scans the whole
            # ledger) therefore paid far more than 25 ms — measured round-robin at 1,427 ms
            # against 54 ms for the pre-§2201 hook.
            #
            # ⚠ §2203 — AND "~570 ms" STOOD HERE, WHICH WAS ARITHMETIC (44 x 13) WRITTEN AS
            # IF MEASURED, IN THE COMMIT WHOSE SUBJECT IS A FALSE COST CLAIM. The measured
            # figure is above. The per-call mean is 51.7 ms over 45 entries, not the 13 ms
            # that multiplication used and not the 7 ms the docstring claimed.
            #
            # ⚠ §2212 — AND "FOR EVERY NEEDS_REVISION ENTRY CARRYING A CRITICAL BODY" IS
            # STILL TOO BROAD, WHICH MAKES THIS THE FOURTH CORRECTION OF THIS COMMENT. The
            # §2142 `continue` above (`resolved.lookup(...) is not None`) skips an entry
            # ALREADY ROWED in RESOLVED.md BEFORE the results loop is entered, so a rowed
            # entry never reaches this call at all. Re-derived from the data at §2202's own
            # commit time — the append-only ledger truncated at 2026-09-15T11:10:59, against
            # RESOLVED.md at `01bceb23`: 46 NR+critical entries, 20 already rowed, so the
            # call ran ~26 times, not 44.
            #
            # NOTHING A READER ACTS ON MOVES: the end-to-end 54 / 1,427 / 347 ms are direct
            # measurements, and the docstring's 45 is correctly labelled a measurement
            # SAMPLE rather than a per-turn count. What moves is the MECHANISM — the call
            # count is drain-state dependent (the same population against today's
            # RESOLVED.md reaches 22), so no fixed number describes it. The cold session
            # this comment is about is the shape where the filter removes the MOST.
            ref = e.get("ref") or ""
            if isinstance(e.get("superseded"), dict):
                _stored_superseded[ref] = e["superseded"]
            # §3085 — the KIND travels with the finding, because the lead sentence bash
            # prints depends on it and nothing else can tell the two apart down there.
            blocking.append((label, crit.split("\n")[0][:400], ref, str(e.get("kind") or "")))
        elif v == "NEEDS_REVISION":
            # A finding with no Critical body: real, but not worth interrupting for.
            informational.append("%s: NEEDS_REVISION (no critical body)" % label)
        # ⚠ §2120 — ERROR IS NOT SURFACED AT ALL, and that is a deliberate narrowing.
        # An ERROR entry means the REVIEW failed, not that the code is wrong — 23% of
        # captures produce no model output and they track account outages, which §2114
        # established are nobody's fault. The first live firing of this hook reported
        # five of them in one turn; a channel that cries infrastructure at every turn
        # boundary is one an agent learns to ignore, which costs the findings that
        # matter. They remain in the ledger and the drain still holds them as owed.
if newest and newest != since:
    try:
        mark.write_text(newest, encoding="utf-8")
    except OSError:
        pass
# ⚠ §2130 — THE CAP STAYS, THE SILENCE GOES. `blocking[:3]` printed three while the
# cursor above advanced over ALL of them, so findings 4..N were marked seen without ever
# having been shown — and the `elif` discarded every informational entry whenever a single
# blocking one was present. Live ticks emit five verdicts at once, so both were routine.
# Three is still what an agent can act on in one turn; what changes is that the turn can
# tell three-of-three from three-of-nine.
#
# ⚠ AND THE WATERMARK STILL ADVANCES, DELIBERATELY. Holding it back to the last entry
# actually shown is the obvious alternative and it HANGS SESSIONS: a fresh session reads
# `since=""`, so it scans the whole ledger, and it would then block again every other turn
# until the backlog drained. `stop_hook_active` is the only loop guard there is and it
# must not be asked to carry that.
CAP = 3
OWED = "python3 .claude/scripts/watch_drain.py list --unresolved"
if blocking:
    # §3085 — the marker carries the KINDS present, so the lead sentence can be true of
    # what is actually in the list. `BLOCK*` still matches and `tail -n +2` still strips
    # exactly this line, so every other consumer is unchanged.
    print("BLOCK %s" % ",".join(sorted({k for _, _, _, k in blocking if k})))
    # §2202 — the supersession marker is derived HERE, for the capped slice only, so the
    # cost really is bounded by CAP the way §2201's comment claimed it already was.
    for label, crit, ref, _kind in blocking[:CAP]:
        sup = _superseded_now(ref) or _stored_superseded.get(ref) or {}
        n = sup.get("commits_since") if isinstance(sup, dict) else None
        dom = sup.get("dominated_by") if isinstance(sup, dict) else None
        why = ""
        if isinstance(dom, dict) and dom.get("path"):
            why = ", %s of them ONLY %s" % (dom.get("only_here"), dom["path"])
        tail = (("  [⚠ %d later commit(s) touched these files%s — verify against HEAD]"
                 % (n, why)) if n else "")
        print("%s: %s%s" % (label, crit, tail))
    rest = []
    if len(blocking) > CAP:
        rest.append("%d more blocking" % (len(blocking) - CAP))
    if informational:
        rest.append("%d informational" % len(informational))
    if rest:
        print("(+%s not shown — %s)" % (", ".join(rest), OWED))
elif informational:
    print("INFORM")
    for i in informational[:CAP]:
        print(i)
    if len(informational) > CAP:
        print("(+%d more — %s)" % (len(informational) - CAP, OWED))
PY
)" || OUT=""

# ---- dispatch a review of the work so far, in the background ----------------------
# Gated inside codex_watch by the LEDGER: the diff must have changed, be big enough to be
# worth ~151s, and the interval must have passed. All three survive a fresh process,
# which the old in-memory debounce did not.
if [ -f "$WATCH" ]; then
  LOG="$ROOT/outputs/_state/logs/review-turn-end.log"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # ⚠ §2124 — THE WORKTREE LOCK, NOT `.watch.lock`. This probed the shared single-instance
  # lock, which a commit drain holds for ~151s per pending commit — and `Stop` fires AFTER
  # a turn's last Bash call, so this probe arrived second EVERY time. The ledger's zero
  # `kind:"worktree"` entries and the absence of this very log file are what that cost:
  # the dispatch below had never once been attempted. Worktree runs now contend only with
  # each other.
  WTLOCK="$ADVICE/.watch.worktree.lock"
  # ⚠ §2128 — THE REDIRECT GOES ON THE GROUP, NEVER ON `exec`. This read
  # `exec 9<"$WTLOCK" 2>/dev/null`, and in that form the `2>/dev/null` is an argument to
  # EXEC — so it permanently rebound this script's stderr to /dev/null for everything
  # after it, including the blocking report below. The hook went on exiting 2, so the
  # agent was still interrupted; it just could no longer say why. That is exactly what
  # the harness reported: "No stderr output".
  #
  # It never showed up in test because every fixture on the surfacing path creates NO
  # lock file, so `[ ! -e ]` short-circuits and this line never runs — the same blind
  # spot §2124 named for the probe itself, one line lower. A group redirect is scoped to
  # the group and restored on exit, which is what was meant all along.
  if [ ! -e "$WTLOCK" ] || { { exec 9<"$WTLOCK"; } 2>/dev/null && flock -n -s 9 2>/dev/null; }; then
    { flock -u 9 2>/dev/null; exec 9<&-; } 2>/dev/null || true
    # §3044 — the writer travels in the ENV, never argv (see eugo-review-on-commit.sh).
    ( cd "$ROOT" 2>/dev/null &&
      # §3103 — the ledger gets the session id too. §3105 — `$SESSION_ID`, NOT `$SID`:
      # the latter is a filename that falls back to a placeholder (see its extraction).
      EUGO_REVIEW_WRITER=hook-turn-end EUGO_REVIEW_SESSION="$SESSION_ID" python3 "$WATCH" --once --since-ledger --worktree --no-commits \
          --engine claude --advice-dir ".adversarial-review/watch"
    ) >>"$LOG" 2>&1 &
  fi
fi

case "$OUT" in
  BLOCK*)
    # ⚠ §3085 — THIS SENTENCE USED TO READ "in work you just did", AND IT WAS NOT TRUE.
    # Measured in protomolecule 2026-09-21: the hook named 17 blocking items, ZERO of them
    # written by the session it was addressing, two of them 8.5 hours older than that
    # session's first commit. A cold session scans the whole ledger (§2130 above), so the
    # false attribution is the DOMINANT shape rather than an edge, and the cost of a gate
    # that blames every session for other people's backlog is every true finding it raises
    # afterwards that nobody believes.
    #
    # THE TWO KINDS ARE NOT THE SAME CLAIM, which is why the marker carries them:
    #   * `commit` — the reviewed sha landed during this turn, but this is a SHARED clone
    #     and git cannot attribute an author, so the hook says when it landed and stops.
    #   * `worktree` — the ref is a CONTENT HASH over the shared dirty tree, so it can
    #     never be attributed to anyone. An earlier fix asserted the opposite here
    #     ("the worktree one(s) are in work you just did") beside a correct disclaimer for
    #     commits, which read as a considered distinction and was therefore believed:
    #     measured at the firing moment, 67 tracked modifications across at least four
    #     accounts, both flagged findings about files owned by another user whose mtime
    #     was an hour AFTER the addressed session's last commit, and that session had no
    #     uncommitted work at all. Saying NOTHING about ownership is the cheapest correct
    #     form; the reader is pointed at the one command that settles it.
    KINDS="$(printf '%s' "$OUT" | head -n1)"; KINDS="${KINDS#BLOCK}"; KINDS="${KINDS# }"
    case "$KINDS" in
      worktree) WHOSE='in the shared working tree — it holds every account'"'"'s uncommitted work, so these may or may not be yours; `git diff -U0 -- <path>` before acting' ;;
      commit)   WHOSE='in commit(s) that LANDED during this turn (shared clone — git cannot attribute the author)' ;;
      *)        WHOSE='in unresolved review findings for this repo (shared clone and shared worktree — neither can be attributed to a session)' ;;
    esac
    printf 'adversarial review found a blocking issue %s:\n%s\n\nAddress it before continuing, or say why it is not a defect.\n' \
      "$WHOSE" "$(printf '%s' "$OUT" | tail -n +2)" >&2
    exit 2 ;;
  INFORM*)
    # ⚠ §2120 — STDERR, NOT STDOUT, AND THIS IS THE DEFECT THE HOOK FOUND IN ITSELF.
    # §2116 printed the informational line to stdout. Its first live firing came back as
    # "[eugo-review-turn-end.sh]: No stderr output" — the harness reports a Stop hook's
    # STDERR, so everything the inform path wrote went into the void and no finding could
    # ever reach the model. That is the exact failure this hook exists to prevent, shipped
    # inside the hook meant to prevent it. Exit stays 0: informing must never interrupt.
    printf 'review watch: %s\n' "$(printf '%s' "$OUT" | tail -n +2 | tr '\n' ' ')" >&2 ;;
esac
exit 0
