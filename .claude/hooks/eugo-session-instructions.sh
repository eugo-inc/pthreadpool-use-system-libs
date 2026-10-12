#!/usr/bin/env bash
# eugo-session-hooks — Claude Code SessionStart hook (startup|resume|clear|compact|fork).
#
# Keeps .claude/rules/eugo-central.md — the FULL eugo-kb central instructions, which
# Claude Code loads natively at launch and re-injects after compaction — fresh, because
# Claude Code injects only the first 2,048 characters of an MCP server's `instructions`
# and caps hook stdout at ~10 KB (both measured; see the carrier's SKILL.md).
#
# Contract (each line is a test in athena's tools/tests/test_session_hook_script.py):
#   - every path exits 0: a session is NEVER blocked by this hook
#   - stdin (Claude Code's hook JSON) is closed before any child runs — `docker exec`
#     runs WITHOUT -i and never inherits it
#   - the bearer never enters argv: a provisioned headers file is read by `curl -H @file`, and
#     EUGO_MCP_TOKEN reaches `curl -H @-` on a pipe from the BUILTIN printf — it is written to NO
#     file (§1.153); a stale copy a pre-§1.153 hook wrote is removed once, on every leg
#   - curl reads no curlrc: `-q` is its first argument, so a `libcurl = FILE` line writes nothing (§1.160 (a))
#   - bash 3.2 safe (macOS): no mapfile, no ${x,,}, no associative arrays
#   - file present  → one-line note on stdout naming the file's age (a day-old copy points at
#                     `get_central_instructions`), refresh in the background for the next session (§1.126 (c))
#   - file missing  → synchronous fetch, the file is written, the first ~9,000 chars are ALSO
#                     printed so this session is not blind
#   - any failure   → exactly one line naming `get_central_instructions`
#   - a reply is installed only when it begins with the provenance header and fits the byte cap; a
#     refused one is never printed and leaves the old rules file in place (§1.126 (a))
#   - EUGO_REVIEW_SUBPROCESS set → silent exit 0: no fetch, no write, no output (§2.38 a2)
#   - a user-only skill this checkout lacks is restored from a local athena checkout (§3.47): never a tracked
#     file, never through a symlink; a restore or a failure is SAID (§3.52 S2): stdout becomes ONE JSON object —
#     `systemMessage` for the operator, the hook's own output plus that line as `additionalContext` for Claude,
#     and `reloadSkills` after a restore. With nothing to say, stdout is the plain text it always was
#   - an errexit or xtrace INHERITED through BASH_ENV is disarmed first — the bearer never
#     reaches a trace (§3142)
#   - the bearer is sent only to an https EUGO_KB_EDGE_URL whose host is the default's or is
#     listed in EUGO_KB_EDGE_HOSTS, and curl is held to https with URL globbing off (§3142)
#   - the rules tmp is created O_EXCL at 0644 under an unpredictable name and is only ever
#     renamed; the rules dir keeps its group-write and setgid bits, loses other-write, and
#     stays readable by every account (§3142)
# §3142 — the publish guard's disarm (protomolecule f73c6ba408), which this hook lacked (eugo-kb
# fact 7664bbb3e4c7). Under the deploy image's BASH_ENV errexit, an unreadable rules file killed
# the hook at `size="$(wc …)"` before the note printed, and a failed chmod of the rules dir (any
# non-owner's) killed the background refresh before it wrote.
# §3142 — and xtrace/verbose OFF: the image's `EUGO_DEBUG_SHELL=1` turns on `set -v -x` through
# BASH_ENV, and under xtrace every `[ -n "$EUGO_MCP_TOKEN" ]` printed the BEARER to stderr
# (measured by the r2 challenger). This hook handles a secret; it never runs traced.
set +eEvx +o pipefail
trap - ERR
set -u
exec </dev/null

# §2.38 (a2) — A REVIEWER IS NOT A SESSION. `codex_review.py` spawns the `claude -p` reviewer
# with `cwd=<the reviewed repo>` and EUGO_REVIEW_SUBPROCESS=1, so this SessionStart hook ran at
# the start of every review: a bearer-carrying fetch and a write into the REVIEWED tree's
# .claude/rules/. The same guard as the kit siblings that key on the marker (§2121).
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi

# §1.126 (c) / §1.153 — seconds since FILE was last written; return 1 when unknown.
age_secs_of() {
  local m="" now=""
  m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=""
  now="$(date +%s 2>/dev/null)"
  case "$m" in ''|*[!0123456789]*) return 1 ;; esac
  case "$now" in ''|*[!0123456789]*) return 1 ;; esac
  if [ "$now" -lt "$m" ]; then printf '0'; else printf '%s' "$((now - m))"; fi
}

# §1.153 (ruled §5819) — the env token is written to no file any more, so a 0600 copy a pre-§1.153 hook left
# (`eugo-instructions-headers.txt` under XDG_RUNTIME_DIR, else ~/.config/eugo) is removed once, on every leg.
# Only a REGULAR file (never a symlink, never followed), and only one at least 60 s old: a pre-cure hook in
# another checkout may have just written its copy for its own curl (accepted at /enext). An unknown age keeps it.
# No `find`: a host's find may be bfs. The provisioned headers files have other names and are never touched.
# audit-w279 #18: only a copy this account OWNS (`-O`), so a root session with a shared XDG_RUNTIME_DIR leaves
# another user's alone. audit-w279 #16: the age read and the `rm` are two steps, so a pre-cure hook rewriting
# its copy in that millisecond window can still lose it; the 60 s rule covers the rest.
for STALE_DIR in "${XDG_RUNTIME_DIR:-}" "${HOME:+$HOME/.config/eugo}"; do
  [ -n "$STALE_DIR" ] || continue
  STALE_HF="$STALE_DIR/eugo-instructions-headers.txt"
  if [ -f "$STALE_HF" ] && [ ! -L "$STALE_HF" ] && [ -O "$STALE_HF" ] && STALE_AGE="$(age_secs_of "$STALE_HF")" &&
      [ "$STALE_AGE" -ge 60 ]; then
    rm -f "$STALE_HF" 2>/dev/null
  fi
done

ROOT="${CLAUDE_PROJECT_DIR:-.}"
RULES_DIR="$ROOT/.claude/rules"
RULES="$RULES_DIR/eugo-central.md"
BUDGET="${EUGO_INSTRUCTIONS_BUDGET:-0}"
EDGE_DEFAULT="https://kb.eugo.io"
EDGE="${EUGO_KB_EDGE_URL:-$EDGE_DEFAULT}"
PY="/opt/miniforge3/envs/eugo_kb/bin/python"
FIRST_SESSION_CHARS=9000
# §1.126 (a) — a reply is installed only when its first line starts with the provenance header that
# `eugo_kb.mcp_instructions.render_hook_payload` writes (ASCII prefix, so no locale enters the `case`) and
# it fits the cap (7x the largest fleet copy measured, 36,759 bytes).
RULES_HEADER='# eugo-kb central instructions '
RULES_MAX_BYTES=262144
# §1.114 — both tmp names start EMPTY: `cleanup_tmps` (the EXIT trap of every path that holds one) may
# run before either is assigned, and `set -u` would stop it on an unbound name.
TMP=""
RULES_TMP=""
cleanup_tmps() {
  if [ -n "$TMP" ]; then rm -f "$TMP" 2>/dev/null; fi
  if [ -n "$RULES_TMP" ]; then rm -f "$RULES_TMP" 2>/dev/null; fi
}

# §3.52 S2 (run 1261) — WHAT THE RE-PULL HAS TO SAY GOES WHERE SOMEONE READS IT. §3.47 said it on stderr, and
# "Claude never sees stderr from a hook that exits 0" (hooks.md); the operator does not see it either. A
# SessionStart hook's plain stdout is context for Claude only, a `systemMessage` is the operator's, and a restored
# skill needs `reloadSkills`: discovery runs before the SessionStart hooks finish, so the skill is otherwise missing
# until the next session (probe P11, 2.1.295: "NO" without the flag, "YES" with it; the field is 2.1.152's). The
# JSON is read only when the WHOLE stdout is one object, so every line this hook prints is collected in OUT and
# written once by `finish`: plain text, byte for byte as before, when SAID is empty.
OUT=""
SAID=""
RELOAD=0
say() { SAID="${SAID:+$SAID
}$1"; }
json_str() { # $1 as a JSON string literal; C0 controls other than tab, LF and CR are dropped (bash 3.2 safe)
  local s
  s="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'; printf x)"; s="${s%x}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}
finish() {
  local ctx="$OUT" reload=""
  if [ -z "$SAID" ]; then printf '%s' "$OUT"; exit 0; fi
  case "$ctx" in ''|*$'\n') ;; *) ctx="$ctx"$'\n' ;; esac
  [ "$RELOAD" = 1 ] && reload=', "reloadSkills": true'
  printf '{"systemMessage": %s, "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": %s%s}}\n' \
    "$(json_str "$SAID")" "$(json_str "$ctx$SAID")" "$reload"
  exit 0
}

