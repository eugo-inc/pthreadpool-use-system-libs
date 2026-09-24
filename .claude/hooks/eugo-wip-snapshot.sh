#!/usr/bin/env bash
# §wip-snapshot — Claude Code Stop hook: copy the uncommitted work OUT of the checkout at
# every turn end, so deleting a checkout loses at most one turn of it.
#
# WHY THIS EXISTS. On 2026-09-23 a session ran `python3 sw20_ctl.py && C=… && …; docker
# compose exec -T tools rm -rf /repo/$C`. The python step failed, `C` was never set, and
# `rm -rf /repo/` ran as root in the tools container, which bind-mounts the whole checkout.
# The tree, its .git, every DB dump kept inside it and hours of uncommitted work were gone;
# GitHub gave the commits back and nothing else. Work that lives only in the working tree
# dies with the working tree, so this hook keeps a copy where that command cannot reach.
#
# WHAT IT WRITES. One `git apply`-able patch — tracked changes AND untracked, non-ignored
# files (`.gitignore` is honoured, so `.env` and `outputs/` stay out) — at
#   ${XDG_CACHE_HOME:-$HOME/.cache}/eugo-wip/<repo basename>-<8 hex>/<UTC stamp>-<session 8>.patch
# mode 600 in a 700 folder. The 8 hex are `git hash-object` of the checkout's path: two
# checkouts sharing a folder name keep separate rings, and a checkout re-cloned at the same
# path finds its old ones. The `# ` lines before the first `diff --git` are a header
# `git apply` skips: repo, HEAD, branch, stamp, session, what was left out, and the restore
# command.
#
# RETENTION. The newest 20 per checkout; past those, the newest patch of each session that
# has none among them, while it is under 72 h old — at most 10 such, so at most 500 MB at
# the cap. By count alone, 20 dirty turns in a re-cloned checkout evicted every snapshot
# taken before the loss.
#
# INSIDE THE REPO it writes only loose objects: `git add` stores the snapshot's new blobs in
# .git/objects, unreferenced until a real commit uses them or `git gc` prunes them
# (gc.pruneExpire, two weeks by default). ⚠ `git add` runs under the CALLER's umask, not
# this hook's 077: a later real commit reuses the blob, and in a shared checkout without
# core.sharedRepository a 0400 blob is one the other users cannot read.
#
# Contract (each line is a test in tools/tests/test_wip_snapshot_hook.py):
#   - EXIT 0 ON EVERY PATH, and nothing on stdout when it works. On a Stop hook exit 2 makes
#     the model keep going, so it must never happen; the EXIT trap forces 0 even past a `set -u` abort
#   - a failure is ONE stderr line, `eugo-wip-snapshot: …`, and the same text in ONE
#     `{"systemMessage": …}` on stdout: exit-0 stderr reaches only the debug log, and
#     systemMessage is the field that shows the user a warning without keeping the model going
#   - the REAL index is never written — concurrent sessions share it (see the index notes)
#   - not a work tree, a clean tree, or EUGO_WIP_SNAPSHOT=off -> no file
#   - a diff identical to the newest patch's -> no file (the header differs by construction)
#   - untracked files over 5 MB, nested repositories and submodules with local work are left
#     out and named; over 50 MB the untracked files go, biggest first, until the patch fits,
#     and only tracked changes that alone pass 50 MB are refused
#   - new blobs are written under the caller's umask; a `.work.*` left by a killed run is swept
#   - bash 3.2 safe (macOS), and no recursive rm anywhere: it deletes only files it named
#   - an errexit INHERITED through BASH_ENV is disarmed before anything else runs
#
# §3143 — THE DISARM COMES FIRST, as in every kit hook: the eugo deploy image's BASH_ENV
# turns on `set -eE -o pipefail` for every non-interactive bash, and a Stop hook ended by
# errexit exits with the failing command's status.
set +eE +o pipefail
trap - ERR
set -u

IN="$(cat 2>/dev/null || true)"
exec </dev/null

case "${EUGO_WIP_SNAPSHOT:-}" in
  off|OFF|Off) exit 0 ;;
esac

