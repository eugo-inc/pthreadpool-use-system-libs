#!/usr/bin/env bash
# §2980 — the PROMPT hook: hand the model, at the moment a prompt is submitted, the one or
# two lines it needs and does not have.
#
# WHY THIS EXISTS. Two failures with the same shape — the model lacked one sentence at the
# one moment it mattered, and no surface could deliver it then:
#   - an operator shorthand ("eipl this: §1.45") whose only definition lived in a KB fact
#     the session had not searched, so the token did nothing until the operator typed
#     "check eugo-kb" (measured 2026-09-18: 0 hits in any repo, rule or skill; 1 KB fact);
#   - a usage-limit line ("You've hit your weekly limit · resets …") recorded as a synthetic
#     ASSISTANT turn, so after the operator switched account the model kept behaving as if
#     quota were exhausted; the harness's own "usage limit has reset" notice was followed
#     ONE SECOND later by a newer limit record (this repo's session c6d0d255, 2026-09-18).
# `UserPromptSubmit` is the only event that fires between the operator's keystroke and the
# model's read of it, and its exit-0 stdout is added to the model's context (PROBED
# 2026-09-19 in a throwaway dir: the model quoted a word that existed only in hook output).
#
# ONE FILE, INDEPENDENT ARMS. Each arm is a function that prints zero or more context lines
# on stdout and returns 0. MAIN runs each inside its own `$(…)` subshell, so an arm that
# dies, `exit`s or prints garbage cannot silence another arm or change this script's exit
# status. The arm bodies hold their python as heredocs inside the FUNCTION (never lexically
# inside `$(…)`: bash 3.2's paren/quote scanning of a command substitution is the trap).
#
# PAYLOAD. Measured on the installed CLI (2026-09-19): the stdin JSON carries
# `prompt` (the text), `session_id`, `transcript_path`, `cwd`, `hook_event_name`,
# `permission_mode`, `prompt_id`. `user_prompt` and `prompt_text` are read as tolerant
# fallbacks; a docs summariser reported each of them as the key and both were wrong.
#
# Contract (each line is a test in tools/tests/test_prompt_context_hook.py):
#   - every path exits 0; nothing on stderr, ever
#   - nothing matches -> stdout empty and python3 never started (the common path is one
#     `cat`, one `sed` and a bash loop)
#   - glossary arm: whole-word, case-insensitive match of a glossary token in the PROMPT
#     only (never in cwd / transcript_path); a token at the start of a later line matches;
#     a `/slash` token needs start-of-text or whitespace before it; one line per matched
#     token, at most 5 lines, each meaning cut at 600 chars, control characters stripped
#   - the glossary is the `## Shorthand glossary` section of .claude/rules/eugo-central.md
#     when present (one `- `token` — meaning` line per entry, as the central instructions
#     state), else the embedded fallback table below
#   - quota arm: prints ONE `QUOTA STATE:` block when the newest main-thread usage-limit
#     record in the transcript has no real assistant turn after it; silent otherwise;
#     reads at most the last EUGO_QUOTA_TAIL_BYTES (default 1 MiB) / 300 lines; a throttle
#     (`API Error: …`) is not a limit; sidechain records count for nothing
#   - effort arm (§3801): prints ONE `EFFORT STATE (<prior>→<current>)` line when the newest
#     `SessionStart:resume` record in the transcript separates main-chain turns at one effort
#     from turns at another and no `/effort` command explains it (`/model` does not: it falls
#     back to the new model's default); silent once a turn is back at <prior>, once any hook
#     already printed that pair (or the resume arm spoke for this resume), and without a resume
#     in the tail — python starts only past that grep. Reads at most the last
#     EUGO_EFFORT_TAIL_BYTES (default 4 MiB). It reads the TRANSCRIPT because `$CLAUDE_EFFORT`
#     is never set in a UserPromptSubmit hook (measured 2026-09-25, -p and interactive)
#   - context arm (§3803): past the SECOND auto-compaction (or one that left >= 10% of the
#     compaction point) and at >= 80% of that point (A = window - 33k; the window is 1M on any
#     1M evidence — a fill or preTokens past 200k, a `[1m]` modelId — else 200k;
#     EUGO_CONTEXT_WINDOW overrides) prints ONE `CONTEXT STATE:` line per compaction cycle, and
#     ONE `CONTEXT STATE (imminent):` line at >= 95%, each writing a hand-off file
#     `.claude/data/handoff/<UTC>-<sid8>.md` (mode 0640, git-ignored) with a paste-ready
#     continuation prompt. Silent once said this cycle or once a hand-off for this session is
#     newer than the newest compaction. NOT a stop. Python starts only when the newest usage in
#     the last 1 MiB reaches the smallest window's 80% (133.6k)
#   - SESSION START (§3801): the same script bound to SessionStart `resume` runs ONLY the two
#     resume arms. Effort-resume: ultracode on before the resume (the newest `ultra_effort_enter|exit` or
#     `/effort <level>` record says so) and nothing re-enabling it — no `--effort ultracode`
#     on `$CLAUDE_PID`'s argv (an explicit `--effort <other>` wins over settings, measured),
#     no `"ultracode": true` in managed > flag > local > project > user settings — prints ONE
#     `EFFORT STATE (ultracode→off)` line before the first prompt: a resume records its
#     `ultra_effort_exit` only AFTER the first prompt's hook has run. Outage (§3802): EVERY
#     resume prints ONE `OUTAGE STATE:` line — the gap (the payload's
#     `seconds_since_last_response`, else the newest main-chain timestamp), the last main-chain
#     `tool_use` left without a `tool_result` (name + 120 chars of its input) or that none was,
#     and the orphan check before any re-run; without python3 the line prints minus the
#     pending-call detail. Any other source (startup, compact, clear): silent
#   - EUGO_REVIEW_SUBPROCESS set -> silent (a reviewer is not a session to inform);
#     EUGO_PROMPT_CONTEXT_OFF set -> silent (the kill switch, every arm)
#   - malformed or empty stdin, no python3, unreadable transcript -> silent
#   - bash 3.2 safe (no mapfile, no ${x,,}, no associative arrays)
#   - an errexit INHERITED through BASH_ENV is disarmed before anything else runs
#
# §3143 — THE DISARM COMES FIRST (fact 7664bbb3e4c7: every kit hook started from `set -u`
# alone). The eugo deploy image's BASH_ENV turns on `set -eE -o pipefail` (fact 76fb0dc9202e)
# for EVERY non-interactive bash, this hook included whenever Claude Code runs in the
# devcontainer.
# Under it the `transcript_path` extraction in MAIN — a `grep -o` with no match, failing
# through `pipefail` — ended this hook before either arm printed: measured, a non-zero exit
# (97 under the test's trap) for any payload without that key, malformed stdin included.
# A payload that carries the key (every real one, per PAYLOAD above) was unaffected.
# The cure is the one protomolecule f73c6ba408 (Ben) gave the publish guard.
set +eE +o pipefail
trap - ERR
set -u