fallback() {
  local line
  printf -v line 'eugo-kb central instructions were NOT auto-injected (%s): call the eugo-kb tool get_central_instructions before your first substantive step.\n' "$1"
  OUT="$OUT$line"
  finish
}

T=""
if command -v timeout >/dev/null 2>&1; then T=timeout; elif command -v gtimeout >/dev/null 2>&1; then T=gtimeout; fi
bounded() { # bounded SECONDS cmd...
  local secs="$1"; shift
  if [ -n "$T" ]; then "$T" "$secs" "$@"; else "$@"; fi
}

budget_args() { # the CLI flag only when the operator set a positive budget
  case "$BUDGET" in ''|0|*[!0-9]*) ;; *) printf -- '--budget %s' "$BUDGET" ;; esac
}
budget_query() { case "$BUDGET" in ''|0|*[!0-9]*) ;; *) printf -- '&budget=%s' "$BUDGET" ;; esac; }

# §3.47 (ruled at run 1260's close; the host route ruled at run 1261's arm) — RE-PULL A MISSING USER-ONLY SKILL.
# A catalog skill marked `disable-model-invocation: true` (eugo-resume and eugo-publish today) is the one kind MCP
# cannot serve: the operator types its slash command, so it must be a per-checkout copy under .claude/skills/, and a
# lost checkout loses it with nothing to bring it back (athena's own copies died with the 2026-09-23 checkout loss).
# So each session start restores any such skill this checkout lacks, from a local athena checkout — this repo when it
# is athena, else EUGO_ATHENA_PATH, else /opt/eugo/athena, else $HOME/eugo/athena (pull-shared-skills.sh's probe;
# never a relative guess, §2935), each holding skills/README.md and tools/eugo_kb/. `eugo-skills pull --name` does it
# when that CLI is on PATH; else plain bash copies the skill's directory, links the aliases its frontmatter names, and
# keeps both out of git through .git/info/exclude (never a tracked file). A restore or a failed one is `say`d (§3.52
# S2, above `fallback`), and nothing here can stop the session. NO ATHENA CHECKOUT stays one stderr line: it is a
# standing fact of the machine, not an event, and said aloud it would repeat at every session start on every
# machine without athena (the test container is one: every hook test turned JSON when it was said).
repull_user_only_skills() {
  local athena="" cand="" sk="" fm="" name="" missing="" dirs="" d="" a="" al="" excl="" sroot="$ROOT/.claude/skills"
  for cand in "$ROOT" "${EUGO_ATHENA_PATH:-}" /opt/eugo/athena "${HOME:+$HOME/eugo/athena}"; do
    if [ -n "$cand" ] && [ -f "$cand/skills/README.md" ] && [ -d "$cand/tools/eugo_kb" ]; then athena="$cand"; break; fi
  done
  if [ -z "$athena" ]; then
    printf 'eugo-session-hooks: no athena checkout found (set EUGO_ATHENA_PATH), so a missing user-only skill (/eresume, /epublish) is not restored\n' >&2
    return 0
  fi
  while IFS= read -r sk; do
    [ -n "$sk" ] || continue
    fm="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$sk" 2>/dev/null)"
    printf '%s\n' "$fm" | grep -qx 'disable-model-invocation: true' || continue   # in the frontmatter, not the body
    name="$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | head -n 1)"
    case "$name" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac                      # one safe path segment only
    [ -f "$sroot/$name/SKILL.md" ] && continue
    if [ -L "$sroot/$name" ] || [ -L "$sroot" ]; then
      say "eugo-session-hooks: $sroot/$name is a symlink, so user-only skill $name is not restored"
      continue
    fi
    missing="$missing $name"
    dirs="$dirs${sk%/SKILL.md}
"
  done <<EOF_SKILLS