# C collation: the newest patch is the last name in glob order, and the stamps only sort
# that way byte-wise. GIT_OPTIONAL_LOCKS=0: plain `git status` opportunistically REWRITES
# .git/index with refreshed stat data under index.lock — a write to the shared index, and a
# lock a concurrent session's `git commit` can collide with.
export LC_ALL=C GIT_OPTIONAL_LOCKS=0
UMASK0="$(umask)"           # the caller's, for `git add` alone (see INSIDE THE REPO above)
umask 077
NL='
'
CR="$(printf '\r')"
TAB="$(printf '\t')"
MAX_UNTRACKED_K=5120        # an untracked file over 5 MiB is skipped (find -size units)
MAX_PATCH=52428800          # 50 MiB: untracked files are dropped to fit, then it is refused
BODY_MAX=$(( MAX_PATCH - 262144 ))   # the diff's share, leaving 256 KiB for the header
KEEP=20
KEEP_SESSIONS=10            # past the newest 20: one patch per other recent session, at most
FLOOR_MIN=4320              # "recent" = modified under 72 h ago (find -mmin units)

# The note goes to stderr (the debug log) AND is kept for the EXIT trap, which hands it to
# the user as `systemMessage`. Control characters become `?`: one line, and valid JSON.
NOTE=""
note() {
  NOTE="eugo-wip-snapshot: ${1//[[:cntrl:]]/?}"
  printf '%s\n' "$NOTE" >&2
}
emit() {
  [ -n "$NOTE" ] || return 0
  j="$(printf '%s' "$NOTE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '{"systemMessage": "%s"}\n' "$j"
}