ROOT="${CLAUDE_PROJECT_DIR:-.}"
RULES="$ROOT/.claude/rules/eugo-central.md"

IN="$(cat 2>/dev/null || true)"
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi
if [ -n "${EUGO_PROMPT_CONTEXT_OFF:-}" ]; then
  exit 0
fi
if [ -z "$IN" ]; then
  exit 0
fi

# The embedded fallback: SHORT meanings, one line each, the same `- `token` — meaning`
# shape the served section uses. The served section wins whenever the rules file has it.
GLOSSARY_FALLBACK='- `eipl` — "explain in plain language": LOOK the reference up first (a §-id in the backlog files, a file, a ledger row, a commit), then the KB; then ONE jargon-free paragraph (what it is, why it matters, where it stands, what is pending, what decision is the user'"'"'s), technical detail after. Never explain from memory.
- `eipws` — "execute in parallel with workflow subagents": run the named items (or the pending task-list items) as parallel Workflow agents rather than inline; the token IS the Workflow opt-in.
- `eipwsncwtodo` — "execute in parallel with workflow subagents, the ncw todo list": fan out EVERY unblocked, parallelisable task-widget item as Workflow lanes now (the token IS the opt-in); `eipws` with the list taken from the widget. Re-test `blocked` labels first, name what you excluded, and follow the capped-wave controls in `eugo-parallel-fanout-base`.
- `elaw` / `/law` — Ben'"'"'s L/A/W questions, answered only for the letters typed, in L → A → W order: L = what is LEFT, A = is an ADVERSARIAL review warranted, W = is everything WRITTEN BACK to the file the prompt came from. Skill eugo-law, slash /elaw.
- `ncw` — the native chat widget (AskUserQuestion in Claude Code); as a bare instruction it means the same as `amqncw`.
- `amqncw` — "ask me question(s) in the native chat widget": put every open question or decision through AskUserQuestion now, one question per decision, options spelled out.
- `eresume` / `/eresume` — resume interrupted work after a usage limit, account switch, SSH drop, crash or compaction: name the CAUSE first; this response proves quota; check for orphans (a backgrounded or container-side run, a held lock) before re-running anything, never killing on a guess; re-check effort and ultracode; read git + STATE.md + breadcrumbs + the plan, name the exact call that died, re-run it. User-only skill eugo-resume.
- `essh` — "resume after an SSH drop or crash": `eresume` with the cause known — orphans first (never kill on a guess), then effort and ultracode, then the last durable state and the call that died. Alias of the user-only skill eugo-resume.
- `epublish` / `/epublish <draft>` — publish ONE external draft the operator names: scrub, show target + exact command, run it (the publish guard asks the operator), backfill the URL. User-only skill eugo-publish; never unnamed, never headless.
- `enext` / `/enext [N2 | §id | all]` — plan the NEXT items: resolve the last report'"'"'s NEXT-N lines (or the named §-ids), verify each with the grep gates + DUPLICATE + OWNER, ask items · duration · involvement, file what is unfiled, write a plan file /eugo-run-overnight executes unchanged. Skill eugo-plan-next-base (adapter /eugo-plan-next).'

glossary_lines() {
  # The served section, else the fallback. sed's range end is searched from the line AFTER
  # the start, so the start line's own `## ` does not close it; the FIRST section wins.
  local out=""
  if [ -r "$RULES" ]; then
    out="$(sed -n '/^## Shorthand glossary/,/^## /{/^- `/p;}' "$RULES" 2>/dev/null)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$GLOSSARY_FALLBACK"
  fi
}

