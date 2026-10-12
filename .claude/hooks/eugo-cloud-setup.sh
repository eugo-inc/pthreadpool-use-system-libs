#!/usr/bin/env bash
# §2.47 (run 1231) — the OPT-IN cloud provisioning hook: in a Claude Code cloud session, run the
# repo's own `.claude/cloud-setup.sh` (operator ruling 2026-09-28: a fixed script path, no
# `.eugo.toml` table).
#
# WHY. A cloud session starts in a fresh VM with a fresh clone. athena provisions its test gate
# there with its own `session-start.sh`; the fleet's carriers gave a consumer repo no equivalent
# (FUTURE.md §2.47). This hook is that slot: the repo writes `.claude/cloud-setup.sh` (apt
# packages, a venv, whatever its gate needs — idempotent, because it runs at every session start),
# and `eugo-skills init-hooks --cloud-setup` registers this hook to run it.
#
# Contract (each line is a test in tools/tests/test_cloud_setup_hook.py):
#   - OPT-IN: registered only by `init-hooks --cloud-setup`, never by `--review` or a default run.
#   - LOCAL SESSIONS ARE UNTOUCHED: it exits 0 at once unless `CLAUDE_CODE_REMOTE` is exactly
#     `true` (the signal athena's `session-start.sh` keys on), and inside a review subprocess.
#   - ALWAYS exits 0: a failed setup is REPORTED (its exit status and the last lines of its
#     output, as SessionStart context the session can act on), never a blocked session.
#   - A SUCCESSFUL setup chooses what the session learns, as a failed one does (report:140; §1.148,
#     §1.149 ruled §5710): every line it starts with the marker `eugo cloud-setup: session:` follows the
#     hook's own line, indented, marker kept, at most 20 (the rest counted); with no marked line, its last
#     NON-blank line does. A FAILED setup passes on its last five NON-blank lines — none when it printed
#     none, so the header line stands alone (§1.152). Both are hardened with POSIX tools only (the hook
#     runs on bash 3.2 / BSD userland, so no `sed '\r'`): on SUCCESS a CR is a line break (a progress
#     meter's frames, CRLF); on FAILURE a line keeps only its last CR piece that is not blank (spaces and
#     tabs only), so a meter costs one of the five lines (§1.156); in both, whitespace-only lines are skipped
#     and each line passed on is cut at 500 bytes, never leaving a character the cut split behind (§1.152;
#     bytes that arrived invalid pass as they came). Stderr stays
#     captured with stdout — the failure branch needs it — so a stray warning can be the "last line": a
#     repo that wants a line heard marks it.
#   - SYNCHRONOUS, like `session-start.sh`: the gate exists before the first tool call. The row's
#     timeout is 600 s, Claude Code's own default for a command hook (hooks.md, "timeout").
#   - The setup runs under `bash`, so a script committed without its exec bit still runs.
set +eE +o pipefail
trap - ERR
set -u
exec </dev/null

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
if [ -n "${EUGO_REVIEW_SUBPROCESS:-}" ]; then
  exit 0
fi

ROOT="${CLAUDE_PROJECT_DIR:-.}"
SETUP="$ROOT/.claude/cloud-setup.sh"
say() { printf 'eugo cloud-setup: %s\n' "$1"; }
MARK='eugo cloud-setup: session:'
# §1.152 — the ONE cut both branches use: at most `cap` bytes, then a character it split is dropped. A cut inside
# a multi-byte UTF-8 character kept its first bytes (audit-w277 #9: 499 `a` + `é` ended `\303` on gawk, mawk,
# BusyBox and the bash:3.2 image). Run under `LC_ALL=C`, so `length`/`substr` count bytes and the compares are
# byte compares: up to three trailing continuation bytes (0x80-0xBF) and the lead byte before them are dropped
# only when that lead byte starts a longer character than is left (0xC0-0xDF two bytes, 0xE0-0xEF three,
# 0xF0-0xF7 four). Checked by hand on gawk, mawk, BusyBox awk and the bash:3.2 image (run 1249).
CUT='function cut(s,    t, n, k, c, need) {
  if (length(s) <= cap) return s
  t = substr(s, 1, cap); n = cap; k = 0
  while (k < 3 && k < n) {
    c = substr(t, n - k, 1)
    if (c < "\200" || c >= "\300") break
    k++
  }
  if (k >= n) return t
  c = substr(t, n - k, 1); need = 0
  if (c >= "\300" && c < "\340") need = 2
  else if (c >= "\340" && c < "\360") need = 3
  else if (c >= "\360" && c < "\370") need = 4
  if (need > k + 1) t = substr(t, 1, n - k - 1)
  return t
}
'

if [ ! -f "$SETUP" ]; then
  say "no .claude/cloud-setup.sh in this repo — nothing provisioned (write one to install what the gate needs)"
  exit 0
fi

OUT="$(cd "$ROOT" && bash "$SETUP" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
  say ".claude/cloud-setup.sh finished (exit 0)"
  # Marked lines, else the last non-blank one (see the contract above). `LC_ALL=C` on both: the cap counts
  # bytes on every platform, and macOS `tr` in a UTF-8 locale stops at the first invalid byte
  # (audit-w277 #12); `-v mark` carries no backslash, so awk's escape processing cannot touch it.
  printf '%s\n' "$OUT" | LC_ALL=C tr '\r' '\n' | LC_ALL=C awk -v mark="$MARK" -v most=20 -v cap=500 "$CUT"'
    index($0, mark) == 1 { if (++n <= most) keep[n] = cut($0); next }
    NF { last = cut($0) }
    END {
      if (n) {
        for (i = 1; i <= n && i <= most; i++) print "  " keep[i]
        if (n > most) printf "  (%d more marked lines not shown)\n", n - most
      } else if (last != "") print "  " last
    }'
else
  say ".claude/cloud-setup.sh FAILED (exit $RC) — the gate may not be provisioned; its last lines:"
  # §1.152 — cleaned like the success line (audit-w277 #27): the last five NON-blank lines, kept in a ring of
  # five rather than the whole output, each cut. §1.156 (ruled (b) §6008) — but a CR is NOT a line break here:
  # a line keeps its last CR piece that is not blank (spaces and tabs only), so a meter's frames cost one line and
  # the line saying what was fetched survives (audit-w278 #13). Split on CR and walk back over the blank pieces:
  # linear, where a trailing `sub(/(\r[ \t]*)+$/, "")` retried its match from every CR, quadratic in a run of
  # blank pieces (audit-w280 #1: 60,000 of them took 12 s on gawk). A line of only blank pieces leaves NF 0.
  printf '%s\n' "$OUT" | LC_ALL=C awk -v most=5 -v cap=500 "$CUT"'
    { np = split($0, piece, "\r"); while (np > 1 && piece[np] !~ /[^ \t]/) np--; $0 = np ? piece[np] : "" }
    NF { ring[n++ % most] = cut($0) }
    END { i = n - most; if (i < 0) i = 0; for (; i < n; i++) print "  " ring[i % most] }'
fi
exit 0