WORK=""
cleanup() {
  # Only the files this run created, by name; `rmdir` refuses anything else left behind.
  [ -n "$WORK" ] && [ -d "$WORK" ] || return 0
  rm -f -- "${WORK:?}"/* 2>/dev/null
  rmdir -- "${WORK:?}" 2>/dev/null
  return 0
}
trap 'cleanup; emit; exit 0' EXIT
trap 'exit 0' HUP INT TERM

# A step that fails while writing into $WORK has usually run out of space, whatever git
# says (a full cache disk used to read "git diff-index failed"): a one-byte probe that
# comes out empty names the disk instead.
fail() {
  if [ -n "$WORK" ]; then
    { printf x >"$WORK/probe"; } 2>/dev/null
    if [ ! -s "$WORK/probe" ]; then note "cannot write in $DIR (disk full?) — no snapshot"; exit 0; fi
  fi
  note "$1 — no snapshot"
  exit 0
}

ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || exit 0
cd "$ROOT" 2>/dev/null || exit 0

# `-unormal` so a `status.showUntrackedFiles=no` config cannot make a tree whose only work
# is new files look clean. v2 because its third field is a submodule's own state (below).
DIRTY="$(git -c core.quotePath=false status --porcelain=v2 --untracked-files=normal 2>/dev/null)" || {
  note "git status failed in $ROOT — no snapshot"; exit 0; }
[ -n "$DIRTY" ] || exit 0

# XDG: a relative XDG_CACHE_HOME is ignored.
BASE="${XDG_CACHE_HOME:-}"
case "$BASE" in /*) ;; *) BASE="" ;; esac
if [ -z "$BASE" ]; then
  case "${HOME:-}" in
    /*) BASE="$HOME/.cache" ;;
    *) note "neither XDG_CACHE_HOME nor HOME is an absolute path — no snapshot"; exit 0 ;;
  esac
fi
NAME="${ROOT##*/}"
[ -n "$NAME" ] || NAME="root"
# The path's hash in the folder name: a folder per checkout, not per basename (see top).
KEY="$(printf '%s' "$ROOT" | git hash-object --stdin 2>/dev/null)"
KEY="${KEY:0:8}"
case "$KEY" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) note "git hash-object failed in $ROOT — no snapshot"; exit 0 ;;
esac
DIR="$BASE/eugo-wip/$NAME-$KEY"
# A cache inside the work tree would snapshot its own snapshots, growing every turn.
case "$DIR/" in
  "$ROOT"/*) note "the cache dir $DIR is inside the work tree — no snapshot"; exit 0 ;;
esac
if ! mkdir -p -- "$DIR" 2>/dev/null || ! chmod 700 -- "$BASE/eugo-wip" "$DIR" 2>/dev/null; then
  note "cannot create $DIR — no snapshot"; exit 0
fi
# A run SIGKILLed at the hook timeout never reaches its trap. The next run removes such a
# folder once it is 10 minutes old — a live run is over in 20 s — by name, one level deep.
for w in "$DIR"/.work.*; do
  [ -d "$w" ] || continue
  [ -n "$(find "$w" -prune -mmin +10 2>/dev/null)" ] || continue
  rm -f -- "$w"/* 2>/dev/null
  rmdir -- "$w" 2>/dev/null
done
WORK="$(mktemp -d "$DIR/.work.XXXXXX" 2>/dev/null)" || WORK=""
[ -n "$WORK" ] || { note "cannot write in $DIR (disk full?) — no snapshot"; exit 0; }

HEAD_SHA="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
if [ -n "$HEAD_SHA" ]; then
  BASE_REV="$HEAD_SHA"
else
  BASE_REV="$(git hash-object -t tree /dev/null 2>/dev/null)"   # unborn: diff against the empty tree
fi
BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null)"
[ -n "$BRANCH" ] || BRANCH="(detached)"

# ---- the temporary index -----------------------------------------------------------
# Every git command that writes an index below writes $IDX (GIT_INDEX_FILE), never the one
# the session and its neighbours are using.
#
# ⚠ SEEDED FROM A COPY OF THE REAL INDEX, NOT FROM `read-tree HEAD`, on measurement:
# read-tree leaves every entry without stat data, so `git add -A` re-hashes every tracked
# byte — 2,246 ms on athena's 1.4 GB tree against 25 ms from the copy, byte-identical
# patch. `cp -p` keeps the mtime, so git's racy-entry check trusts the copy exactly as far
# as `git status` trusts the original. `read-tree HEAD` is the fallback when there is no
# index to copy; an unborn branch with none starts from the empty index (an absent file).
IDX="$WORK/index"
REAL_IDX="$(git rev-parse --git-path index 2>/dev/null)"
if [ -n "$REAL_IDX" ] && [ -f "$REAL_IDX" ] && cp -p -- "$REAL_IDX" "$IDX" 2>/dev/null; then
  :
else
  rm -f -- "${WORK:?}/index"
  if [ -n "$HEAD_SHA" ] && ! GIT_INDEX_FILE="$IDX" git read-tree "$HEAD_SHA" >/dev/null 2>&1; then
    fail "git read-tree into the temporary index failed in $ROOT"
  fi
fi

# ---- submodules ----------------------------------------------------------------------
# A submodule's own work — its edits, its untracked files, the commits it moved to — lives
# in its own repository under .git/modules, which no patch of this one carries (git apply
# skips a gitlink line). Named in the header instead. v2's third field is S<commit changed>
# <tracked changes><untracked files>, a `.` for each it lacks; N... is not a submodule.
SUBMODS=""
case "$DIRTY" in
  *" S"[C.][M.][U.]" "*)
    printf '%s\n' "$DIRTY" 2>/dev/null >"$WORK/status"
    while IFS= read -r ln; do
      case "$ln" in
        "1 "*) k=8 ;;        # 1 XY sub mH mI mW hH hI path
        "2 "*) k=9 ;;        # 2 XY sub mH mI mW hH hI Xscore path<TAB>orig
        "u "*) k=10 ;;       # u XY sub m1 m2 m3 mW h1 h2 h3 path
        *) continue ;;
      esac
      sub="${ln#* }"; sub="${sub#* }"; sub="${sub%% *}"
      case "$sub" in S...|N*) continue ;; esac
      p="$ln"
      while [ "$k" -gt 0 ]; do p="${p#* }"; k=$(( k - 1 )); done
      p="${p%%$TAB*}"       # a type-2 line ends in a TAB and the old path
      SUBMODS="$SUBMODS# NOT in this patch (submodule with local work): ${p//[[:cntrl:]]/?}$NL"
    done 2>/dev/null <"$WORK/status"
    ;;
esac

# ---- what `git add -A` must leave out ------------------------------------------------
# A nested repository (`ls-files -o` lists it as `dir/`) cannot travel in a patch, and an
# untracked file over 5 MB is usually a build product or a dump. Both are excluded with
# LITERAL pathspecs (no glob surprises from `[` or `*` in a name) and named in the header.
git ls-files -o --exclude-standard -z >"$WORK/untracked" 2>/dev/null
set --
SKIPPED=""
while IFS= read -r -d '' f; do
  case "$f" in
    */)
      set -- ${1+"$@"} ":(exclude,literal)$f"
      g="${f//$NL/?}"; g="${g//$CR/?}"
      SKIPPED="$SKIPPED# skipped (a nested repository): $g$NL"
      ;;
    *) printf './%s\0' "$f" ;;   # `./` so a name starting with `-` is never a find option
  esac