arm_glossary() {
  local lines line rest tok hit=0
  lines="$(glossary_lines)"
  # PRE-FILTER in pure bash (no forks), deliberately over-matching — substring, whole
  # payload, case-insensitive: it only decides whether python is worth starting. The
  # `shopt` is scoped to this arm's subshell.
  shopt -s nocasematch
  while IFS= read -r line; do
    case "$line" in '- `'*) ;; *) continue ;; esac
    rest="${line%% — *}"
    while [ "$rest" != "${rest#*\`}" ]; do   # another `token` in the head
      rest="${rest#*\`}"                      # drop through the opening backtick
      tok="${rest%%\`*}"                      # the token
      rest="${rest#*\`}"                      # drop the token and its closing backtick
      tok="${tok#/}"
      if [ -n "$tok" ] && [[ "$IN" == *"$tok"* ]]; then
        hit=1
        break
      fi
    done
    if [ "$hit" = 1 ]; then
      break
    fi
  done <<EOF
$lines
EOF
  if [ "$hit" != 1 ]; then
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 0
  # The payload on stdin, the program on fd 3 (a heredoc), the glossary in an env var that
  # deliberately carries no EUGO_ prefix (it is not a configuration knob).
  printf '%s' "$IN" | PC_GLOSSARY="$lines" PYTHONUTF8=1 python3 -S /dev/fd/3 3<<'PY' 2>/dev/null || true
import json, os, re, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
p = next((d[k] for k in ("prompt", "user_prompt", "prompt_text")
          if isinstance(d.get(k), str) and d[k].strip()), "")
if not p:
    sys.exit(0)
out = []
for line in os.environ.get("PC_GLOSSARY", "").splitlines():
    if not line.startswith("- `"):
        continue
    head, sep, meaning = line.partition(" — ")
    if not sep:
        continue
    for t in re.findall(r"`([^`]+)`", head):
        left = r"(?:^|(?<=\s))" if t.startswith("/") else r"(?<![A-Za-z0-9_/-])"
        if re.search(left + re.escape(t) + r"(?![A-Za-z0-9_-])", p, re.I | re.M):
            m = re.sub(r"[\x00-\x1f\x7f]", " ", meaning).strip()[:600]
            out.append("eugo shorthand `%s` — %s" % (t, m))
            break
    if len(out) >= 5:
        break
for o in out:
    print(o)
PY
  return 0
}

arm_quota() {
  # $1 = transcript_path. Structured record first (`isApiErrorMessage` + `quotaLimits`),
  # the text form second ("You've hit|reached your … limit" on a 429), the harness's
  # informational "Usage limit reached" line third. A real assistant turn AFTER the newest
  # limit means the session already resumed: silent. Measured shapes: 991 session/weekly
  # records with `quotaLimits.status="rejected"`, 44 model-limit records with quotaLimits
  # NULL, 50+ throttles sharing the 429 — so neither field alone is the discriminator.
  local tp="${1:-}" cap hits
  [ -n "$tp" ] || return 0
  [ -r "$tp" ] || return 0
  cap="${EUGO_QUOTA_TAIL_BYTES:-1048576}"
  case "$cap" in ''|*[!0-9]*) cap=1048576 ;; esac
  # cheap gate: python never starts on the common path (grep -c, not -q: no SIGPIPE)
  hits="$(tail -c "$cap" "$tp" 2>/dev/null | grep -a -c -e 'isApiErrorMessage' -e 'Usage limit reached' 2>/dev/null)" || true
  case "${hits:-0}" in ''|0|*[!0-9]*) return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -S - "$tp" "$cap" 300 <<'PY' 2>/dev/null || true
import json, re, sys, time
path, cap, max_lines = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
QUOTA_TEXT = re.compile(r"^You've (hit|reached) your .{0,60}limit")
INFO_TEXT = re.compile(r"^Usage limit reached")
def first_text(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and isinstance(b.get("text"), str):
                return b["text"]
    return ""
try:
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell(); f.seek(max(0, size - cap)); blob = f.read()
except OSError:
    sys.exit(0)
lines = blob.split(b"\n")
if size > cap:
    lines = lines[1:]          # the first line of a cut window is partial
limit, real_after = None, False
for raw in lines[-max_lines:]:
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(r, dict) or r.get("isSidechain"):
        continue               # a subagent is ONE arm, never the session
    t = r.get("type")
    if t == "assistant":
        if r.get("isApiErrorMessage") is True:
            q, text = r.get("quotaLimits"), first_text(r)
            hard = (isinstance(q, dict) and q.get("status") == "rejected") or (
                r.get("apiErrorStatus") == 429 and bool(QUOTA_TEXT.match(text)))
            if hard:
                limit = {"ts": r.get("timestamp") or "?", "text": text,
                         "q": q if isinstance(q, dict) else {}}
                real_after = False
            continue           # a throttle / 529 / login error: neither a limit nor a turn
        if (r.get("message") or {}).get("model") == "<synthetic>":
            continue
        if limit is not None:
            real_after = True
    elif t == "system" and r.get("subtype") == "informational":
        c = r.get("content")
        if isinstance(c, str) and INFO_TEXT.match(c) and (limit is None or real_after):
            limit = {"ts": r.get("timestamp") or "?", "text": c, "q": {}}
            real_after = False
if limit is None or real_after:
    sys.exit(0)
resets = limit["q"].get("resetsAt")
when = "resetsAt unknown"
if isinstance(resets, (int, float)) and resets > 0:
    when = "resetsAt " + time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(resets))