$(grep -lx 'disable-model-invocation: true' "$athena"/skills/*/*/SKILL.md 2>/dev/null)
EOF_SKILLS
  [ -n "$missing" ] || return 0
  if command -v eugo-skills >/dev/null 2>&1; then
    set -- pull --from "$athena" --into "$ROOT"
    for name in $missing; do set -- "$@" --name "$name"; done
    if bounded 60 eugo-skills "$@" >/dev/null 2>&1; then
      say "eugo-session-hooks: restored user-only skill(s)$missing from $athena (eugo-skills pull)"; RELOAD=1
    else
      say "eugo-session-hooks: eugo-skills pull failed, so user-only skill(s)$missing are not restored"
    fi
    return 0
  fi
  excl="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null)" || excl=""
  case "$excl" in ''|/*) ;; *) excl="$ROOT/$excl" ;; esac
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && sub(/^name: */, "") { print; exit }' "$d/SKILL.md" 2>/dev/null)"
    mkdir -p "$sroot/$name" && cp -R "$d/." "$sroot/$name/" || {
      say "eugo-session-hooks: could not copy user-only skill $name into $sroot"; return 0; }
    al="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && sub(/^aliases: *\[/, "") { sub(/\].*$/, ""); print; exit }' "$d/SKILL.md" 2>/dev/null | tr ',' ' ')"
    for a in $name $al; do
      case "$a" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
      if [ "$a" != "$name" ] && [ ! -e "$sroot/$a" ] && [ ! -L "$sroot/$a" ]; then ln -s "$name" "$sroot/$a" 2>/dev/null || true; fi
      if [ -n "$excl" ] && [ -d "${excl%/*}" ] && ! git -C "$ROOT" check-ignore -q ".claude/skills/$a" 2>/dev/null; then
        printf '/.claude/skills/%s\n' "$a" >> "$excl" 2>/dev/null || true
      fi
    done
  done <<EOF_DIRS
$dirs
EOF_DIRS
  say "eugo-session-hooks: restored user-only skill(s)$missing from $athena"; RELOAD=1
  return 0
}
repull_user_only_skills || true

# --- the bearer, the launcher's way (never argv, never a file this hook writes) ----
# §1.153 — curl's `-H` argument: a provisioned headers file's path, or `-` (paths always hold a `/`, so the
# sentinel cannot collide) when only EUGO_MCP_TOKEN is set; rc 1 when there is neither.
resolve_headers_file() {
  local f
  for f in "$ROOT/.claude/eugo-mcp-headers.txt" "${HOME:+$HOME/.config/eugo/mcp-headers.txt}"; do   # audit-w279 #17
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  # audit-w279 #12 — `:+x`, never the token itself, as `[`'s argument: a disabled `[` builtin (BASH_ENV
  # `enable -n "["`) or an exported `[` function would run an external `[` with the bearer in its argv.
  if [ -n "${EUGO_MCP_TOKEN:+x}" ]; then printf '%s' "-"; return 0; fi
  return 1
}
# §1.153 — for `-`, the env token's header line on stdout, for `curl -H @-`; for a headers file, nothing. The
# BUILTIN printf only: a function named printf (exported, or defined through BASH_ENV) or `enable -n printf`
# would make a bare `printf` the external /usr/bin/printf, whose argv — the bearer — any local process can
# read. With the builtin disabled `builtin printf` fails closed: it prints nothing, curl sends no bearer, and
# the edge answers 401 (the fallback line). audit-w279 #14 — what it cannot stop: an exported FUNCTION named
# `builtin` (`BASH_FUNC_builtin%%`), or `enable -n builtin` with a `builtin` executable on PATH; no in-script
# defence exists, and whoever controls this environment can read EUGO_MCP_TOKEN directly anyway.
bearer_stdin() {
  if [ "$1" = "-" ]; then builtin printf 'Authorization: Bearer %s\n' "${EUGO_MCP_TOKEN:-}"; fi
}

# --- the one host the bearer may go to (§3142, operator rulings 2026-09-23) --------
# The character sets are spelled out, not ranges: a range such as a-z follows the locale's
# collation in bash before 5.0 and may then match more than ASCII letters.
edge_host_of() { # print HOST of a plain https://HOST[:PORT][/PATH] URL; return 1 for any other shape
  local rest="" auth="" host="" port=""
  case "$1" in
    *@*) return 1 ;; # userinfo: curl sends an authority `<host>:<port>@evil.example` to evil.example
    https://*) ;;
    *) return 1 ;;
  esac
  rest="${1#https://}"
  case "$rest" in *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./:_-]*) return 1 ;; esac
  auth="${rest%%/*}"
  host="${auth%%:*}"
  if [ "$host" != "$auth" ]; then
    port="${auth#*:}"
    case "$port" in ''|*[!0123456789]*) return 1 ;; esac
  fi
  case "$host" in ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-]*) return 1 ;; esac
  printf '%s' "$host"
}

