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
set -u
exec </dev/null

ROOT="${CLAUDE_PROJECT_DIR:-.}"
RULES_DIR="$ROOT/.claude/rules"
RULES="$RULES_DIR/eugo-central.md"
BUDGET="${EUGO_INSTRUCTIONS_BUDGET:-0}"
EDGE="${EUGO_KB_EDGE_URL:-https://kb.eugo.io:8443}"
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
    ( umask 077; printf 'Authorization: Bearer %s\n' "$EUGO_MCP_TOKEN" > "$hf" ) 2>/dev/null || return 1
    printf '%s' "$hf"; return 0
  fi
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
  local hf
  hf="$(resolve_headers_file)" || { REASON="no local container and no bearer (headers file or EUGO_MCP_TOKEN)"; return 1; }
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 8 -H @"$hf" "$EDGE/mcp/instructions?source=edge$(budget_query)" > "$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  REASON="edge fetch failed"
  return 1
}

write_rules_from() { # atomic: tmp in the same dir, then rename; WORLD-READABLE —
  # on a shared checkout other accounts' sessions must load this file, and the
  # mktemp source is 0600 (cp preserves it; measured 2026-08-30 on two live trees).
  mkdir -p "$RULES_DIR" 2>/dev/null || return 1
  chmod 755 "$RULES_DIR" 2>/dev/null
  local tmp="$RULES_DIR/.eugo-central.md.$$.tmp"
  cp "$1" "$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null && mv -f "$tmp" "$RULES" 2>/dev/null
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
  write_rules_from "$TMP" || REASON="could not write $RULES"
  head -c "$FIRST_SESSION_CHARS" "$TMP"
  printf '\n\n[eugo-kb: first session on this machine — the first %s characters above; the full text is now in .claude/rules/eugo-central.md and loads natively from the next session on.]\n' "$FIRST_SESSION_CHARS"
  rm -f "$TMP"
  exit 0
fi
rm -f "$TMP"
fallback "$REASON"