text = " ".join(limit["text"].split())[:160]
print('QUOTA STATE: this prompt is being processed, so the limit recorded at %s ("%s", %s) '
      'no longer binds this session — the account or model was switched, or the window reset. '
      'Resume from the last durable state (git status/log, STATE.md, breadcrumbs, the plan); '
      're-issue the tool calls that failed with that error; never defer, skip, or file work as '
      'blocked on quota grounds; one arm\'s limit (a review or a subagent) is not a campaign-wide '
      'block. [central §quota]' % (limit["ts"], text, when))
PY
  return 0
}

arm_effort() {
  # $1 = transcript_path. §3801 — part 1 of the effort check: the newest resume separates
  # turns at one effort from turns at another. The gate is the resume record itself, so a
  # session that never restarted never starts python.
  local tp="${1:-}" cap hits
  [ -n "$tp" ] || return 0
  [ -r "$tp" ] || return 0
  cap="${EUGO_EFFORT_TAIL_BYTES:-4194304}"
  case "$cap" in ''|*[!0-9]*) cap=4194304 ;; esac
  hits="$(tail -c "$cap" "$tp" 2>/dev/null | grep -a -c -e 'SessionStart:resume' 2>/dev/null)" || true
  case "${hits:-0}" in ''|0|*[!0-9]*) return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -S - "$tp" "$cap" <<'PY' 2>/dev/null || true
import json, sys
path, cap = sys.argv[1], int(sys.argv[2])
def text_of(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b["text"] for b in c if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""
try:
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell(); f.seek(max(0, size - cap)); blob = f.read()
except OSError:
    sys.exit(0)
lines = blob.split(b"\n")
if size > cap:
    lines = lines[1:]          # the first line of a cut window is partial
ev = []                        # (kind, value) in transcript order, main chain only
for raw in lines:
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(r, dict) or r.get("isSidechain"):
        continue
    t = r.get("type")
    if t == "assistant":
        m = r.get("message") or {}
        if r.get("isApiErrorMessage") is True or m.get("model") == "<synthetic>":
            continue
        e = r.get("effort")
        if isinstance(e, str) and e:
            ev.append(("effort", (e, m.get("model") or "")))
    elif t == "attachment":
        a = r.get("attachment")
        if not isinstance(a, dict):
            continue
        said = "%s %s" % (a.get("content") or "", a.get("stdout") or "")
        if a.get("hookName") == "SessionStart:resume":
            ev.append(("boundary", (r.get("timestamp") or "?", said)))
        elif a.get("type") in ("ultra_effort_enter", "ultra_effort_exit"):
            ev.append(("ultra", a["type"]))
        elif "EFFORT STATE (" in said:
            ev.append(("said", said))
    elif t == "user":
        s = text_of(r)
        # ONLY a deliberate EFFORT choice explains a change; `/model` alone falls back to the
        # new model's default (measured: c6d0d255, Opus 5 xhigh -> /model Opus 5.5 -> medium).
        if "<command-name>/effort</command-name>" in s or "Set effort level to" in s:
            ev.append(("cmd", s))
        elif "Set model to" in s and "effort" in s.lower():
            ev.append(("cmd", s))
b = max((i for i, (k, _) in enumerate(ev) if k == "boundary"), default=None)
if b is None:
    sys.exit(0)
bts = ev[b][1][0]
pre = [(i, v) for i, (k, v) in enumerate(ev[:b]) if k == "effort"]
post = [v for k, v in ev[b + 1:] if k == "effort"]
if not pre or not post:
    sys.exit(0)
last_i, (prior, m1) = pre[-1]
# ONE resume writes one `SessionStart:resume` record per hook that printed, in FINISH order
# (watch:9389f199a4), so the resume arm's record need not be the last: read every boundary
# record between the last pre-resume turn and the newest one.
if any(k == "boundary" and "EFFORT STATE (" in v[1] for k, v in ev[last_i + 1:b + 1]):
    sys.exit(0)                # the resume arm already spoke for this resume
current, m2 = post[-1]
if current == prior:
    sys.exit(0)                # unchanged, or already back at the prior level
if any(k == "cmd" for k, _ in ev[last_i + 1:]):
    sys.exit(0)                # the operator chose it
tag = "EFFORT STATE (%s→%s)" % (prior, current)
if any(k == "said" and tag in v for k, v in ev[b + 1:]):
    sys.exit(0)                # already said for this pair
ultra = [v for k, v in ev[:b] if k == "ultra"]
want = "ultracode" if ultra and ultra[-1] == "ultra_effort_enter" else prior
models = " (model %s → %s)" % (m1, m2) if m1 and m2 and m1 != m2 else ""
print("%s: replies in this session ran at effort %s before it was resumed at %s and at %s since%s; "
      "no /effort command explains the change — a resume restores neither the effort level nor "
      "ultracode, and /model falls back to the new model's default. Ask the operator "
      "(AskUserQuestion) whether to type /effort %s now. [central §resume]"
      % (tag, "ultracode (xhigh)" if want == "ultracode" else prior, bts, current, models, want))
PY
  return 0
}