edge_allowed() { # 0 when $EDGE may receive the bearer; else sets $REASON (never echoing the URL)
  local host="" list=""
  if ! host="$(edge_host_of "$EDGE")"; then
    REASON="EUGO_KB_EDGE_URL is not an https URL of the form https://HOST[:PORT][/PATH], so the bearer was not sent"
    return 1
  fi
  [ "$host" = "$(edge_host_of "$EDGE_DEFAULT")" ] && return 0
  list=" $(printf '%s' "${EUGO_KB_EDGE_HOSTS:-}" | tr ',\t\r\n' '    ') "
  case "$list" in *" $host "*) return 0 ;; esac
  REASON="EUGO_KB_EDGE_URL names a host that is neither the default's nor listed in EUGO_KB_EDGE_HOSTS, so the bearer was not sent"
  return 1
}

payload_ok() { # $1 = a fetched reply; 0 when it may be installed, else sets $REASON (never echoing the body)
  # audit-w276 #26 — the SIZE first: `read -r` of a one-line 64 MB reply cost 2.2 s and 378 MB before the header test.
  local first="" size=""
  size="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
  case "$size" in
    ''|*[!0123456789]*) REASON="the reply's size could not be read, so it was not installed"; return 1 ;;
  esac
  if [ "$size" -gt "$RULES_MAX_BYTES" ]; then
    REASON="the reply is $size bytes, over the $RULES_MAX_BYTES-byte cap, so it was not installed"
    return 1
  fi
  IFS= read -r first < "$1" || :
  case "$first" in
    "$RULES_HEADER"*) ;;
    *) REASON="the reply does not begin with the eugo-kb central instructions header, so it was not installed"; return 1 ;;
  esac
  return 0
}

# --- fetch the served string into $1 (a temp file); 0 on success ------------------
fetch_into() {
  local out="$1"
  if command -v docker >/dev/null 2>&1 && bounded 3 docker exec eugo-kb-tools true >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    if bounded 8 docker exec eugo-kb-tools "$PY" -m eugo_kb.cli_instructions --source "local docker" $(budget_args) > "$out" 2>/dev/null && [ -s "$out" ]; then
      payload_ok "$out"   # §1.126 (a): its REASON, not the one below, names a refusal
      return $?
    fi
    REASON="the local container answered but eugo-instructions failed"
    return 1
  fi
  # §3142 — the bearer goes only over https and only to a pinned host (eugo-kb facts 07f3c4ede333,
  # 391e109339af, 221cef9521; operator rulings 2026-09-23: https only, no loopback exception, pin
  # the host). EDGE comes from the environment, and any URL it named, plain http or another host,
  # received the bearer. The host must be EXACTLY the default's or listed in EUGO_KB_EDGE_HOSTS
  # (any numeric port); a URL with `@` or with a character outside the plain set is refused.
  # Checked BEFORE resolve_headers_file, so a refused URL never sends EUGO_MCP_TOKEN anywhere, and
  # the URL is kept out of $REASON (it may carry credentials). `--proto =https` holds curl itself
  # to https; `--globoff` stops curl expanding `{a,b}` or `[1-9]` into more URLs than one.
  # NOT closed by this: EUGO_KB_EDGE_HOSTS comes from the same environment, so whoever can set the
  # URL (fact 221cef9521: a tracked settings.json `env` block) can list its host too; the pin stops
  # a stale or mistaken URL on its own. §1.126 (a): the reply is now vetted (`payload_ok`) on both legs
  # before it is installed (391e109339af) — a sanity check on the header and size, not authentication.
  edge_allowed || return 1
  local hf
  hf="$(resolve_headers_file)" || { REASON="no local container and no bearer (headers file or EUGO_MCP_TOKEN)"; return 1; }
  # §1.153 (ruled §5819) — ONE line for both bearer kinds: `-H @file` reads a provisioned headers file and
  # ignores the pipe; `-H @-` reads the env token's header from it, so EUGO_MCP_TOKEN is never on disk (the
  # race, kill window and stale copies of §1.126 (b)'s derived file all go with it). curl 7.55.0 added
  # `@file` and `@-` in one commit. `command -v curl` stays first; pipefail is off (`set +o pipefail` above),
  # so the pipeline's status is curl's. The `.mcp.json` launcher's own copies (eugo-mcp-headers.txt,
  # eugo-mcp-stdio.env) persist — it execs past them — the residual accepted at run 1227's close (§3822).
  # §1.160 (a) (ruled 2026-10-05) — `-q` FIRST (curl honours it only there): no curlrc is read, so a `libcurl = FILE`
  # line cannot make curl write a C program holding the bearer to FILE, on a failed fetch too. A curlrc's proxy or
  # cacert settings are lost with it; the env proxies (https_proxy, …) still apply.
  if command -v curl >/dev/null 2>&1 && bearer_stdin "$hf" 2>/dev/null | curl -q -fsS --proto =https --globoff --max-time 8 -H @"$hf" "$EDGE/mcp/instructions?source=edge$(budget_query)" > "$out" 2>/dev/null && [ -s "$out" ]; then
    payload_ok "$out"   # §1.126 (a)
    return $?
  fi
  REASON="edge fetch failed"
  return 1
}

