#!/usr/bin/env bash
# eugo-session-hooks — Claude Code SessionStart hook (startup|resume|clear|compact).
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
#   - the bearer travels only through files (0600) — never argv
#   - bash 3.2 safe (macOS): no mapfile, no ${x,,}, no associative arrays
#   - file present  → one-line note on stdout, refresh in the background for the next session
#   - file missing  → synchronous fetch, the file is written, the first ~9,000 chars are ALSO
#                     printed so this session is not blind
#   - any failure   → exactly one line naming `get_central_instructions`
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

ROOT="${CLAUDE_PROJECT_DIR:-.}"
RULES_DIR="$ROOT/.claude/rules"
RULES="$RULES_DIR/eugo-central.md"
BUDGET="${EUGO_INSTRUCTIONS_BUDGET:-0}"
EDGE_DEFAULT="https://kb.eugo.io:8443"
EDGE="${EUGO_KB_EDGE_URL:-$EDGE_DEFAULT}"
PY="/opt/miniforge3/envs/eugo_kb/bin/python"
FIRST_SESSION_CHARS=9000

fallback() {
  printf 'eugo-kb central instructions were NOT auto-injected (%s): call the eugo-kb tool get_central_instructions before your first substantive step.\n' "$1"
  exit 0
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

# --- the bearer, the launcher's way (files only) --------------------------------
resolve_headers_file() {
  local f
  for f in "$ROOT/.claude/eugo-mcp-headers.txt" "$HOME/.config/eugo/mcp-headers.txt"; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  if [ -n "${EUGO_MCP_TOKEN:-}" ]; then
    local hf="${XDG_RUNTIME_DIR:-$HOME/.config/eugo}/eugo-instructions-headers.txt"
    mkdir -p "$(dirname "$hf")" 2>/dev/null || return 1
    ( umask 077; rm -f "$hf" 2>/dev/null; set -C; printf 'Authorization: Bearer %s\n' "$EUGO_MCP_TOKEN" > "$hf" ) 2>/dev/null || return 1
    printf '%s' "$hf"; return 0
  fi
  return 1
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

# --- fetch the served string into $1 (a temp file); 0 on success ------------------
fetch_into() {
  local out="$1"
  if command -v docker >/dev/null 2>&1 && bounded 3 docker exec eugo-kb-tools true >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    if bounded 8 docker exec eugo-kb-tools "$PY" -m eugo_kb.cli_instructions --source "local docker" $(budget_args) > "$out" 2>/dev/null && [ -s "$out" ]; then
      return 0
    fi
    REASON="the local container answered but eugo-instructions failed"
    return 1
  fi
  # §3142 — the bearer goes only over https and only to a pinned host (eugo-kb facts 07f3c4ede333,
  # 391e109339af, 221cef9521; operator rulings 2026-09-23: https only, no loopback exception, pin
  # the host). EDGE comes from the environment, and any URL it named, plain http or another host,
  # received the bearer. The host must be EXACTLY the default's or listed in EUGO_KB_EDGE_HOSTS
  # (any numeric port); a URL with `@` or with a character outside the plain set is refused.
  # Checked BEFORE resolve_headers_file, so a refused URL never writes EUGO_MCP_TOKEN to disk, and
  # the URL is kept out of $REASON (it may carry credentials). `--proto =https` holds curl itself
  # to https; `--globoff` stops curl expanding `{a,b}` or `[1-9]` into more URLs than one.
  # NOT closed by this: EUGO_KB_EDGE_HOSTS comes from the same environment, so whoever can set the
  # URL (fact 221cef9521: a tracked settings.json `env` block) can list its host too; the pin stops
  # a stale or mistaken URL on its own. The reply is still installed unchecked (391e109339af).
  edge_allowed || return 1
  local hf
  hf="$(resolve_headers_file)" || { REASON="no local container and no bearer (headers file or EUGO_MCP_TOKEN)"; return 1; }
  if command -v curl >/dev/null 2>&1 && curl -fsS --proto =https --globoff --max-time 8 -H @"$hf" "$EDGE/mcp/instructions?source=edge$(budget_query)" > "$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
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
  # The trap is armed HERE, not at top level, because the `( … ) &` refresh subshell does
  # not inherit a top-level EXIT trap. Without it an interrupt, a failed write or a failed
  # mv left the tmp inside the repo (eugo-grpc G017, protomolecule F521(a)).
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
  trap 'rm -f "$RULES_TMP" 2>/dev/null' EXIT
  ( umask 022; set -C; cat "$1" > "$RULES_TMP" ) 2>/dev/null && mv -f "$RULES_TMP" "$RULES" 2>/dev/null
}

REASON="unknown"
TMP="$(mktemp "${TMPDIR:-/tmp}/eugo-central.XXXXXX" 2>/dev/null)" || fallback "cannot create a temp file"

if [ -f "$RULES" ]; then
  # Present: this session loads it natively already. Refresh for the NEXT session in the
  # background (never on the critical path) and say so.
  size="$(wc -c < "$RULES" 2>/dev/null | tr -d ' ')"
  printf 'eugo-kb central instructions: loaded natively from .claude/rules/eugo-central.md (%s bytes; refreshing in the background for the next session).\n' "${size:-?}"
  ( fetch_into "$TMP" && write_rules_from "$TMP"; rm -f "$TMP" ) >/dev/null 2>&1 &
  exit 0
fi

# Missing (a machine's first session): fetch now, write the file, and print the head so
# this session is not blind — rules are loaded at launch, before hooks run.
if fetch_into "$TMP"; then
  # The success line prints ONLY when the write succeeded; otherwise $REASON is printed
  # (eugo-grpc G013 — it used to be set here and never read, under an unconditional claim).
  WROTE=0
  if write_rules_from "$TMP"; then WROTE=1; else REASON="could not write $RULES"; fi
  head -c "$FIRST_SESSION_CHARS" "$TMP"
  if [ "$WROTE" = 1 ]; then
    printf '\n\n[eugo-kb: first session on this machine — the first %s characters above; the full text is now in .claude/rules/eugo-central.md and loads natively from the next session on.]\n' "$FIRST_SESSION_CHARS"
  else
    printf '\n\n[eugo-kb: first session on this machine — the first %s characters above; the full text was NOT saved (%s), so it will not load natively: call the eugo-kb tool get_central_instructions for the rest.]\n' "$FIRST_SESSION_CHARS" "$REASON"
  fi
  rm -f "$TMP"
  exit 0
fi
rm -f "$TMP"
fallback "$REASON"