done 2>/dev/null <"$WORK/untracked" >"$WORK/files"   # a full disk is fail()'s to report, once
if [ -s "$WORK/files" ]; then
  xargs -0 sh -c 'exec find "$@" -prune -type f -size +'"$MAX_UNTRACKED_K"'k -print0' sh \
    <"$WORK/files" >"$WORK/big" 2>/dev/null
  while IFS= read -r -d '' f; do
    f="${f#./}"
    set -- ${1+"$@"} ":(exclude,literal)$f"
    g="${f//$NL/?}"; g="${g//$CR/?}"
    SKIPPED="$SKIPPED# skipped (untracked, over 5 MB): $g$NL"
  done <"$WORK/big"
fi

# `--ignore-errors`: one unreadable file (a root-owned one the container left, say) must
# cost that file, not the whole snapshot. git exits 1 for that case and 128 when it could
# not add at all; the unreadable files are named in the header. The subshell restores the
# caller's umask for the blobs this writes into .git/objects (see INSIDE THE REPO above).
( umask "$UMASK0"
  GIT_INDEX_FILE="$IDX" git -c core.splitIndex=false add -A --ignore-errors -- . ${1+"$@"}
) >/dev/null 2>"$WORK/adderr"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  fail "git add into the temporary index failed in $ROOT (exit $rc)"
fi
UNREAD=""
if [ "$rc" -eq 1 ]; then
  sed -n "s/^error: unable to index file '\(.*\)'\$/\1/p" "$WORK/adderr" >"$WORK/unread" 2>/dev/null
  while IFS= read -r f; do
    if [ -n "$f" ]; then UNREAD="$UNREAD# NOT in this patch (git could not read it): ${f//$CR/?}$NL"; fi
  done <"$WORK/unread"
  [ -n "$UNREAD" ] || UNREAD="# NOT complete: git add reported errors (exit 1)$NL"
fi

# ⚠ PLUMBING, NOT `git diff --cached`: the porcelain reads the USER's diff.noprefix,
# diff.external and textconv settings, any of which yields a patch `git apply` rejects.
# `--binary` carries binary files whole.
diff_body() {
  GIT_INDEX_FILE="$IDX" git diff-index --cached -p --binary "$BASE_REV" -- \
    >"$WORK/body" 2>/dev/null || fail "git diff-index failed in $ROOT"
  SIZE=$(( $(wc -c <"$WORK/body" 2>/dev/null || echo 0) + 0 ))
}
# Back to $BASE_REV in the temporary index for the paths in $1 (NUL-separated): a path HEAD
# lacks leaves the index, and one HEAD has (after `git rm --cached`) is not a deletion.
reset_paths() {
  GIT_INDEX_FILE="$IDX" GIT_LITERAL_PATHSPECS=1 git -c core.splitIndex=false reset -q \
    "$BASE_REV" --pathspec-from-file="$1" --pathspec-file-nul >/dev/null 2>&1 ||
    fail "git reset in the temporary index failed in $ROOT"
}
diff_body
# §1.103 L3 — an empty body with something LEFT OUT means every dirty item was excluded (an
# untracked file over 5 MB, a nested repository, a submodule's own work, an unreadable file).
# Those are named only in a patch header, and there is no patch: say so once, never silently.
if [ ! -s "$WORK/body" ]; then
  LEFT="$SKIPPED$SUBMODS$UNREAD"
  if [ -n "$LEFT" ]; then
    LEFT="${LEFT//# /}"; LEFT="${LEFT//$NL/; }"; LEFT="${LEFT%; }"
    [ "${#LEFT}" -le 400 ] || LEFT="${LEFT:0:397}..."
    note "nothing saved — every uncommitted item was left out: $LEFT"
  fi
  exit 0
fi