write_rules_from() { # atomic: tmp in the same dir, then rename; WORLD-READABLE —
  # on a shared checkout other accounts' sessions must load this file, and the
  # mktemp source is 0600 (a cp preserves it; measured 2026-08-30 on two live trees),
  # so the tmp below is CREATED 0644 rather than copied.
  # A DIRECTORY at $RULES is refused: `mv -f` would move the tmp INTO it and return 0,
  # so the rules file would be reported written while it does not exist (eugo-grpc G013).
  [ -d "$RULES" ] && return 1
  mkdir -p "$RULES_DIR" 2>/dev/null || return 1
  # §3142 — `a+rx,o-w`, not `755` (eugo-kb fact 2bf43927d313). §hook-8 (2af4f08cb) needs the dir
  # readable by every account; a numeric 755 ALSO dropped group-write from a shared checkout's
  # 2775 dir (GNU chmod keeps its setgid bit), so the other accounts could no longer refresh.
  # `o-w` keeps what 755 got right: in a world-writable dir ANY local account could drop a
  # rules .md, which Claude Code loads natively as instructions.
  chmod a+rx,o-w "$RULES_DIR" 2>/dev/null
  # The tmp name is GLOBAL, not `local`: the EXIT trap runs after this function returns.
  # The trap is armed HERE as well as by each caller, because the `( … ) &` refresh subshell
  # does not inherit a top-level EXIT trap. Without it an interrupt, a failed write or a failed
  # mv left the tmp inside the repo (eugo-grpc G017, protomolecule F521(a)). §1.114 — it is
  # `cleanup_tmps`, which removes the caller's fetch tmp too: `trap … EXIT` REPLACES the earlier
  # trap, so a trap naming only $RULES_TMP dropped $TMP for the rest of the run.
  # §3142 — the tmp is CREATED by the write itself, O_EXCL (`set -C`) at 0644 (`umask 022`),
  # under an unpredictable name that `mktemp -u` only picks, and afterwards it is only renamed:
  # never copied onto, reopened or chmod'ed. The old `.eugo-central.md.$$.tmp` was predictable,
  # and cp + chmod 644 followed a symlink planted there (fact 2bf43927d313). A name mktemp
  # CREATES is visible to anyone who can write the dir: a watcher swapped it for a symlink
  # between mktemp and cp/chmod and redirected the write (measured, 20 of 20 runs). Now a
  # symlink at the name when the write opens it fails O_EXCL, and a swap after the write only
  # renames the link, which a group member could do to the rules file directly anyway.
  # A full-path template with trailing X's, like the TMP line below: BSD mktemp replaces only
  # trailing X's.
  RULES_TMP="$(mktemp -u "$RULES_DIR/.eugo-central.md.tmp.XXXXXX" 2>/dev/null)" || return 1
  trap cleanup_tmps EXIT
  # §1.100 — `-T` (GNU) / `-h` (BSD): rename ONTO $RULES, never into a directory it names. The
  # `-d` refusal above cannot close the window between that test and this rename: a symlink to a
  # directory planted there in between made plain `mv -f` move the tmp INTO that directory and
  # return 0, so the rules file was reported written while it did not exist. Each mv rejects
  # the other's flag, so only one of the two can move anything.
  ( umask 022; set -C; cat "$1" > "$RULES_TMP" ) 2>/dev/null &&
    { mv -fT "$RULES_TMP" "$RULES" 2>/dev/null || mv -fh "$RULES_TMP" "$RULES" 2>/dev/null; }
}