arm_effort_resume() {
  # $1 = transcript_path. §3801 — part 2, bound to SessionStart `resume`: the ultracode loss,
  # said before the first prompt. The gate: an ultracode record anywhere in the tail.
  local tp="${1:-}" cap hits
  [ -n "$tp" ] || return 0
  [ -r "$tp" ] || return 0
  cap="${EUGO_EFFORT_TAIL_BYTES:-4194304}"
  case "$cap" in ''|*[!0-9]*) cap=4194304 ;; esac
  hits="$(tail -c "$cap" "$tp" 2>/dev/null | grep -a -c -e 'ultra_effort_enter' -e 'command-args>ultracode' -e 'effort level to ultracode' 2>/dev/null)" || true
  case "${hits:-0}" in ''|0|*[!0-9]*) return 0 ;; esac
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -S - "$tp" "$cap" <<'PY' 2>/dev/null || true
import json, os, re, subprocess, sys
path, cap = sys.argv[1], int(sys.argv[2])
CMD = re.compile(r"<command-name>/effort</command-name>.*?<command-args>\s*([A-Za-z]*)\s*</command-args>", re.S)
SET = re.compile(r"Set effort level to ([A-Za-z]+)")
def text_of(rec):
    c = (rec.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b["text"] for b in c if isinstance(b, dict) and isinstance(b.get("text"), str))
    return ""
try:
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell(); f.seek(max(0, size - cap)); blob = f.read()
except OSError:
    sys.exit(0)
lines = blob.split(b"\n")
if size > cap:
    lines = lines[1:]
on = None                      # the newest ultracode state before this resume
for raw in lines:
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(r, dict) or r.get("isSidechain"):
        continue
    t = r.get("type")
    if t == "attachment":
        a = r.get("attachment")
        if isinstance(a, dict) and a.get("type") == "ultra_effort_enter":
            on = True
        elif isinstance(a, dict) and a.get("type") == "ultra_effort_exit":
            on = False
    elif t == "user":
        s = text_of(r)
        m = CMD.search(s) or SET.search(s)
        if m and m.group(1):
            on = m.group(1).lower() == "ultracode"
if on is not True:
    sys.exit(0)

def argv_of(pid):
    try:
        with open("/proc/%s/cmdline" % pid, "rb") as f:
            return [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except OSError:
        pass
    try:                       # macOS: no /proc; `ps` splits on spaces, good enough for flags
        out = subprocess.run(["ps", "-o", "args=", "-p", pid], capture_output=True, text=True, timeout=3)
        return out.stdout.split()
    except (OSError, subprocess.SubprocessError):
        return []
pid = os.environ.get("CLAUDE_PID", "")
argv = argv_of(pid) if pid.isdigit() else []
flag_effort = flag_settings = None
for i, tok in enumerate(argv):
    if tok == "--effort" and i + 1 < len(argv):
        flag_effort = argv[i + 1]
    elif tok.startswith("--effort="):
        flag_effort = tok.split("=", 1)[1]
    elif tok == "--settings" and i + 1 < len(argv):
        flag_settings = argv[i + 1]
    elif tok.startswith("--settings="):
        flag_settings = tok.split("=", 1)[1]
if flag_effort is not None:
    if flag_effort.lower() == "ultracode":
        sys.exit(0)            # the flag re-enables it, and a flag beats every settings file
else:
    def load(src):
        try:
            if src.lstrip().startswith("{"):
                d = json.loads(src)
            else:
                with open(src, encoding="utf-8") as f:
                    d = json.load(f)
        except (OSError, ValueError):
            return None
        v = d.get("ultracode") if isinstance(d, dict) else None
        return v if isinstance(v, bool) else None
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or "."
    sources = [os.path.join(cfg, "settings.json"),                      # user (lowest)
               os.path.join(proj, ".claude", "settings.json"),          # project
               os.path.join(proj, ".claude", "settings.local.json")]    # local
    if flag_settings:
        sources.append(flag_settings)                                    # --settings
    sources += ["/etc/claude-code/managed-settings.json",                # managed (highest)
                "/Library/Application Support/ClaudeCode/managed-settings.json"]
    effective = None
    for src in sources:
        v = load(src)
        if v is not None:
            effective = v
    if effective is True:
        sys.exit(0)
print("EFFORT STATE (ultracode→off): this session ran with ultracode before this resume, and a "
      "resume does not restore it — the harness drops it and the next reply runs at the model's "
      "default effort (measured 2026-09-25); nothing here re-enables it (no --effort ultracode on "
      "this claude process, no \"ultracode\": true in the settings it reads). Before any work runs, "
      "ask the operator (AskUserQuestion) whether to type /effort ultracode. [central §resume]")
PY
  return 0
}