# ---- over the cap: the untracked files go, biggest first ------------------------------
# The TRACKED edits are what this hook is for, and refusing the whole patch cost them on
# every turn that one untracked blob too many was lying around. Each round drops the
# biggest untracked files left (64 KiB to 5 MiB, the first 256 found, sized by `wc -c`)
# until their estimated share of the patch covers the excess, and rebuilds the diff. The
# estimate starts at 129 patch bytes per 100 on disk (base85 of data zlib cannot shrink —
# counting disk bytes alone dropped 16 of 20 such blobs where 13 fit) and is re-measured
# from each round's drop. After four rounds, or with no candidate left, every untracked
# file goes. Tracked changes alone over the cap are refused. Each dropped file is named.
DROPPED=""; DROPSET="$NL"; ndrop=0
if [ "$SIZE" -gt "$BODY_MAX" ]; then
  # Candidates and their sizes, biggest first. Names stay in CN (NUL-safe); sort sees
  # only "<bytes> <index>" lines. `./` prefixes as in $WORK/files, stripped for git.
  { : >"$WORK/mid"
    if [ -s "$WORK/files" ]; then
      xargs -0 sh -c 'exec find "$@" -prune -type f -size +64k ! -size +'"$MAX_UNTRACKED_K"'k -print0' sh \
        <"$WORK/files" >"$WORK/mid"
    fi
  } 2>/dev/null
  n=0
  while [ "$n" -lt 256 ] && IFS= read -r -d '' f; do
    CN[$n]="$f"
    CS[$n]=$(( $(wc -c <"$f" 2>/dev/null || echo 0) + 0 ))
    n=$(( n + 1 ))
  done 2>/dev/null <"$WORK/mid"
  { i=0
    while [ "$i" -lt "$n" ]; do printf '%s %s\n' "${CS[$i]}" "$i"; i=$(( i + 1 )); done |
      sort -rn >"$WORK/order"
  } 2>/dev/null
  m=0
  while read -r sz i; do OS[$m]="$sz"; OI[$m]="$i"; m=$(( m + 1 )); done 2>/dev/null <"$WORK/order"
  next=0; round=0; RATIO=129
  while [ "$SIZE" -gt "$BODY_MAX" ] && [ "$round" -lt 4 ] && [ "$next" -lt "$m" ]; do
    need=$(( (SIZE - BODY_MAX) * 100 / RATIO + 1 )); gone=0; before=$SIZE
    { : >"$WORK/drop"; } 2>/dev/null || fail "cannot write in $WORK"
    while [ "$need" -gt 0 ] && [ "$next" -lt "$m" ]; do
      j="${OI[$next]}"; f="${CN[$j]}"
      need=$(( need - ${OS[$next]} )); gone=$(( gone + ${OS[$next]} )); next=$(( next + 1 ))
      printf '%s\0' "${f#./}" >>"$WORK/drop"
      DROPSET="$DROPSET$f$NL"
      g="${f#./}"; g="${g//$NL/?}"; g="${g//$CR/?}"
      DROPPED="$DROPPED# skipped (untracked, patch over 50 MB): $g$NL"
      ndrop=$(( ndrop + 1 ))
    done 2>/dev/null
    reset_paths "$WORK/drop"
    diff_body
    if [ "$gone" -gt 0 ] && [ "$before" -gt "$SIZE" ]; then
      RATIO=$(( (before - SIZE) * 100 / gone ))
      [ "$RATIO" -ge 1 ] || RATIO=1
    fi
    round=$(( round + 1 ))
  done
  if [ "$SIZE" -gt "$BODY_MAX" ]; then
    BIGSET="$NL"
    if [ -f "$WORK/big" ]; then
      while IFS= read -r -d '' f; do BIGSET="$BIGSET$f$NL"; done <"$WORK/big"
    fi
    { : >"$WORK/drop"; } 2>/dev/null || fail "cannot write in $WORK"
    while IFS= read -r -d '' f; do
      case "$BIGSET$DROPSET" in *"$NL$f$NL"*) continue ;; esac
      printf '%s\0' "${f#./}" >>"$WORK/drop"
      g="${f#./}"; g="${g//$NL/?}"; g="${g//$CR/?}"
      DROPPED="$DROPPED# skipped (untracked, patch over 50 MB): $g$NL"
      ndrop=$(( ndrop + 1 ))
    done 2>/dev/null <"$WORK/files"
    if [ -s "$WORK/drop" ]; then reset_paths "$WORK/drop"; diff_body; fi
  fi
  if [ "$SIZE" -gt "$BODY_MAX" ]; then
    note "the tracked changes in $ROOT alone make a $SIZE-byte patch, over the 50 MB cap — not written (commit or stash the large change)"
    exit 0
  fi
  if [ ! -s "$WORK/body" ]; then
    note "the untracked files in $ROOT pass the 50 MB cap and nothing else changed — no snapshot"
    exit 0
  fi
fi

