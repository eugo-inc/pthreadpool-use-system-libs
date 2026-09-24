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
#   - EUGO_REVIEW_SUBPROCESS set -> silent (a reviewer is not a session to inform);
#     EUGO_PROMPT_CONTEXT_OFF set -> silent (the kill switch, both arms)
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
- `eresume` / `/eresume` — resume interrupted work after a usage limit, account switch, crash or compaction: this response proves quota; read git + STATE.md + breadcrumbs + the plan, name the exact call that died, re-run it. User-only skill eugo-resume.
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

# ---- MAIN ----
# The FIRST occurrence, never the last: a prompt that quotes the literal key must not
# redirect the quota arm (greedy `.*` took the last match). And only a `.jsonl` path is
# ever read.
TP="$(printf '%s' "$IN" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
case "$TP" in *.jsonl) ;; *) TP="" ;; esac
A="$(arm_glossary 2>/dev/null)" || true
B="$(arm_quota "$TP" 2>/dev/null)" || true
if [ -n "$A" ]; then
  printf '%s\n' "$A"
fi
if [ -n "$B" ]; then
  printf '%s\n' "$B"
fi
exit 0