fmt_gap() {
  # $1 = seconds -> "2h 5m" / "11m 48s" (bash 3.2 arithmetic, no fork)
  local s="$1" h m
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm %ds' "$m" $((s % 60))
  fi
}

arm_outage() {
  # $1 = transcript_path, $2 = the payload's `seconds_since_last_response` (may be empty).
  # §3802 — every resume: the dead process's children did not come back with the transcript.
  # Python only adds the pending-call detail; without it the line still prints.
  local tp="${1:-}" gap="${2:-}" cap now g
  case "$gap" in ''|*[!0-9]*) gap="" ;; esac
  cap="${EUGO_EFFORT_TAIL_BYTES:-4194304}"
  case "$cap" in ''|*[!0-9]*) cap=4194304 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || now="?"
  if [ -n "$tp" ] && [ -r "$tp" ] && command -v python3 >/dev/null 2>&1; then
    python3 -S - "$tp" "$cap" "$gap" "$now" <<'PY' 2>/dev/null && return 0
import calendar, json, re, sys, time
path, cap, gap, now = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(path, "rb") as f:
    f.seek(0, 2); size = f.tell(); f.seek(max(0, size - cap)); blob = f.read()
lines = blob.split(b"\n")
if size > cap:
    lines = lines[1:]
pending, last_ts = {}, None
for raw in lines:
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(r, dict) or r.get("isSidechain"):
        continue
    ts = r.get("timestamp")
    if isinstance(ts, str) and ts:
        last_ts = ts
    c = (r.get("message") or {}).get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if not isinstance(b, dict):
            continue
        if r.get("type") == "assistant" and b.get("type") == "tool_use":
            pending[b.get("id")] = (b.get("name") or "?", b.get("input"))
        elif r.get("type") == "user" and b.get("type") == "tool_result":
            pending.pop(b.get("tool_use_id"), None)