# Identical to the newest snapshot? Compared from the first `diff --git` line on, because
# the header's stamp and session differ on every run. No header line can start that way,
# and no base85 line can either (the alphabet has no space). ⚠ By `git hash-object`, not
# `cmp`: the Fedora tools/devcontainer image ships no diffutils, and there `cmp` is "command
# not found" — a dedupe that never fires. git is the one tool this hook already needs.
NEWEST=""
for f in "$DIR"/*.patch; do
  if [ -f "$f" ]; then NEWEST="$f"; fi
done
if [ -n "$NEWEST" ]; then
  sed -n '/^diff --git /,$p' "$NEWEST" >"$WORK/prev" 2>/dev/null
  SUMS="$(git hash-object --no-filters -- "$WORK/body" "$WORK/prev" 2>/dev/null)"
  case "$SUMS" in
    *"$NL"*) if [ "${SUMS%%"$NL"*}" = "${SUMS#*"$NL"}" ]; then exit 0; fi ;;
  esac
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)"
case "$STAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) note "date gave no UTC stamp — no snapshot"; exit 0 ;;
esac
ISO="${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2}T${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2}Z"
SESSION_ID="$(printf '%s' "$IN" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
SID="${SESSION_ID//[^A-Za-z0-9_-]/}"
SID8="${SID:0:8}"
[ -n "$SID8" ] || SID8="nosession"
FINAL="$DIR/$STAMP-$SID8.patch"
# Same second, same session: the newer patch replaces the older (it differs, see above).

R="${ROOT//$NL/?}"; R="${R//$CR/?}"
B="${BRANCH//$NL/?}"; B="${B//$CR/?}"
{
  printf '# eugo-wip-snapshot: the uncommitted work at one turn end (git apply skips these lines)\n'
  printf '# repo: %s\n' "$R"
  printf '# head: %s\n' "${HEAD_SHA:-(unborn: no commit yet)}"
  printf '# branch: %s\n' "$B"
  printf '# taken: %s\n' "$ISO"
  printf '# session: %s\n' "${SID:-(none)}"
  printf '%s%s%s%s' "$SKIPPED" "$DROPPED" "$SUBMODS" "$UNREAD"
  printf "# restore: in a clean checkout at that head, git apply --binary '%s'\n" "$FINAL"
  cat "$WORK/body"
} 2>/dev/null >"$WORK/out" || fail "cannot write in $DIR"

SIZE=$(( $(wc -c <"$WORK/out" 2>/dev/null || echo 0) + 0 ))
if [ "$SIZE" -gt "$MAX_PATCH" ]; then
  note "the snapshot of $ROOT is $SIZE bytes, over the 50 MB cap — not written (commit or stash the large change)"
  exit 0
fi
chmod 600 "$WORK/out" 2>/dev/null
mv -f -- "$WORK/out" "$FINAL" 2>/dev/null || fail "cannot write $FINAL"
WITHOUT=""
if [ -n "$UNREAD" ]; then WITHOUT="some unreadable files"; fi
if [ "$ndrop" -gt 0 ]; then
  WITHOUT="${WITHOUT:+$WITHOUT and }$ndrop untracked file(s), to fit the 50 MB cap"
fi
if [ -n "$WITHOUT" ]; then
  note "snapshot written without $WITHOUT — see the header of $FINAL"
fi

# ---- retention -------------------------------------------------------------------------
# Glob order is oldest first (C collation, fixed-width stamps). The newest $KEEP stay. Past
# them, walking newest to oldest, a patch stays only while it is the newest of a session
# with none among the newest $KEEP, was modified under 72 h ago, and fewer than
# $KEEP_SESSIONS such are kept. The session is the name after the 16-character stamp.
P=( "$DIR"/*.patch )
N=${#P[@]}
if [ -f "${P[0]}" ] && [ "$N" -gt "$KEEP" ]; then
  YOUNG="$NL$(find "$DIR" -maxdepth 1 -name '*.patch' -mmin -"$FLOOR_MIN" 2>/dev/null)$NL"
  SEEN=" "; extra=0; i=$(( N - 1 ))
  while [ "$i" -ge 0 ]; do
    f="${P[$i]}"; s="${f##*/}"; s="${s:17}"; s="${s%.patch}"
    if [ "$i" -lt $(( N - KEEP )) ]; then
      case "$SEEN" in
        *" $s "*) rm -f -- "$f" ;;
        *) case "$YOUNG" in
             *"$NL$f$NL"*) if [ "$extra" -lt "$KEEP_SESSIONS" ]; then extra=$(( extra + 1 )); else rm -f -- "$f"; fi ;;
             *) rm -f -- "$f" ;;
           esac ;;
      esac
    fi
    SEEN="$SEEN$s "
    i=$(( i - 1 ))
  done
fi
exit 0