# §1.126 (c) — how long ago the rules file was last written (`age_secs_of "$RULES"`, defined above). Every
# successful refresh renames a freshly written tmp onto it, so its mtime IS the last successful refresh — and
# since a background refresh's REASON goes nowhere (a refused reply, §1.126 (a), included), this age is the
# only sign the refresh stopped.
age_words() { # $1 = seconds -> "N min ago" / "N h ago" / "N days ago"
  if [ "$1" -lt 3600 ]; then printf '%s min ago' "$(($1 / 60))"
  elif [ "$1" -lt 86400 ]; then printf '%s h ago' "$(($1 / 3600))"
  else printf '%s days ago' "$(($1 / 86400))"; fi
}

REASON="unknown"
# §1.114 (run 1226; operator ruling 2026-09-26) — the fetch tmp is created INSIDE each branch, each
# with its own EXIT trap armed first. It was created once, up here, with no trap: a hook killed
# mid-fetch (a SessionStart timeout sends SIGTERM) left `eugo-central.XXXXXX` in $TMPDIR, and so did
# one killed after `write_rules_from`'s trap, which named only its own tmp. The background refresh
# makes its OWN tmp: a top-level trap in the parent would unlink the file that subshell is still
# using when the parent reaches `exit 0`.

if [ -f "$RULES" ]; then
  # Present: this session loads it natively already. Refresh for the NEXT session in the
  # background (never on the critical path) and say so.
  size="$(wc -c < "$RULES" 2>/dev/null | tr -d ' ')"
  AGE="at an unknown time"; STALE=""
  if AGE_S="$(age_secs_of "$RULES")"; then
    AGE="$(age_words "$AGE_S")"
    if [ "$AGE_S" -ge 86400 ]; then
      STALE=" It is over a day old: if sessions ran here since, the background refresh is failing or refusing the reply — call the eugo-kb tool get_central_instructions for the current text."
    fi
  fi
  printf -v line 'eugo-kb central instructions: loaded natively from .claude/rules/eugo-central.md (%s bytes; last refreshed %s; refreshing in the background for the next session).%s\n' "${size:-?}" "$AGE" "$STALE"
  OUT="$OUT$line"
  ( trap cleanup_tmps EXIT
    TMP="$(mktemp "${TMPDIR:-/tmp}/eugo-central.XXXXXX" 2>/dev/null)" || exit 0
    fetch_into "$TMP" && write_rules_from "$TMP"; rm -f "$TMP" ) >/dev/null 2>&1 &
  finish
fi

# Missing (a machine's first session): fetch now, write the file, and print the head so
# this session is not blind — rules are loaded at launch, before hooks run.
trap cleanup_tmps EXIT
TMP="$(mktemp "${TMPDIR:-/tmp}/eugo-central.XXXXXX" 2>/dev/null)" || fallback "cannot create a temp file"
if fetch_into "$TMP"; then
  # The success line prints ONLY when the write succeeded; otherwise $REASON is printed
  # (eugo-grpc G013 — it used to be set here and never read, under an unconditional claim).
  WROTE=0
  if write_rules_from "$TMP"; then WROTE=1; else REASON="could not write $RULES"; fi
  line="$(head -c "$FIRST_SESSION_CHARS" "$TMP"; printf x)"; OUT="$OUT${line%x}"   # the x keeps a trailing newline
  if [ "$WROTE" = 1 ]; then
    printf -v line '\n\n[eugo-kb: first session on this machine — the first %s characters above; the full text is now in .claude/rules/eugo-central.md and loads natively from the next session on.]\n' "$FIRST_SESSION_CHARS"
  else
    printf -v line '\n\n[eugo-kb: first session on this machine — the first %s characters above; the full text was NOT saved (%s), so it will not load natively: call the eugo-kb tool get_central_instructions for the rest.]\n' "$FIRST_SESSION_CHARS" "$REASON"
  fi
  OUT="$OUT$line"
  rm -f "$TMP"
  finish
fi
rm -f "$TMP"
fallback "$REASON"