secs = int(gap) if gap else None
if secs is None and last_ts:
    try:
        secs = int(time.time()) - calendar.timegm(time.strptime(last_ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        secs = None
if secs is None or secs < 0:
    when = "an unknown time"
elif secs >= 3600:
    when = "%dh %dm" % (secs // 3600, secs % 3600 // 60)
else:
    when = "%dm %ds" % (secs // 60, secs % 60)
if pending:
    name, inp = list(pending.values())[-1]
    what = inp.get("command") if isinstance(inp, dict) and isinstance(inp.get("command"), str) else json.dumps(inp)
    what = re.sub(r"[\x00-\x1f\x7f`]", " ", str(what)).strip()[:120]
    detail = ("Its last tool call never returned a result: %s `%s` — it may still be running, or may have "
              "half-run." % (name, what))
else:
    detail = ("No tool call was left without a result, but a backgrounded or container-side run the old "
              "process started can still be going.")
print("OUTAGE STATE: this session's Claude process stopped and was resumed at %s, %s after its last "
      "response (an SSH drop, crash, kill or exit — a resume restores the transcript, not the processes "
      "it started). %s Before re-running anything, check for orphans (a backgrounded or container-side "
      "run, a held lock) and wait for them or ask the operator — never kill on a guess; then resume from "
      "git and the plan. [central §resume · eresume / essh]" % (now, when, detail))
PY
  fi
  if [ -n "$gap" ]; then
    g="$(fmt_gap "$gap")"
  else
    g="an unknown time"
  fi
  printf '%s\n' "OUTAGE STATE: this session's Claude process stopped and was resumed at $now, $g after its last response (an SSH drop, crash, kill or exit — a resume restores the transcript, not the processes it started). Whether a tool call was left pending is not known here (no python3). Before re-running anything, check for orphans (a backgrounded or container-side run, a held lock) and wait for them or ask the operator — never kill on a guess; then resume from git and the plan. [central §resume · eresume / essh]"
  return 0
}

arm_context() {
  # $1 = transcript_path, $2 = session_id. §3803 — past the second auto-compaction (or one that
  # left a heavy floor) and near the next one: warn ONCE per compaction cycle, once more when
  # it is imminent, and write a hand-off file. Never a stop. The gate: the newest usage numbers
  # in the last 1 MiB against the smallest window's warning point (no python below it).
  local tp="${1:-}" sid="${2:-}" u w fill gate
  [ -n "$tp" ] || return 0
  [ -r "$tp" ] || return 0
  u="$(tail -c 1048576 "$tp" 2>/dev/null | grep -a -o -E '"usage"[[:space:]]*:[[:space:]]*[{][[:space:]]*"input_tokens"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*"cache_read_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' 2>/dev/null | tail -n 1)" || true
  [ -n "$u" ] || return 0
  set -- $(printf '%s' "$u" | sed 's/[^0-9][^0-9]*/ /g')
  [ $# -eq 3 ] || return 0
  fill=$(($1 + $2 + $3))
  w="${EUGO_CONTEXT_WINDOW:-}"
  case "$w" in ''|*[!0-9]*) w="" ;; esac
  gate=$(((${w:-200000} - 33000) * 4 / 5))
  [ "$fill" -ge "$gate" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -S - "$tp" "$sid" "${CLAUDE_PROJECT_DIR:-.}" "$w" <<'PY' 2>/dev/null || true
import calendar, collections, json, os, re, subprocess, sys, time
path, sid, root, wover = sys.argv[1:5]
MARGIN, WARN, IMM, FLOOR = 33000, 0.80, 0.95, 0.10
PLAN = re.compile(r"(?:~|/[A-Za-z0-9._/-]*)/\.claude/plans/[A-Za-z0-9._-]+\.md")
def ep(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None
comps, post, bts, one_m, said, said_imm = 0, None, None, False, False, False
ultra, plan = None, None
recent = collections.deque(maxlen=64)       # raw lines that may carry the newest main-chain usage
with open(path, "rb") as f:
    for raw in f:
        if b"compact_boundary" in raw:
            try:
                r = json.loads(raw)
            except ValueError:
                r = None
            if isinstance(r, dict) and r.get("type") == "system" and r.get("subtype") == "compact_boundary" \
                    and not r.get("isSidechain"):
                cm = r.get("compactMetadata") or {}
                comps += 1
                post = cm.get("postTokens") if isinstance(cm.get("postTokens"), int) else None
                if isinstance(cm.get("preTokens"), int) and cm["preTokens"] > 200000:
                    one_m = True
                bts, said, said_imm = r.get("timestamp"), False, False
                recent.clear()
                continue
        if b"CONTEXT STATE" in raw:
            try:
                r = json.loads(raw)
            except ValueError:
                r = None
            a = r.get("attachment") if isinstance(r, dict) else None
            if isinstance(a, dict) and str(a.get("type", "")).startswith("hook_"):
                said_txt = "%s %s" % (a.get("content") or "", a.get("stdout") or "")
                if "CONTEXT STATE (imminent)" in said_txt:
                    said_imm = said = True
                elif "CONTEXT STATE:" in said_txt:
                    said = True
        if b'"modelId"' in raw and b"[1m]" in raw:
            one_m = True
        if b"ultra_effort_" in raw or b"/effort</command-name>" in raw or b"Set effort level to" in raw:
            m = re.search(rb"ultra_effort_(enter|exit)|<command-args>\s*([A-Za-z]+)\s*</command-args>|Set effort level to ([A-Za-z]+)", raw)
            if m:
                v = (m.group(1) or m.group(2) or m.group(3) or b"").decode()
                ultra = v in ("enter", "ultracode")
        if b"/.claude/plans/" in raw:
            hits = PLAN.findall(raw.decode("utf-8", "replace"))
            if hits:
                plan = hits[-1]
        if b'"usage"' in raw and b'"assistant"' in raw:
            recent.append(raw)
fill = effort = None
for raw in reversed(recent):
    try:
        r = json.loads(raw)
    except ValueError:
        continue
    if not isinstance(r, dict) or r.get("isSidechain") or r.get("type") != "assistant":
        continue
    u = (r.get("message") or {}).get("usage")
    if not isinstance(u, dict):
        continue
    fill = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    effort = r.get("effort") if isinstance(r.get("effort"), str) else None
    break
if fill is None:
    sys.exit(0)
if fill > 200000:
    one_m = True
W = int(wover) if wover else (1000000 if one_m else 200000)
A = W - MARGIN
if not (comps >= 2 or (post or 0) >= FLOOR * A) or fill < WARN * A:
    sys.exit(0)
sid8 = re.sub(r"[^A-Za-z0-9-]", "", sid)[:8] or "session"
hdir = os.path.join(root, ".claude", "data", "handoff")
b_ep = ep(bts)
try:
    for name in os.listdir(hdir):
        if name.endswith("-%s.md" % sid8) and b_ep is not None and os.path.getmtime(os.path.join(hdir, name)) > b_ep:
            said = True        # a hand-off already written this cycle
except OSError:
    pass
if fill >= IMM * A and not said_imm:
    kind = "imminent"
elif not said:
    kind = "warn"
else:
    sys.exit(0)

def run(args, limit=60):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return "(unavailable)"
    if out.returncode != 0:
        return "(unavailable)"         # e.g. not a git checkout: never paste an error as a value
    lines = (out.stdout or "").rstrip("\n").splitlines()
    return "\n".join(ln[:200] for ln in lines[:limit]) or "(empty)"
now = time.gmtime()
stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", now)
fname = os.path.join(hdir, "%s-%s.md" % (time.strftime("%Y%m%dT%H%M%SZ", now), sid8))
branch = run(["git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"], 1)
sha = run(["git", "-C", root, "rev-parse", "--short=12", "HEAD"], 1)
has_sha = re.fullmatch(r"[0-9a-f]{7,40}", sha) is not None
level = "ultracode" if ultra else (effort or "xhigh")
since = ("log --oneline %s..HEAD" % sha) if has_sha else "log --oneline -10"
state_md = os.path.join(root, ".claude", "docs", "guardrails", "STATE.md")
try:
    state = "".join(open(state_md, encoding="utf-8", errors="replace").readlines()[:80]) \
        if time.time() - os.path.getmtime(state_md) < 86400 else "(older than 24 h — not copied)"
except OSError:
    state = "(none)"
procs = run(["ps", "-u", str(os.getuid()), "-o", "pid=,etime=,args="], 400)
keep = re.compile(r"pytest|docker|make |eugo-|with-heavy-lock|codex_|claude -p|vitest|embed")
procs = "\n".join(ln for ln in procs.splitlines() if keep.search(ln))[:6000] or "(none matched)"
body = """# Hand-off — session %(sid)s, %(stamp)s

- user: %(user)s · repo: %(root)s @ %(branch)s · HEAD %(sha)s
- context: %(fill)d tokens of a %(W)d window (auto-compaction near %(A)d); auto-compactions so far: %(comps)d
- effort of the newest turn: %(effort)s · ultracode: %(ultra)s
- plan: %(plan)s

## Continue in a FRESH session

1. In THIS session: `/exit` (one writer per branch).
2. From a shell: `cd %(root)s && claude --effort %(level)s`
3. Paste as the first message:

       eresume handoff %(fname)s

   then, standalone:
   1) Read %(fname)s in full — every line is as of %(stamp)s.
   2) `git -C %(root)s %(since)s` — what landed after this hand-off.
   3) `git -C %(root)s status` — compare with the snapshot below; never discard what you did not write.
   4) Confirm this session runs at effort %(level)s (`/effort %(level)s` if not).
   5) Open the plan and continue at its first unfinished item.

Not a stop: the old session keeps working until the operator switches.

## git status (at hand-off)

```
%(status)s
```

## git stash list

```
%(stash)s
```

## STATE.md (shared by concurrent sessions — may be another session's)

%(state)s

## Your processes (at hand-off; filtered)

```
%(procs)s
```
""" % dict(sid=sid, stamp=stamp, user=os.environ.get("USER") or str(os.getuid()), root=root, branch=branch,
           sha=sha, fill=fill, W=W, A=A, comps=comps, effort=effort or "unknown",
           ultra={True: "on", False: "off", None: "unknown"}[ultra], plan=plan or "(none named in the transcript)",
           level=level, fname=fname, since=since, status=run(["git", "-C", root, "status", "--short", "-b"]),
           stash=run(["git", "-C", root, "stash", "list"], 20), state=state, procs=procs)
os.makedirs(hdir, exist_ok=True)
fd = os.open(fname, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(body)
os.chmod(fname, 0o640)
ncomp = "%d auto-compaction%s" % (comps, "" if comps == 1 else "s")
left = " (the newest left %dk)" % (post // 1000) if isinstance(post, int) else ""
if kind == "imminent":
    print("CONTEXT STATE (imminent): this session's context holds %dk tokens of its %dk window, within 5%% of the "
          "next auto-compaction, after %s%s. The hand-off is refreshed: %s — tell the operator (AskUserQuestion) and "
          "offer its continuation prompt before the summary replaces this context. Not a stop — keep working until the "
          "operator switches. [central §resume]" % (fill // 1000, W // 1000, ncomp, left, fname))
else:
    print("CONTEXT STATE: this session's context holds %dk tokens of its %dk window after %s%s; each compaction "
          "summarises the last summary, so a FRESH session will serve the rest of this work better. A hand-off with a "
          "paste-ready continuation prompt is written: %s — tell the operator (AskUserQuestion) and offer it. Not a stop "
          "— keep working until the operator switches. [central §resume]" % (fill // 1000, W // 1000, ncomp, left, fname))
PY
  return 0
}

# ---- MAIN ----
# The FIRST occurrence, never the last: a prompt that quotes the literal key must not
# redirect the quota arm (greedy `.*` took the last match). And only a `.jsonl` path is
# ever read.
TP="$(printf '%s' "$IN" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
case "$TP" in *.jsonl) ;; *) TP="" ;; esac
# §3801 — the same script is bound to SessionStart `resume`; there ONLY the resume arm runs
# (a prompt arm would speak twice: once now, once at the first prompt). A quoted key inside
# the prompt is JSON-escaped (`\"`), so it cannot match these patterns.
EV="$(printf '%s' "$IN" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
if [ "$EV" = "SessionStart" ]; then
  SRC="$(printf '%s' "$IN" | grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  if [ "$SRC" = "resume" ]; then
    GAP="$(printf '%s' "$IN" | grep -o '"seconds_since_last_response"[[:space:]]*:[[:space:]]*[0-9]*' 2>/dev/null | head -n 1 | sed 's/.*:[[:space:]]*//')"
    D="$(arm_effort_resume "$TP" 2>/dev/null)" || true
    E="$(arm_outage "$TP" "$GAP" 2>/dev/null)" || true
    if [ -n "$D" ]; then
      printf '%s\n' "$D"
    fi
    if [ -n "$E" ]; then
      printf '%s\n' "$E"
    fi
  fi
  exit 0
fi
SID="$(printf '%s' "$IN" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
A="$(arm_glossary 2>/dev/null)" || true
B="$(arm_quota "$TP" 2>/dev/null)" || true
C="$(arm_effort "$TP" 2>/dev/null)" || true
F="$(arm_context "$TP" "$SID" 2>/dev/null)" || true
if [ -n "$A" ]; then
  printf '%s\n' "$A"
fi
if [ -n "$B" ]; then
  printf '%s\n' "$B"
fi
if [ -n "$C" ]; then
  printf '%s\n' "$C"
fi
if [ -n "$F" ]; then
  printf '%s\n' "$F"
fi
exit 0
