#!/usr/bin/env bash
# The DELETION GUARD: a recursive delete whose target can silently become a parent does not run.
#
# WHY THIS EXISTS. On 2026-09-23 a session ran
#     python3 sw20_ctl.py && C=outputs/_state/ctl-sw20 && ...; docker compose exec -T tools rm -rf /repo/$C
# The python step failed, so `C` was never set, the `;` ran the delete anyway, and
# `rm -rf /repo/` ran as root in the tools container, which bind-mounts the whole checkout
# at /repo. The checkout, its .git, every DB dump (outputs/_backups lived inside the tree)
# and hours of uncommitted work were gone; the tree was restored from GitHub. Prose rules
# ("never rm a path built from an unguarded variable") existed and did not stop it. This
# hook is the mechanical backstop.
#
# WHAT IT DOES. On `PreToolUse` (matcher `Bash`) it DENIES a real `rm` with a recursive flag
# (`-r`, `-R`, `--recursive` or any prefix GNU accepts, any short cluster holding r/R) and a
# `find` with `-delete` or `-exec|-execdir|-ok|-okdir rm` (rm past a wrapper, `-exec sudo rm`, or a shell `-c` string
# holding an rm: §1.164; the cd rule still reads a literal rm), when one of its path operands
#   (a) carries an UNGUARDED expansion — `$NAME`, `${NAME}`, `${NAME%…}`, `${NAME#…}`,
#       `${NAME:-…}`, `${NAME-…}` (a default can still be empty), `${NAME?…}` (it aborts only
#       when NAME is UNSET: a failed `C=$(…)` leaves C set and empty, and that passes), `$1`,
#       `$@`, `$(…)`, backticks; `${NAME:?…}` is GUARDED (empty or unset aborts the command),
#       and `$$`, `$?`, `$#`, `$-`, `$((…))` never expand to nothing; or
#   (b) normalises (repeated and trailing slashes, leading `./`, `.`/`..` components; a leading `${PWD:?…}` reads as
#       `.`, §1.164) to a
#       protected root, or to one followed by `/*` or `/.*`: / . .. (and any run of ..) * .* ~
#       /repo /opt /opt/eugo /opt/eugo/<one component> (a whole checkout) /home /home/<user>
#       one component under /home/user not starting with `.` (a cloud session's checkout, §2.45) /root — `~user` counts as a home. find with no starting point starts at `.`. A find
#       whose delete only reaches NAMED entries — a positive -name/-path/-regex test before the
#       action, its literal pattern holding a letter or digit, and no -o, `,` or parentheses
#       (`find . -name __pycache__ -exec rm -rf {} +`) — may start at `.` or another RELATIVE
#       path, never at an absolute path or a home (operator ruling 2026-09-24: `find ~ -name .git
#       -exec rm -rf {} +` deletes every repo's .git); (a) still holds. After a cd that may have
#       failed, a relative start is denied too (§2.68, below).
# A name assigned a LITERAL earlier in the same command is not unknown: `B=/tmp/x; rm -rf $B/y`
# is checked as `/tmp/x/y`, and `C=/ && rm -rf $C` is still a root. It is bound only when the
# assignment provably ran in this shell before the delete: a bare `NAME=word` (no space, glob,
# `~`, quote or `$` in the value), not piped or backgrounded, either at top level before any
# compound command, subshell or function, or earlier in the delete's own `&&` chain — the
# incident's `C=… && echo x; … rm …` crosses a `;`, so C is unknown there. Any later assignment
# to the name forgets it; a compound command, `IFS=` and every builtin that can set a variable
# without `NAME=` (`read`, `unset`, `eval`, `source`, `declare`/`local`/`readonly`, `printf -v`,
# …) forget every name and stop binding. A `bash -c` string, a `$(…)` body and a -c string the
# outer shell expands start with nothing bound, and an operand holding a brace group is never
# resolved (`/repo/{$C,}` expands its braces first: it is `/repo/x` AND `/repo/`).
# It splits on ; && || | & ( ) and newlines (a case pattern's `)` and its optional `(` end the pattern, never a
# subshell or a `$(…)`/`<(…)` body: §2.70), reads quotes the way bash does (a single-quoted
# `$X` is text, a double-quoted one expands), skips comments and heredoc bodies — save the `$(…)`, backticks and `${…}`
# of an UNQUOTED delimiter's body, which bash runs and which are checked (§1.163) — and recurses
# into the string of `bash|sh|zsh|dash|ksh -c` (any cluster holding c: `-lc`, `-ec`), into
# every `$(…)` / backtick / `<(…)` body (one in a `${…}` operand too, a `'…'` span's included: §1.158,
# watch:3e520ba1e), and past `function NAME`, `coproc [NAME]`, `builtin`, `sudo`, `env`, `xargs`, `timeout`, `nice`,
# `nohup`, `time`, `command`, `exec`, `setsid`, `ionice`, `stdbuf`, `busybox <applet>`, into
# `su … -c STRING` / `--session-command STRING`, `runuser -u USER [--] cmd…` and su-style
# `runuser [-] USER -c STRING`, `flock <file> -c STRING` / `flock <file> cmd…` and `watch` (whose words it
# joins and runs with `sh -c`, so they are checked as that string: nothing binds), past
# leading `VAR=value` words, shell keywords (`then`, `do`, `!`,
# `{`, …), `docker [compose] exec|run` (`<container|service|image>`) and `docker-compose
# exec|run` — the incident's blast radius, since `run` bind-mounts the checkout just as well. §1.170: a `<<` inside an
# arithmetic `((…))` or `for ((…))` is a shift, never a heredoc (bash runs the next line); the `$(…)`, backticks, `${…}`
# and `"…"` inside `$((…))` are read (they run first, and a `'…'` there quotes nothing); and `$((cmd); …)`, whose inner
# `(` closes with no second `)` straight after it, is bash's command substitution and is read as one. RULED 2026-10-05
# (§2.70 (k)): an extglob group `!(…)` `@(…)` `*(…)` `+(…)` `?(…)` in ARGUMENT position is one glob word, never a
# subshell (at a command's start `!(` keeps bash's negation-plus-subshell reading), and a match-all or `!(…)` group counts
# as `*` for the root rule, so `rm -rf /!(keep)` is a root while a bare `rm -rf !(keep)` in the current folder is not.
# The deny is `permissionDecision: "deny"` with a one-line reason naming the operand and the
# fix. That a deny stops the call is the Claude Code hooks contract; it was NOT probed on this
# box (the publish guard's probe covered "ask"), including under bypassPermissions.
#
# §2.53 — A GLOB RM AFTER A CD THAT MAY HAVE FAILED. It also DENIES an rm, with any flags, of an
# unquoted RELATIVE glob (`*`, `*.log`, `./*`, `sub/*.o`, `../*`; quoted or escaped it is a file
# name) after a `cd`/`pushd` in the same shell whose failure may not stop it — joined by `;`, a
# newline, `||` or `&`: when that cd fails, the glob deletes in the directory the command started
# in (report:119: `mkdir -p $P/mx2; cd $P/mx2; rm -f *` from a repo root). It passes the cd's own
# `&&` chain (a newline after `&&`, a pipe, or a subshell entered from it), the FIRST command of a
# then/do body of `if cd X` / `while cd X` (never `! cd` or `until cd`), and `cd X || exit [N]`
# (`|| return` falls through outside a function). §2.69: so do every command of a then/do or
# `{ … }` body entered only when the cd succeeded, and an rm after `cd X || { …; exit [N]; }`
# (the group's own unconditional exit; a conditional one, or one inside a compound, does not
# count; nor does an exit piped or backgrounded, which ends only its subshell — audit-w276 #1). §2.71 (b): a compound
# BEFORE that exit (`cd X || { echo no; if a; then :; fi; exit 1; }`) no longer cancels it, and the group ends at its
# own `}`, never at a nested one. §2.71 (B11): `if ! cd X; then …; exit [N]; fi` proves the cd at its `fi` the same way
# (its then-body runs exactly when the cd failed), and a later `else`/`elif` runs after a cd that worked — only for the
# negated cd alone as the condition, the if the level's only open compound, the exit unconditional at the then-body's top
# (not piped, backgrounded or in an `&&`/`||` chain); `|| return`/`|| continue` forms stay denied. §2.70 (h)(q): a cd proven inside a body that may not run — an `if` whose test failed,
# a `{ …; }` after an `&&` whose left side failed, a loop that ran zero times, a function only defined — proves nothing
# after its closer: each compound's skipped and alternative paths are folded into the state there, the riskier kept.
# §2.71: a compound entered from the cd's `&&` chain is guarded to its own closer, and the chain runs on past it
# (`cd X && { make; } && rm -f *`, an `else` inside it included), unless another closer or `else` is stacked on that
# closer; `|| continue|break` and `|| return` (bare, or a `{ …; continue; }` group closed alone) guard the rest of
# their loop's or function's body, never past its `done`/`}` — not piped or backgrounded, not in a subshell, not
# inside a piped or backgrounded compound within the loop (a subshell there has no loop in bash >= 5.0:
# watch:c41ccd2d), and not in a function defined inside the loop.
# Every walk reads a command's leading reserved words ONE way (`lead_words`, run 1255): past `!`, `time`, its `-p` and
# `--`, `function NAME` and `coproc [NAME]`, so `time -p until …; do` finds its loop and `function g { :; }` inside a
# then-body is a compound, not the body's end. A `for`/`select` whose body is `{ …; }` (bash's other loop form, `for f in
# a; { …; }`) reads that `{` as its `do`: its `}` ends the loop (§2.70 (f)).
# §2.70 (s): an exit, continue, break or return proves a cd only when the shell runs it — bare, quoted, after `builtin`
# or `command` or the `time` keyword; one run by an external program (`env exit`, `sudo exit`, `nohup exit`, a quoted
# `"time" exit`, `flock FILE exit`) fails and proves nothing.
# §2.70 (d): a negated cd (`! cd X`, `time ! cd X`) guards nothing, and a cd joined by `||` guards only when the left
# side did (`cd X; true || cd Y && rm -f *` skips `cd Y` and deletes where the failed `cd X` left it).
# §2.68 (operator ruling 2026-10-04): after such a cd it also denies a deleting `find` (`-delete`, `-exec|-execdir|-ok|
# -okdir rm`) from a RELATIVE start (none given is `.`), and a RECURSIVE rm of a relative operand (`rm -rf build`,
# `../sib`, `build/${N:?}`) — when the cd fails, each deletes a tree in the directory the command started in. Never a
# plain `rm -f file`; the root and expansion reasons above still come first (`cd X; find . -delete` names the root).
# `set -e` is not modelled (ruled 2026-10-04, §2.68 (c)) — write `cd X || exit`. A cd in its own explicit subshell
# `( … )` moves nothing. §2.71 (c) (ruled 2026-10-05): neither does one in a background job (the whole and-or list an
# `&` ends), in an element of a pipeline or in a coproc — each runs in a subshell of its own (`subshell_spans`), its cd
# and its `|| exit` stay there, and a delete after it with no cd of this shell's own before it is DENIED with its own
# reason (`cd X & rm -f *`, `cd X | cat; rm -f *`); a delete inside the same job or compound as its cd is still guarded
# by it, and `(cd X) & …` stays allowed. §2.70 (o): inside a coproc the compound after `coproc [NAME]` is read like any
# other (an `until` body there runs when its condition's cd failed), and a reserved word after `coproc` is that word,
# never the NAME. A delete with no cd before it is never blocked by this rule (operator ruling 2026-10-03).
#
# WHAT IT NEVER DOES. It never blocks any other NON-recursive rm (`rm -f "$f"` deletes one file at
# most, never a parent tree, even after a cd; `rm -f *.log` with no cd before it), a literal path below a root
# with no cd before it that may have failed (§2.68)
# (`rm -rf build/ outputs/_state/x`), `git rm`, `docker rm`, `docker run --rm`, `npm rm`, `rmdir`,
# or `rm` inside a quoted string, a comment or a heredoc body (not inside a `$(…)` an unquoted body runs). It is a
# backstop, not a sandbox: a
# script file, a pipe fed to a shell (`… | sh`, `cat <<EOF | bash`; a heredoc or here-string fed to one IS read as its
# commands: §1.163), `sudo -s` / `su` with no -c, `source /dev/stdin`, `eval`, `env -S`,
# `docker container exec|run`, `kubectl exec`, `ssh`, python's `shutil.rmtree` (it only opens the
# parser: nothing denies on it) and a variable whose VALUE is `/` or `.` but was set outside this
# command are not parsed or cannot be known. Nor, after a cd that may have failed, are a cd that an
# inner shell or a substitution inherits (`cd X; bash -c 'rm -f *'`), an operand or start led by an UNBOUND
# expansion (`rm -rf "$D"/x` is the primary rule's; `"${D:?}/x"` names its own directory — `"${PWD:?}/x"`, `$PWD/*`
# and `~+/x` name the one a failed cd left and ARE checked, §2.70 (n), as do `"$(pwd)"/*` and `` `pwd`/* ``, §2.70 (p); a
# literal bound earlier, `D=build; cd X; rm -rf
# $D/x`, is resolved and checked: audit-w279 #21), a delete in a container (`docker … exec`: a host cd never reaches
# it; `flock FILE cmd…`, `runuser -u USER cmd…` and `builtin cd` are read since §2.70 (b)(c)), a delete fed by a pipe
# or an inner shell (`find … | xargs rm -rf`, `-exec sh -c 'rm -rf "$1"'`), or the shapes §2.70 and §2.71 still list.
# §2.70 (k)'s quoted half: a quoted or escaped word (`"case"`, `\esac`, `"{"`, `"done"`) is a plain word in bash, never a
# keyword: the lexer and every walk read it so (`"case" a in; rm -rf /` is a command named case, then the rm); the gates
# that PROVE a cd keep the plain reading, so a quoted word there only adds denies (`cd X || "!" exit; rm -f *`).
# §1.163: an UNQUOTED heredoc body (`<<EOF`, no `'`, `"` or `\` anywhere in the delimiter word) is expanded by the shell
# before its command reads it, so its `$(…)`, backticks and `${…}` are checked as commands; a `"` or `'` there quotes
# nothing. Its lines are LOGICAL: one ending in an odd run of `\` continues on the next (bash and dash agree), and the
# delimiter test reads the joined line. bash reads `<<$'EOF'`'s delimiter as EOF and dash as `$EOF`: both are read.
# A heredoc (quoted or not) or a here-string FED TO A SHELL — `bash <<'EOF'`, `sh -s`, `sh -`, through `sudo`, `docker
# … exec` or `runuser -u`, never `bash -c …` or `bash FILE` — is read as that shell's commands; an unquoted body as the
# inner shell gets it (`\$` → `$`), with nothing bound (the OUTER shell expands it first).
#
# TRANSPORT. Payload on stdin, program on fd 3, verdict by EXIT CODE (0 allow, 3 deny, 4 the
# checker failed) with the one-line reason on stdout — never argv and never a heredoc inside
# `$(…)`, for the publish guard's reasons (E2BIG fail-open; bash 3.2's paren/quote scanning).
#
# Contract (each line is a test in tools/tests/test_deletion_guard_hook.py):
#   - every path exits 0 but one; a deny is ONE JSON line on stdout, an allow prints nothing
#   - a command with no `rm` word, no `-delete` and no `rmtree` never starts python
#   - a CRASH in the checker (python ran and raised) FAILS CLOSED: ONE stderr line and exit 1, which the row's
#     `onFailure: "block"` makes a block on Claude Code 2.1.295+ (an older client reports a hook error and runs the
#     command) — §3.52 S3.7, ruled 2026-10-11. A dead checker (python3 that cannot run: a macOS stub, a broken
#     install) and a missing python3 still FAIL OPEN with ONE stderr line, or such a box would block every rm. A
#     command nested past MAX_NEST (100) levels is DENIED before it can crash the checker (§1.176)
#   - a payload that is not a Bash hook JSON object is allowed silently
#   - EUGO_DELETION_GUARD=off in the HOOK's environment disables it; an inline
#     `EUGO_DELETION_GUARD=off rm …` in the command does not
#   - an errexit INHERITED through BASH_ENV is disarmed first (the deploy image's bash_env; see
#     eugo-external-publish-guard.sh: under it the verdict's own exit 3 killed the hook before
#     the JSON printed, and a non-2 exit is non-blocking — the delete would run)
#   - bash 3.2 safe; the python runs on 3.9+
set +eE +o pipefail
trap - ERR
set -u

if [ "${EUGO_DELETION_GUARD:-}" = "off" ]; then
  exit 0
fi
IN="$(cat 2>/dev/null || true)"
if [ -z "$IN" ]; then
  exit 0
fi
# Cheap pre-filter on the raw JSON: the common Bash call never starts python. `rm` counts as a
# WORD when neither side is [A-Za-z0-9_.-]; a JSON `\n` / `\t` / `\r` escape before it counts
# as a boundary too, or `cd x\nrm -rf $X` would slip past. Unquoted on the right of `=~` so
# bash 3.2 reads it as a regex.
RM_WORD='([^A-Za-z0-9_.-]|\\[nrt])rm([^A-Za-z0-9_.-])'
case "$IN" in
  *-delete*|*rmtree*) ;;
  *rm*) [[ $IN =~ $RM_WORD ]] || exit 0 ;;
  *) exit 0 ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  printf 'eugo-deletion-guard: python3 not found; the command was allowed unchecked\n' >&2
  exit 0
fi

verdict() {
  printf '%s' "$IN" | PYTHONUTF8=1 python3 -S /dev/fd/3 3<<'PY' 2>/dev/null
import json, posixpath, re, sys

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
GUARDED_RE = re.compile(r"(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+):\?")     # the body of ${X:?…}; ${X?…} passes a SET, EMPTY X
ASSIGN_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\+?=")
# a repo under /home/user is a cloud checkout; a dot-folder there (.cache, .venv) is not one (audit-w260 #1)
HOME_RE = re.compile(r"(?:(?:/opt/eugo|/home)/[^/]+|/home/user(?:/[^/.][^/]*))(?:/\*)?")
TILDE_RE = re.compile(r"~[^/]*(?:/\*)?")
PROTECTED = frozenset(("/", "/*", ".", "..", "*", ".*", "~", "/repo", "/repo/*", "/opt", "/opt/eugo", "/opt/eugo/*",
                       "/home", "/root"))
# A name bound to a literal earlier in the same command. The value must be ONE literal word: no space, glob,
# `~`, quote or `$`, so bash cannot split, glob or expand it into something else.
BIND_REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
BIND_VALUE_RE = re.compile(r"[A-Za-z0-9_./@%+,:-]+")
# Every name bash sets itself (`env -i bash -c 'compgen -v'`, bash 5.2) plus those cd/read/getopts and the
# array-reading builtins write by default.
NEVER_BIND = frozenset((
    "BASH BASHOPTS BASHPID BASH_ALIASES BASH_ARGC BASH_ARGV BASH_ARGV0 BASH_CMDS BASH_COMMAND BASH_EXECUTION_STRING "
    "BASH_LINENO BASH_LOADABLES_PATH BASH_SOURCE BASH_SUBSHELL BASH_VERSINFO BASH_VERSION COMP_WORDBREAKS DIRSTACK "
    "EPOCHREALTIME EPOCHSECONDS EUID GROUPS HISTCMD HOSTNAME HOSTTYPE IFS LINENO MACHTYPE OPTERR OPTIND OSTYPE PATH "
    "PPID PS4 PWD RANDOM SECONDS SHELL SHELLOPTS SHLVL SRANDOM TERM UID _ OLDPWD REPLY OPTARG MAPFILE").split())
# The builtins of `compgen -b` that can set a variable with no NAME=value word (`printf` only with -v; export's
# NAME=value words are assignments and are seen as such). Each forgets every name and stops binding. The two
# array-reading builtins are not listed: they write only the name they are given, and a command that names a
# bound variable as a bare word forgets it anyway.
FORGET = frozenset((".", "source", "eval", "read", "unset", "getopts", "let", "declare", "typeset", "local",
                    "readonly", "wait", "trap", "fc", "builtin"))
# A compound command (like a subshell or a function) runs its body conditionally, repeatedly or later.
COMPOUND = ("if", "while", "until", "for", "select", "case", "{", "function", "coproc")
SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
KEYWORDS = ("if", "then", "else", "elif", "do", "while", "until", "!", "{", "}")
EXEC_ACTIONS = ("-exec", "-execdir", "-ok", "-okdir")
REDIR = "<redirect>"
# §2.70 (a) — a case statement's pattern list, as the lexer emits it: CASE_PAT opens a pattern (its words are DATA,
# never a command), CASE_SEP is the `)` that ends it and starts the arm's body. Neither is a subshell paren.
CASE_PAT, CASE_SEP = "<case-pattern>", "<case-body>"
# The reserved words after which the next word is still in command position, where `case` and `esac` are words of
# the shell's grammar.
CMD_KEEP = ("if", "then", "else", "elif", "do", "while", "until", "!", "{", "time")
# §1.158 (b) — `coproc NAME` takes a name only before a compound command: these words open one.
COPROC_COMPOUND = ("{", "if", "while", "until", "for", "select", "case", "[[")
# §2.70 (o) — bash's reserved words (`compgen -k`) less `time`: after `coproc` each one is that word, never the NAME
# (`coproc until { :; }; …` is an until loop), while `coproc time { …; }` runs a coproc NAMED time (bash 5.2: it ran).
RESERVED = frozenset(("if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done",
                      "in", "function", "{", "}", "!", "[[", "]]", "coproc"))


def co_name(words, j):
    """§2.70 (o) — whether words[j] is the NAME of the `coproc` before it: a name that is no reserved word, with a compound
    command after it. The bound lives here: `coproc N; rm -rf /` has no word after N, and a crash would allow it."""
    return (j + 1 < len(words) and kw(words[j + 1]) in COPROC_COMPOUND and kw(words[j]) not in RESERVED
            and NAME_RE.fullmatch(words[j].text) is not None)
# Options that take a VALUE, per wrapper; every other `-x` is a flag. `command -v|-V` only
# looks a name up and is handled below.
WRAPPERS = {
    "sudo": ("-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "--user", "--group", "--host",
             "--prompt", "--close-from", "--chdir", "--role", "--type", "--other-user", "--command-timeout"),
    "env": ("-u", "-C", "-S", "--unset", "--chdir", "--split-string"),
    "nice": ("-n", "--adjustment"),
    "timeout": ("-s", "-k", "--signal", "--kill-after"),
    "xargs": ("-a", "-E", "-I", "-L", "-n", "-P", "-s", "-d", "--arg-file", "--eof", "--max-lines",
              "--max-args", "--max-procs", "--max-chars", "--delimiter", "--process-slot-var"),
    "nohup": (), "time": (), "command": (),
    # §1.103 L1 — five more that run the command after them (run 1217's audit: each let
    # `rm -rf /repo/$C` through). An attached value (`ionice -c3`, `stdbuf -oL`) is one word, a flag here.
    "exec": ("-a",), "setsid": (), "busybox": (),
    # §2.70 (b) — `builtin cd X` is a cd (and `builtin read …` still forgets every binding: the base peel leaves).
    "builtin": (),
    "ionice": ("-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"),
    "stdbuf": ("-i", "-o", "-e", "--input", "--output", "--error"),
}
# §1.103 L1 — the other three carry the command differently (see check_command).
FLOCK_VALUED = ("-w", "--wait", "--timeout", "-E", "--conflict-exit-code")
WATCH_VALUED = ("-n", "--interval", "-q", "--equexit")
# §1.109 (b) — `runuser --help` (util-linux): -u runs the command after the options; without -u it is su's
# form, and -c/-f/-l/-s are mutually exclusive with -u (runuser refuses the mix, so nothing runs).
RUNUSER_VALUED = ("-u", "--user", "-g", "--group", "-G", "--supp-group", "-w", "--whitelist-environment",
                  "-s", "--shell", "-c", "--command", "--session-command")
# §1.103 L2 (operator ruling 2026-09-24) — `NAME=$(mktemp …)` earlier in the SAME `&&` chain is never
# empty: a failed mktemp stops the chain before the delete. Bound to this stand-in path, so a root
# reached from it (`"$D"/../..`) is still a root; across `;` the binding ends and it is unguarded again.
MKTEMP_RE = re.compile(r"\s*mktemp(?:\s+[-A-Za-z0-9_./%+=:,@]+)*\s*")
MKTEMP_BOUND = "/tmp/mktemp.XXXXXXXXXX"
DOCKER_VALUED = ("-c", "--context", "-H", "--host", "-l", "--log-level", "--config",
                 "--tlscacert", "--tlscert", "--tlskey")
COMPOSE_VALUED = ("-f", "--file", "-p", "--project-name", "--project-directory", "--env-file",
                  "--profile", "--ansi", "--progress", "--parallel")
EXEC_VALUED = ("-e", "--env", "--env-file", "-u", "--user", "-w", "--workdir", "--detach-keys", "--index")
# `docker run --help` (29.6) valued options, plus compose run's --env-from-file; the rest of both are flags.
RUN_VALUED = EXEC_VALUED + (
    "--add-host", "--annotation", "-a", "--attach", "--blkio-weight", "--blkio-weight-device", "--cap-add", "--cap-drop",
    "--cgroup-parent", "--cgroupns", "--cidfile", "--cpu-period", "--cpu-quota", "--cpu-rt-period", "--cpu-rt-runtime",
    "-c", "--cpu-shares", "--cpus", "--cpuset-cpus", "--cpuset-mems", "--device", "--device-cgroup-rule",
    "--device-read-bps", "--device-read-iops", "--device-write-bps", "--device-write-iops", "--dns", "--dns-option",
    "--dns-search", "--domainname", "--entrypoint", "--env-from-file", "--expose", "--gpus", "--group-add",
    "--health-cmd", "--health-interval", "--health-retries", "--health-start-interval", "--health-start-period",
    "--health-timeout", "-h", "--hostname", "--ip", "--ip6", "--ipc", "--isolation", "-l", "--label", "--label-file",
    "--link", "--link-local-ip", "--log-driver", "--log-opt", "--mac-address", "-m", "--memory",
    "--memory-reservation", "--memory-swap", "--memory-swappiness", "--mount", "--name", "--network", "--net",
    "--network-alias", "--oom-score-adj", "--pid", "--pids-limit", "--platform", "-p", "--publish", "--pull",
    "--restart", "--runtime", "--security-opt", "--shm-size", "--stop-signal", "--stop-timeout", "--storage-opt",
    "--sysctl", "--tmpfs", "--ulimit", "--userns", "--uts", "-v", "--volume", "--volume-driver", "--volumes-from")
PWD_RE = re.compile(r"\$(?:PWD|\{PWD)(?![A-Za-z0-9_])")      # §2.70 (n): `$PWD`, `${PWD}`, `${PWD:?}`, …
# §2.70 (r) — a `${…}`'s operator: a POSIX pattern (`#` `##` `%` `%%`, of a name, a digit run or `@`/`*`) or a POSIX
# value (`:-` `-` `:=` `=` `:+` `+` `:?` `?`); anything else (`/`, `^`, `,`, `:N`, a subscript, …) is neither.
PE_OP_RE = re.compile(r"(?:([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*])(##?|%%?)|!?(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])(:?[-=+?]))")
_PWD_BODY = r"\s*(?:(?:builtin|command)\s+)?(?:(?:/usr)?/bin/)?pwd(?:\s+-[LP]+)*\s*"
PWD_CMD_RE = re.compile(r"\$\(%s\)|`%s`" % (_PWD_BODY, _PWD_BODY))   # §2.70 (p): `$(pwd)`, `` `pwd` ``, the same folder
NAME_TESTS = ("-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex")


class Word(object):
    """One shell word. `text` has its quotes removed and every expansion kept verbatim; `live`
    lists the expansions the SHELL performs (never one inside single quotes) as (kind, shown):
    "var" can be empty, "guarded" is ${X:?}/${X?}, "fixed" never expands to nothing, "cmd" is a
    $(…)/backtick/<(…) whose BODY is in `subs` (checked as a command of its own). `glob` — an unquoted
    `*`, `?` or `[` (§2.53)."""
    __slots__ = ("text", "live", "subs", "tilde", "glob", "every", "quoted", "redir", "buf", "nofail", "redbad", "hd")

    def __init__(self, text=""):
        self.text, self.live, self.subs, self.tilde, self.glob = text, [], [], False, False
        self.every = []                                       # B10: (an extglob group, its op) that may match ALL
        self.quoted = False                                   # B10: a `\`, '…', "…", $'…' or $"…" part: never a keyword
        self.redir = False                                    # audit-w284: (first word) a redirect there may fail
        self.redbad = False                                   # #22: (first word) a redirect target that may abandon
        self.hd = False                                       # #22: a heredoc placeholder (its body is expanded)
        self.buf = []                                         # §1.175: the pieces the lexer appends, joined by flush
        self.nofail = False                                   # §6813: a redirect target that cannot fail to open

    def flush(self):
        """§1.175 — join the pieces the lexer appended. Grown one character at a time on the `text` attribute, a word
        was copied at every step: one 1 MB word cost 6.4 s of CPU, and a hook that times out ALLOWS."""
        if self.buf:
            self.text += "".join(self.buf)
            self.buf = []
        return self


class Lexer(object):
    """Bash's word/operator split, enough of it to know which words are commands. Lenient: an
    unterminated quote or substitution runs to the end (bash would refuse to run it at all)."""

    def __init__(self, s):
        self.s, self.n = s, len(s)
        self.memo = {}                                        # §1.170: ("r"|"a", start) -> what `run`/`arith` read
        self.feeds = []                                       # §1.163: (a body fed to a shell, bind) — `_check_text`

    def run(self, i, stop):
        """Lex from i. With `stop` it ends at the `)` closing a $( or <( body: returns
        (tokens, index after that `)`, closed).

        §2.70 (a) — each open `case` has a state: `subj` (its word), `in`, `pat` (a pattern may start), `pat+`
        (inside one), `body`. In a pattern, `(`/`)`/`|` are the pattern's own (CASE_PAT, CASE_SEP, swallowed) and
        never touch the subshell or `$(` depth; an extglob `@(a|b)` stays one word. `case` counts only in command
        position, never as a redirect's target, and an unquoted `esac` first in a pattern position closes the case
        (bash 5.2: `case esac in esac)` is a syntax error; a quoted `"esac"` is a pattern — a known gap, §2.70).
        §1.170 — with `stop` the result is memoized per start (every such caller keeps only the end): `arith` re-reads
        a `$((cmd) …)` text as a command substitution, so each body is lexed once. Inline, not a wrapper: a frame
        more per level would lower the nesting depth at which the checker overflows the stack (§1.176: `dollar` and
        `nested` count every level, and past MAX_NEST the command is denied before that)."""
        if stop and ("r", i) in self.memo:
            return self.memo[("r", i)]
        i0 = i
        s, n = self.s, self.n
        toks, heredocs, w, depth = [], [], None, 0
        cases, ppar = [], 0
        cmd, tgt = True, False
        arg = False                                           # B10: the command word has been seen (an argument follows)
        dbl = 0                                               # audit-w279 #19: `[[` opened in command position
        ar = None                                             # §1.170: the depth an arithmetic `((` opened at
        hs = []                                               # §1.163: pending here-strings (command start, REDIR index)

        def start():
            """§1.163 — where the simple command being lexed starts in toks (past its words and redirects)."""
            k = len(toks)
            while k and (isinstance(toks[k - 1], Word) or toks[k - 1] == REDIR):
                k -= 1
            return k

        def settle():
            """§1.163 — a here-string fed to a shell is read as its commands; the outer shell expands it first."""
            for k, r in hs:
                cs = commands(toks[k:])
                if r + 1 < len(toks) and isinstance(toks[r + 1], Word) and cs and stdin_shell(cs[0][0]):
                    self.feeds.append((toks[r + 1].text, False))
            del hs[:]
        # §1.158 / §2.70 (i)(j) — the words after which the NEXT word is still in command position: `function NAME`
        # (pend "fname": NAME, then the body), `coproc` (pend "co": a command, or a NAME a compound follows: "coname"),
        # and `time -p` (prev).
        pend, prev = None, None

        def word(x):
            """Append a finished word, stepping the case state and the command position."""
            nonlocal cmd, tgt, dbl, pend, prev, arg
            x.flush()                                         # §1.175: the word is finished, its pieces joined once
            st = cases[-1] if cases else None
            k = kw(x)                                         # B10: a quoted word is no keyword
            if tgt:                                           # a redirect's target is never a keyword
                # §6813: a here-string cannot fail to open; §1.181 (b): nor a dup of fd 0-2 or its close (`-`), and that
                # only after `>&` / `<&` — after `>`, `<`, `&>`, … a target named 0, 1, 2 or `-` is a FILE, which may fail
                x.nofail = tgt == "hs" or (tgt == "dup" and x.text in ("0", "1", "2", "-"))
                tgt = cmd = False
            elif st == "pat" and k == "esac":
                cases.pop()
                cmd = False
            elif st == "pat":
                toks.append(CASE_PAT)                         # the pattern's words are data
                cases[-1], cmd = "pat+", False
            elif st == "subj":
                cases[-1], cmd = "in", False
            elif st == "in":
                if k == "in":
                    cases[-1] = "pat"
                cmd = False
            elif st == "pat+":
                cmd = False
            else:
                if pend == "fname":                           # §1.158: `function NAME` — the body comes next
                    pend, prev = None, None
                    toks.append(x)
                    cmd, arg = True, False
                    return
                if pend == "coname":                          # `coproc NAME {` / `coproc NAME case …`
                    pend = None
                    cmd = cmd or k in COPROC_COMPOUND
                was, after_co = cmd, pend == "co"
                pend = None
                if cmd and k == "case":
                    cases.append("subj")
                elif cmd and k == "esac" and st == "body":
                    cases.pop()
                elif cmd and k == "[[":
                    dbl += 1
                elif dbl and k == "]]":
                    # audit-w279 #19 — bash takes a closer straight after `]]` (`[[ -n x ]] done`): the command ends
                    # here, so the next word is in command position and the walks see that closer.
                    dbl -= 1
                    toks.append(x)
                    toks.append(";")
                    cmd, arg = True, False
                    return
                cmd = cmd and k in CMD_KEEP
                if was and k == "function":
                    pend = "fname"
                elif was and k == "coproc":
                    cmd, pend = True, "co"
                elif was and k == "-p" and prev == "time":
                    cmd = True
                elif was and k == "--" and prev in ("time", "-p"):
                    cmd = True                                # run 1255 B8: `time [-p] --` (TIMEIGN): a command follows
                elif after_co and k != "case" and NAME_RE.fullmatch(x.text):
                    pend = "coname"                           # a NAME, if a compound command follows it
                prev = k if was else None
                # B10 — an argument may follow: past the command word (an assignment, a reserved word that keeps the
                # command position and `function NAME` are not it, so `X=1 !(…)` and `then !(…)` keep the subshell)
                arg = not cmd and pend != "fname" and (arg or not ASSIGN_RE.match(x.text))
            toks.append(x)

        while i < n:
            c = s[i]
            if c == "\\":
                if s.startswith("\\\n", i):                    # a line continuation joins the lines
                    i += 2
                    continue
                w = w or Word()
                w.quoted = True
                w.buf.append(s[i + 1:i + 2])
                i += 2
                continue
            if c in " \t\r\n":
                if w is not None:
                    word(w)
                    w = None
                i += 1
                if c == "\n":
                    toks.append(";")                          # a newline separates commands
                    cmd, tgt, pend, prev, arg = True, False, None, None, False   # audit-w281 #10: `prev` too
                    if heredocs:
                        i = self.bodies(i, heredocs, stop, toks)   # heredoc bodies are data, never commands (§1.163:
                        heredocs = []                         # save what an unquoted one runs, or a shell reads)
                    settle()
                continue
            if c == "#" and w is None:                        # a comment runs to the end of its line
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "'":
                j = s.find("'", i + 1)
                j = n if j < 0 else j
                w = w or Word()
                w.quoted = True
                w.buf.append(s[i + 1:j])
                i = j + 1
                continue
            if c == '"':
                w = w or Word()
                w.quoted = True
                i = self.dquote(i + 1, w)
                continue
            if c == "`":
                w = w or Word()
                i = self.backtick(i + 1, w)
                continue
            if c == "$":
                w = w or Word()
                i = self.dollar(i, w)
                continue
            if cases and cases[-1] in ("pat", "pat+") and (c in "()" or (c == "|" and not s.startswith("||", i))):
                if ppar or (c == "(" and w is not None):      # an extglob `@(a|b)` is one pattern word
                    w = w or Word()
                    w.buf.append(c)
                    ppar += 1 if c == "(" else -1 if c == ")" else 0
                    i += 1
                    continue
                if w is not None:
                    word(w)                                   # flush first: `esac)` closes the case
                    w = None
                if cases and cases[-1] in ("pat", "pat+"):
                    if c == "(" and cases[-1] == "pat":
                        toks.append(CASE_PAT)                 # the optional `(` before a pattern
                        cases[-1] = "pat+"
                    elif c == "(":
                        w, ppar = Word("("), 1                # a bare `(` inside a pattern: data
                    elif c == ")":
                        toks.append(CASE_SEP)                 # the pattern ends; the arm's body starts
                        cases[-1], cmd, arg = "body", True, False
                    i += 1                                    # a `|` between patterns is swallowed
                    continue
            if c == ")" and stop and depth == 0:
                if w is not None:
                    word(w)
                settle()
                self.memo[("r", i0)] = toks, i + 1, True
                return toks, i + 1, True
            if c in "<>" and s.startswith("(", i + 1):        # process substitution: a command body
                _, j, closed = self.nested(i + 2)
                w = w or Word()
                w.buf.append(s[i:j])
                w.live.append(("cmd", s[i:j]))
                w.subs.append(s[i + 2:j - 1] if closed else s[i + 2:j])
                i = j
                continue
            if c in ";&|()<>":
                if c in "<>" and w is not None and w.flush().text.isdigit() and not w.live:
                    w = None                                  # `2>`: the digits are a file descriptor
                if w is not None:
                    word(w)
                    w = None
                if ar is None and c == "(" and s.startswith("(", cont(s, i + 1)) and (cmd or prev == "for"):
                    ar = depth                                # §1.170: `((…))` / `for ((…))` is arithmetic (§1.181:
                    # the shells join a line continuation between the two `(` first, so `(\<newline>(…))` is one too)
                if s.startswith("<<<", i):
                    hs.append((start(), len(toks)))
                    toks.append(REDIR)
                    tgt = "hs"                                # §6813: nor can a here-string
                    i += 3
                    continue
                if s.startswith("<<", i) and ar is not None:
                    toks.append(REDIR)                        # §1.170: a shift there, never a heredoc (bash runs the
                    tgt = True                                # line after `((n<<=1))`)
                    i += 2
                    continue
                if s.startswith("<<", i):
                    strip = s.startswith("-", cont(s, i + 2))  # §6811: `<<\<newline>-EOF` is `<<-EOF`
                    delim, quoted, i = self.delimiter(cont(s, i + 2) + 1 if strip else i + 2)
                    # §1.163 — a REDIR and its placeholder target, appended straight to toks (not through word(), which
                    # would move the command position): `commands` skips the target, and the token loop in `_check_text`
                    # checks the substitutions `bodies` puts on it.
                    ph, k = Word(delim), start()
                    ph.hd = not quoted
                    ph.nofail = True                          # §6813: a heredoc cannot fail to open
                    toks.append(REDIR)
                    toks.append(ph)
                    heredocs.append((delim, strip, quoted, ph, k))
                    continue
                for op in ("&>>", "&>", ">>", ">&", ">|", "<&", "<>", ">", "<"):
                    if s.startswith(op, i):                   # `2>&1` / `&>` never split on `&`
                        toks.append(REDIR)
                        tgt = "dup" if op in (">&", "<&") else True   # §1.181 (b): a dup operator's target
                        i += len(op)
                        break
                else:
                    for op in (";;&", ";;", ";&", "&&", "||", "|&", ";", "&", "|", "(", ")"):
                        if s.startswith(op, i):
                            break
                    depth += 1 if op == "(" else -1 if op == ")" else 0
                    if ar is not None and depth <= ar:
                        ar = None                             # its `))`
                    toks.append(";" if op.startswith(";") else op)
                    if op in (";;", ";&", ";;&") and cases and cases[-1] == "body":
                        cases[-1] = "pat"                     # the arm ended: a pattern may start
                    cmd, tgt, pend, prev, arg = True, False, None, None, False
                    i += len(op)
                continue
            if c in "@*+?!" and s.startswith("(", i + 1) and arg and not (cases and cases[-1] in ("pat", "pat+")):
                w = w or Word()                               # B10: an extglob group in argument position
                w.glob = True
                i = self.extglob(i, w)
                continue
            if w is None:
                w = Word()
                w.tilde = c == "~"
            m = PLAIN_RE.match(s, i)                          # §1.175: ordinary characters, one piece per run
            if m:
                w.buf.append(m.group())
                i = m.end()
                continue
            w.glob = w.glob or c in "*?["                   # §2.53: only a BARE glob character globs
            w.buf.append(c)
            i += 1
        if w is not None:
            word(w)
        settle()
        if stop:
            self.memo[("r", i0)] = toks, n, False
        return toks, n, False

    def extglob(self, i, w):
        """B10 — an extglob group `OP(…)` from i: one glob word; a `$(…)`, backtick, `${…}` or quote inside it is read as
        anywhere else (its substitutions are still checked). A group that can match every name — `*(…)`, `!(…)`, or one
        with a match-all alternative such as `?(*)` / `@(*|x)` — goes to `w.every` for the root rule."""
        s, n = self.s, self.n
        op, at = s[i], len(w.flush().text)
        w.buf.append(s[i:i + 2])
        i, d = i + 2, 1
        while i < n and d:
            c = s[i]
            if c == "\\":
                w.buf.append(s[i + 1:i + 2])
                i += 2
                continue
            if c == "'":
                j = s.find("'", i + 1)
                j = n if j < 0 else j
                w.buf.append(s[i + 1:j])
                i = j + 1
                continue
            if c == '"':
                i = self.dquote(i + 1, w)
                continue
            if c == "`":
                i = self.backtick(i + 1, w)
                continue
            if c == "$":
                i = self.dollar(i, w)
                continue
            d += 1 if c == "(" else -1 if c == ")" else 0
            w.buf.append(c)
            i += 1
        alts, k = [""], 0
        w.flush()
        for ch in w.text[at + 2:len(w.text) - (0 if d else 1)]:
            k += 1 if ch == "(" else -1 if ch == ")" else 0
            if ch == "|" and not k:
                alts.append("")
            else:
                alts[-1] += ch
        if op in "*!" or any(a and not a.strip("*") for a in alts):
            w.every.append((w.text[at:], op))
        return i

    def dquote(self, i, w):
        s, n = self.s, self.n
        while i < n:
            c = s[i]
            if c == '"':
                return i + 1
            if c == "\\" and i + 1 < n:
                if s[i + 1] == "\n":
                    i += 2
                elif s[i + 1] in '$`"\\':
                    w.buf.append(s[i + 1])
                    i += 2
                else:
                    w.buf.append(c)
                    i += 1
                continue
            if c == "$" and s[i + 1:i + 2] not in ("'", '"'):  # `$"` / `$'` are text inside "…"
                i = self.dollar(i, w, dq=True)
            elif c == "`":
                i = self.backtick(i + 1, w)
            else:
                m = DQ_PLAIN_RE.match(s, i)                   # §1.175: a run of text up to the next `"`, `\`, `$`, `` ` ``
                w.buf.append(m.group() if m else c)           # (none: a `$` before a quote, a trailing `\`)
                i = m.end() if m else i + 1
        return n

    def backtick(self, i, w):
        s, n = self.s, self.n
        j, body = i, []
        while j < n and s[j] != "`":
            if s[j] == "\\" and j + 1 < n:
                body.append(s[j + 1] if s[j + 1] in "$`\\" else s[j:j + 2])
                j += 2
                continue
            body.append(s[j])
            j += 1
        w.buf.append("`" + s[i:j] + "`")
        w.live.append(("cmd", "`" + s[i:j] + "`"))
        w.subs.append("".join(body))
        return j + 1

    def arith(self, i, w):
        """§1.170 — `$((…))` from i (its `$`): (the index after it, whether bash reads it as a command substitution).
        Its `$(…)`, backticks, `${…}` and `"…"` run before the arithmetic (bash and dash both run `$(( $(cmd) + 1 ))`'s
        cmd), so their bodies go to `w.subs`; a `'` there quotes nothing (`$(( '$(cmd)' ))` runs cmd). bash reads
        `$((cmd); x)` (the inner `(` closed by a `)` with no second `)` straight after it) as a command substitution
        that starts with a subshell, so that text is lexed as one. Memoized per start, as `run` is: a nest of those
        re-reads each inner text, and unmemoized that doubled per level (16 deep took 6 s; the hook's timeout allows).
        §1.181 (a) — bash and dash join a line continuation before they read either pair of parens, so one between the two
        `(` or the two `)` changes nothing: `$(\\<newline>(…))` is arithmetic, where a `'` quotes nothing, never a command
        substitution starting with a subshell, where it would."""
        if ("a", i) in self.memo:
            j, comsub, subs = self.memo[("a", i)]
            w.subs.extend(subs)
            return j, comsub
        s, n = self.s, self.n
        j, d, inner, subs = cont(s, i + 2) + 1, 2, None, []   # §1.181: past the second `(`, continuations joined
        while j < n and d:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c in '"`' or (c == "$" and s.startswith(("(", "{"), cont(s, j + 1))):   # §1.174: joined first
                x = Word()
                j = self.dquote(j + 1, x) if c == '"' else self.backtick(j + 1, x) if c == "`" else self.dollar(j, x)
                subs.extend(x.subs)
                continue
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 1 and inner is None:
                    inner = j
                    if not s.startswith(")", cont(s, j + 1)):   # §1.181: the two `)` are joined first too
                        break                                 # a command substitution: read below, as a whole
            j += 1
        comsub = inner is not None and not s.startswith(")", cont(s, inner + 1))
        if comsub:
            _, j, closed = self.run(i + 2, True)
            subs = [s[i + 2:j - 1] if closed else s[i + 2:j]]   # its own check reads what the scan found
        self.memo[("a", i)] = (j, comsub, subs)
        w.subs.extend(subs)
        return j, comsub

    def nested(self, i):
        """§1.176 — a `<(…)` / `>(…)` body: `run` one nesting level deeper, counted as `dollar` is."""
        enter()
        try:
            return self.run(i, True)
        finally:
            _NEST[0] -= 1

    def dollar(self, i, w, dq=False):
        """§1.176 — every nested expansion passes here (and `nested`): one level deeper, past MAX_NEST a deny."""
        enter()
        try:
            return self._dollar(i, w, dq)
        finally:
            _NEST[0] -= 1

    def _dollar(self, i, w, dq=False):
        s, n = self.s, self.n
        p = cont(s, i + 1)                                    # §1.174: what follows the `$`, line continuations joined
        nx = s[p:p + 1]
        if dq and p > i + 1 and nx in ("'", '"'):            # `$"` / `$'` are text inside "…", joined or not
            w.buf.append("$")
            return i + 1
        if nx == "(" and s.startswith("(", cont(s, p + 1)):   # arithmetic: always a number (§1.170: its subs run;
            j, comsub = self.arith(p - 1, w)                  # §1.181: the two `(` joined first). arith reads from its
            # `$`'s index: p - 1 stands in
            w.buf.append("$" + s[p:j])
            w.live.append(("cmd" if comsub else "fixed", "$" + s[p:j]))
            return j
        if nx == "(":
            _, j, closed = self.run(p + 1, True)
            w.buf.append("$" + s[p:j])
            w.live.append(("cmd", "$" + s[p:j]))
            w.subs.append(s[p + 1:j - 1] if closed else s[p + 1:j])
            return j
        if nx == "{":
            # §1.158 (c) — a `$(…)` or backtick inside `${…}` (`${Y:-$(rm -rf /)}`) runs when the default is used: its
            # body is recorded in `subs` and checked as a command, also from a nested "…" (whose subs are merged, never
            # dropped). watch:3e520ba1e — bash (not in POSIX mode) skips a `'…'` span when it finds the `}`, inside "…" too
            # (a `"` in it, `"${line//'"'/}"`, ends nothing); inside "…" the span's quotes may be literal (a `:-` default,
            # where its `$(…)` runs: bash-confirmed), so there its substitutions are recorded as well. watch:db9ff1585 —
            # POSIX sh (dash, this box's /bin/sh, `bash --posix`) reads a `'` in a double-quoted `${…}` default as a
            # character (`"${x:-it's}"; echo AFTER` runs AFTER there, and is a syntax error in bash), so `check_text`
            # reads such a text both ways (_MODE["posix"]) and denies what either reading finds. §2.70 (r) (RULED: the
            # POSIX trim operators only) — a `'` in a `#`/`##`/`%`/`%%` PATTERN operand quotes in every shell (bash 3.2
            # and 5.2, --posix, dash, zsh 5.9), unless another operand that is no POSIX default encloses it, so its span's
            # `$(…)` never runs there; `/ // ^ ,` and the replacement operands keep the reading above. watch:64360ae8 —
            # zsh reads an UNPAIRED `'` there as a character (`"${v#it's}"; rm -rf /x/$C` runs the rm in zsh 5.9, and is a
            # syntax error in bash and dash), so the trim reading holds only for a span that closes and holds no `}` or
            # `"`; any other `'` keeps the two readings above.
            j, ctx, odd = p + 1, [], [0]                      # the open operands' classes; odd[0]: those not "pv"

            def opens(p):
                m = PE_OP_RE.match(s, p)
                ctx.append("p4" if m and m.group(2) else "pv" if m else "x")
                odd[0] += ctx[-1] != "pv"
                return m.end() if m else p

            j = opens(j)
            while j < n and ctx:
                pat = ctx[-1] == "p4" and odd[0] == 1
                if s[j] == "$" and s.startswith("\\\n", j + 1):
                    q = cont(s, j + 1)                        # §1.174: the line continuations after a `$` join first,
                    if s.startswith("(", q):                  # so what follows reads as it would with none: a `$(…)`
                        inner = Word()                        # or `$((…))` is a substitution,
                        j = self.dollar(j, inner, dq)
                        w.subs.extend(inner.subs)
                        continue
                    if s.startswith("{", q):                  # a `${` nests in THIS scan's operand context (a fresh
                        j = opens(q + 1)                      # `dollar` would read its quotes without the outer one),
                        continue
                    if s.startswith("'", q) and dq and pat:
                        _MODE["split"] = True                 # §3.52 R2: bash and POSIX sh read this `$'` apart
                    if s.startswith("'", q) and (pat or not dq) and not (dq and _MODE["posix"]):
                        k = q + 1                             # a `$'…'` is the ANSI-C string below,
                        while k < n and s[k] != "'":
                            k += 2 if s[k] == "\\" else 1
                        j = k + 1
                        continue
                    j = q                                     # and any other `$` is read as below
                    continue
                if s[j] == "\\":
                    j += 2
                    continue
                if s.startswith("$'", j) and dq and pat:
                    _MODE["split"] = True                     # §3.52 R2: bash and POSIX sh read this `$'` apart
                if s.startswith("$'", j) and (pat or not dq) and not (dq and _MODE["posix"]):
                    k = j + 2                                 # audit-w284 #11 #12 — bash reads `$'…'` unquoted or in a
                    while k < n and s[k] != "'":              # "…" trim pattern as an ANSI-C string (`\'` escapes a
                        k += 2 if s[k] == "\\" else 1         # quote); in a "…" default it does not (its `$(…)` runs)
                    j = k + 1
                    continue
                if s[j] == "'" and pat:
                    kq = s.find("'", j + 1)
                    pat = kq >= 0 and "}" not in s[j + 1:kq] and '"' not in s[j + 1:kq]   # watch:64360ae8
                if s[j] == "'" and dq and not pat:
                    _MODE["split"] = True                     # §3.52 R2: watch:db9ff1585's `'`, read apart
                if s[j] == "'" and (pat or not (dq and _MODE["posix"])):
                    k = s.find("'", j + 1)
                    k = n if k < 0 else k
                    if dq and not pat and ("$" in s[j + 1:k] or "`" in s[j + 1:k]):   # audit-w281 #12: a span that runs
                        inner, span, p = Word(), s[j + 1:k], 0
                        while p < len(span):                  # a `"` in the span ends nothing: scan past each
                            p = Lexer(span).dquote(p, inner)
                        w.subs.extend(inner.subs)
                    j = k + 1
                    continue
                if s[j] == '"':
                    inner = Word()
                    j = self.dquote(j + 1, inner)
                    w.subs.extend(inner.subs)
                    continue
                if s[j] == "`":
                    inner = Word()
                    j = self.backtick(j + 1, inner)
                    w.subs.extend(inner.subs)
                    continue
                if s.startswith("$(", j) and s.startswith("(", cont(s, j + 2)):   # arithmetic: its substitutions
                    # run (§1.170); §1.181: the two `(` joined first
                    j = self.arith(j, w)[0]
                    continue
                if s.startswith("$(", j):
                    _, k, closed = self.run(j + 2, True)
                    w.subs.append(s[j + 2:k - 1] if closed else s[j + 2:k])
                    j = k
                    continue
                if s.startswith("${", j):
                    j = opens(j + 2)
                    continue
                if s[j] == "}":
                    odd[0] -= ctx.pop() != "pv"
                j += 1
            w.buf.append("$" + s[p:j])
            w.live.append(("guarded" if GUARDED_RE.match(s, p + 1) else "var", "$" + s[p:j]))
            return j
        if nx == "'":                                         # $'…' ANSI-C quoting: text
            w.quoted = True
            j = p + 1
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            w.buf.append(s[p + 1:j])
            return j + 1
        if nx == '"':
            w.quoted = True
            return self.dquote(p + 1, w)
        m = NAME_RE.match(s, p)
        if m:
            w.buf.append("$" + m.group())
            w.live.append(("var", "$" + m.group()))
            return m.end()
        if nx and (nx.isdigit() or nx in "@*!"):
            w.buf.append("$" + nx)
            w.live.append(("var", "$" + nx))
            return p + 1
        if nx and nx in "$?#-":
            w.buf.append("$" + nx)
            w.live.append(("fixed", "$" + nx))
            return p + 1
        w.buf.append("$")
        return i + 1

    def delimiter(self, i):
        """The heredoc delimiter word at i: (its text, quotes removed in order; whether it was QUOTED; the index after
        it). §1.163 — any `'`, `"` or `\\` in the word quotes it, and a quoted delimiter's body is data: `<<E"OF"` and
        `<<E\\OF` keep it so in bash and dash alike. `\\X` is a pair (`E\\ OF` is one word). bash drops a `$` right before
        a quote (`<<$'EOF'` ends at EOF); POSIX sh keeps it (dash ends at `$EOF`), so `check_text` reads both."""
        s, n = self.s, self.n
        while i < n and (s[i] in " \t" or s.startswith("\\\n", i)):   # §6811: `<<\<newline> EOF` is `<< EOF`
            i += 2 if s[i] == "\\" else 1
        j, out, quoted, dollar = i, [], False, False
        while j < n and s[j] not in " \t\r\n;&|()<>":
            c = s[j]
            if s.startswith("\\\n", j):                    # §1.174: a line continuation joins the word (`<<E\
                j += 2                                        # newline OF` is EOF, unquoted, in bash and dash alike)
                continue
            if c == "\\":
                out.append(s[j + 1:j + 2])
                quoted, dollar, j = True, False, j + 2
                continue
            if c in "'\"":
                if dollar:
                    _MODE["split"] = True                     # §3.52 R2: §1.163's delimiter, read apart
                if dollar and not _MODE["posix"]:
                    out.pop()                                 # bash: `$'EOF'` / `$"EOF"` is EOF
                k = s.find(c, j + 1)
                k = n if k < 0 else k
                out.append(s[j + 1:k])
                quoted, dollar, j = True, False, k + 1
                continue
            out.append(c)
            dollar, j = c == "$", j + 1
        return "".join(out), quoted, j

    def bodies(self, i, heredocs, stop, toks):
        """Read each pending heredoc's body from i (the line after its `<<`), in order; return the index after the last.
        §1.163 — an UNQUOTED delimiter's body is expanded: its lines are LOGICAL (an odd run of `\\` at a line's end joins
        the next, the backslash dropped, before the delimiter test; `<<-` strips the logical line's leading tabs), and its
        substitutions go to the placeholder word. An unterminated body runs to the end of the text (bash warns and still
        expands it). A quoted delimiter's body stays data, read line by line as before — unless the heredoc's command is a
        shell reading stdin (`stdin_shell`): then the body is that shell's commands, kept in `feeds`."""
        s, n = self.s, self.n
        for delim, strip, quoted, ph, k in heredocs:
            body = []
            while i < n:
                j = s.find("\n", i)
                end = n if j < 0 else j
                line = s[i:end]
                probe = line.lstrip("\t") if strip else line
                if stop and probe.startswith(delim) and probe[len(delim):].lstrip().startswith(")"):
                    i += len(line) - len(probe) + len(delim)  # `EOF)` closes the $( on the same line
                    break
                nxt = n if j < 0 else j + 1
                while not quoted and nxt < n and (len(line) - len(line.rstrip("\\"))) % 2:
                    j = s.find("\n", nxt)                    # `x\\` + newline: the next line continues this one
                    end = n if j < 0 else j
                    line, nxt = line[:-1] + s[nxt:end], (n if j < 0 else j + 1)
                probe = line.lstrip("\t") if strip else line
                i = nxt
                if probe == delim:
                    break
                body.append(probe)
            if not quoted and body:
                ph.subs.extend(heredoc_subs("\n".join(body)))
            cs = commands(toks[k:])
            if body and cs and stdin_shell(cs[0][0]):            # the body goes to the heredoc's OWN command
                text = "\n".join(body)
                self.feeds.append((text if quoted else HD_ESC_RE.sub(r"\1", text), quoted))
        return i


def cont(s, p):
    """§1.174 — the index past any line continuations (`\\` + newline) at p: bash and dash join them before they read
    what follows, so `$\\<newline>(cmd)` is a `$(cmd)`, inside "…" too."""
    while s.startswith("\\\n", p):
        p += 2
    return p


#: §1.175 — runs of characters no branch of `Lexer.run` (or of `dquote`) treats specially: each run is ONE piece.
PLAIN_RE = re.compile(r"[^\\ \t\r\n#'\"`$;&|()<>@*+?!\[~]+")
DQ_PLAIN_RE = re.compile(r'[^"\\$`]+')
HD_SCAN_RE = re.compile(r"[\\$`]")
HD_DOLLAR_RE = re.compile(r"<<(?:\\\n)*-?(?:[ \t]|\\\n)*\$(?:\\\n)*['\"]")   # §1.163: `<<$'EOF'`, the delimiter bash and dash read apart
HD_ESC_RE = re.compile(r"\\([$`\\])")                        # §1.163: an unquoted body's `\$`, `\``, `\\` as the shell gets them


def heredoc_subs(text):
    """§1.163 — the command bodies an UNQUOTED heredoc body runs: its `$(…)` and backticks, and those inside `${…}`
    (Lexer.dollar's and backtick's own scans, read as inside "…"). A `"` or `'` in a body quotes nothing, so unlike
    `dquote` the scan never stops at one, and it keeps no text (dquote's accumulation is quadratic: 3.3 s per 1 MB,
    against the hook's 10 s). `\\` escapes the next character; a `$` before `'` or `"` is text."""
    lx, w, i, out = Lexer(text), Word(), 0, []
    while True:
        m = HD_SCAN_RE.search(text, i)
        if m is None:
            return out
        i = m.start()
        if text[i] == "\\":
            i += 2
            continue
        w.text, w.subs, w.buf = "", [], []
        if text[i] == "`":
            i = lx.backtick(i + 1, w)
        elif text[i + 1:i + 2] in ("'", '"'):
            i += 1
            continue
        else:
            i = lx.dollar(i, w, dq=True)
        out.extend(w.subs)


def kw(w):
    """B10, §2.70 (k) — a word as the shell's grammar sees it: a quoted or escaped word is never a keyword."""
    return "" if w.quoted else w.text


def commands(toks):
    """Tokens -> (the word list of each simple command, the separators just before it); a redirect's
    target is not an argument."""
    out, cur, seps, skip, red, bad = [], [], [], False, False, False
    for t in toks:
        if isinstance(t, Word):
            if skip:
                skip = False                                  # audit-w284 #20: a target that may fail (not /dev/null;
                red = red or not (t.nofail or (t.live == [("cmd", t.text)] and t.text[:2] in ("<(", ">("))) and (
                    t.live or t.text != "/dev/null")          # §6813, §1.181 (b): not a heredoc, a here-string, a whole
                    # `<(…)`/`>(…)` or a dup of fd 0-2 after `>&`/`<&` (`nofail`, set by the lexer): none can fail to open
                bad = bad or not safe_word(t)                 # #22: its expansion may abandon the list (whether or
                # not the target can fail to OPEN: §6813's `nofail` is about opening, this about expanding)
            else:
                cur.append(t)
        elif t == REDIR:
            skip = True
        else:
            if cur:
                cur[0].redir = cur[0].redir or red            # audit-w284: a redirect that fails skips the command
                cur[0].redbad = cur[0].redbad or bad
                out.append((cur, seps))
                cur, seps = [], []
            seps.append(t)
            skip = red = bad = False
    if cur:
        cur[0].redir = cur[0].redir or red
        cur[0].redbad = cur[0].redbad or bad
        out.append((cur, seps))
    return out


def joined_by(seps):
    """The operator joining a command to the one before it: None first, `;` for `;` or a newline
    (a newline straight after `&&` / `|` continues that operator). §2.70: CASE_PAT/CASE_SEP join nothing."""
    seps = [s for s in seps if s not in (CASE_PAT, CASE_SEP)]
    ops = [s for s in seps if s != ";"]
    return ops[0] if ops else (";" if seps else None)


def skip_opts(words, i, valued):
    while i < len(words):
        t = words[i].text
        if t == "--":
            return i + 1
        if not t.startswith("-") or t == "-":
            break
        i += 2 if t in valued else 1
    return i


def peel(words):
    """Drop leading assignments, keywords and wrappers: the words from the real command on."""
    i = 0
    while i < len(words):
        t = words[i].text
        if ASSIGN_RE.match(t) or t in KEYWORDS:
            i += 1
            continue
        if t == "function":                                   # §1.158 (a): `function NAME {` — the body follows
            i += 2
            continue
        if t == "coproc":                                     # §1.158 (b): `coproc [NAME] command`, NAME only
            i += 1                                            # before a compound command
            if i + 1 < len(words) and words[i + 1].text in COPROC_COMPOUND and NAME_RE.fullmatch(words[i].text):
                i += 1
            continue
        base = posixpath.basename(t)
        if base not in WRAPPERS:
            break
        if base == "command" and i + 1 < len(words) and words[i + 1].text in ("-v", "-V"):
            return []                                         # a lookup, never a run
        i = skip_opts(words, i + 1, WRAPPERS[base])
        if base == "timeout":
            i += 1                                            # the DURATION
    return words[i:]


def docker_exec(base, args):
    """`docker [opts] exec|run [opts] C|IMAGE cmd…`, `docker [opts] compose [opts] exec|run [opts]
    SVC cmd…`, `docker-compose …`: the inner command's words, or None. The first non-option word
    is the subcommand — `docker rm` is not exec, and `docker run --rm img` runs no command."""
    i = 0
    if base == "docker":
        i = skip_opts(args, 0, DOCKER_VALUED)
        if i < len(args) and args[i].text == "compose":
            base, i = "docker-compose", i + 1
    if base == "docker-compose":
        i = skip_opts(args, i, COMPOSE_VALUED)
    if i >= len(args) or args[i].text not in ("exec", "run"):
        return None
    i = skip_opts(args, i + 1, EXEC_VALUED if args[i].text == "exec" else RUN_VALUED)
    return args[i + 1:]


def _shell_opts(args, glued=False):
    """A shell's options: (an option cluster holds c, one holds s, the index of the first operand). §1.173 — an `o` or
    `O` in a short cluster takes a VALUE word, and the shells read it two ways (probed under run_contained, 2026-10-07):
    bash (3.2, 5.2, --posix), dash and busybox sh take the next word for EACH `o` (and bash for each `O`; dash and busybox
    reject `-O`, so counting it errs deny-side), wherever it stands in the cluster (`-euo pipefail -c S`,
    `-oc pipefail S`); zsh, ksh and mksh (`glued`) take the rest of the cluster after the first `o` as its value
    (`-opipefail -c S`), and the next word only when that `o` ends the cluster."""
    has_c, has_s, i = False, False, 0
    while i < len(args):
        t = args[i].text
        if t in ("--rcfile", "--init-file"):
            i += 2
            continue
        if t == "--":
            i += 1
            break
        if t.startswith("--"):
            i += 1
            continue
        if len(t) > 1 and t[0] in "-+":
            flags, take = t[1:], 0
            if glued:
                k = flags.find("o")
                if k >= 0:
                    flags, take = flags[:k], int(k == len(flags) - 1)
            else:
                take = flags.count("o") + flags.count("O")
            has_c = has_c or (t[0] == "-" and "c" in flags)
            has_s = has_s or (t[0] == "-" and "s" in flags)
            i += 1 + take
            continue
        break
    return has_c, has_s, i


def shell_strings(args):
    """The command-string WORDS of `bash -c STRING` (any option cluster holding c) under both of `_shell_opts`'
    readings, each once: one word where the shells agree, two where they do not (§1.173: both are checked, the deny
    side); none without -c."""
    out = []
    for glued in (False, True):
        has_c, _, i = _shell_opts(args, glued)
        if has_c and i < len(args) and all(w is not args[i] for w in out):
            out.append(args[i])
    return out


def stdin_shell(words):
    """§1.163 — whether this command is a shell that runs its STDIN as commands: no -c, and -s, no operand or the
    operand `-` (`sh -`); past `peel`'s wrappers, `runuser -u` / `flock FILE cmd…`, and `docker … exec|run` (its shell
    reads the same stdin; without -i it gets none, read anyway: the deny side). `bash FILE` runs the file instead."""
    head = peel(words)
    while head:
        base, args = posixpath.basename(head[0].text), head[1:]
        if base in ("docker", "docker-compose"):
            head = peel(docker_exec(base, args) or [])
            continue
        run = wrapped(base, args)
        if run is not None:
            head = peel(run[1]) if run[0] == "cmd" else []
            continue
        if base not in SHELLS:
            return False
        return any(not has_c and (has_s or i >= len(args) or args[i].text == "-")   # §1.173: either reading
                   for has_c, has_s, i in (_shell_opts(args, glued) for glued in (False, True)))
    return False


def su_string(args):
    """The command-string WORD of `su [opts] [-] [user] -c STRING` (`--command STRING`,
    `--command=STRING`, `--session-command[=]STRING`, a short cluster ending in c: `-lc`), else None
    — `su` alone runs no command. `runuser` without -u takes the same forms."""
    for k, a in enumerate(args):
        t = a.text
        for opt in ("--command=", "--session-command="):
            if t.startswith(opt):
                w = Word(t[len(opt):])
                w.live, w.subs = a.live, a.subs
                return w
        if t in ("--command", "--session-command") or (len(t) > 1 and t[0] == "-" and t[1] != "-"
                                                        and t.endswith("c")):
            return args[k + 1] if k + 1 < len(args) else None
    return None


def show(t):
    t = "".join(ch if " " <= ch and ch != "\x7f" else "?" for ch in t)
    t = t.encode("utf-8", "replace").decode("utf-8")             # a lone surrogate cannot be printed: keep the deny
    return t if len(t) <= 120 else t[:117] + "..."


FIX = ("Write `${VAR:?}` so an empty variable aborts the command instead of deleting the parent, "
       "or a literal path.")
CD_FIX = ("Chain it so a failed cd stops the delete (`cd DIR && rm -f -- ./*`, or `cd DIR || exit` first), or name the "
          "directory in the operand: `${VAR:?}/*` or an absolute literal path.")
CD_TREE_FIX = ("Chain it so a failed cd stops the delete (`cd DIR && rm -rf -- build`, or `cd DIR || exit` first), or name "
               "the directory in the path: `${VAR:?}/build` or an absolute literal path.")


def ref_name(shown):
    m = BIND_REF_RE.fullmatch(shown)
    return m and (m.group(1) or m.group(2))


def resolve(a, env):
    """(`a` with each `$NAME` / `${NAME}` bound in `env` replaced by its literal, the names used). `a`
    itself when nothing is bound, or when a quoted or escaped lookalike (`'$B'`, `\\$B`) in the text
    would make the substitution land on the wrong one."""
    used = [s for kind, s in a.live if kind == "var" and ref_name(s) in env]
    seen = [m.group() for m in BIND_REF_RE.finditer(a.text) if (m.group(1) or m.group(2)) in env]
    if not used or sorted(used) != sorted(seen):
        return a, ()
    b = Word(BIND_REF_RE.sub(lambda m: env.get(m.group(1) or m.group(2), m.group()), a.text))
    if "{" in b.text:                                         # brace expansion runs FIRST: `/repo/{$C,}` is `/repo/` too
        return a, ()
    b.live = [(kind, s) for kind, s in a.live if not (kind == "var" and ref_name(s) in env)]
    b.subs, b.tilde = a.subs, a.tilde
    return b, sorted(set(ref_name(s) for s in used))


def is_root(p, tilde):
    return (p in PROTECTED or HOME_RE.fullmatch(p) is not None or (tilde and TILDE_RE.fullmatch(p) is not None)
            or set(p.split("/")) == {".."})                   # `..`, `../..`, …


def operand_verdict(a, what, env, roots=True, named=False):
    b, used = resolve(a, env)
    if b.live and b.live[0][0] == "guarded" and b.text.startswith(b.live[0][1]) and PWD_RE.match(b.live[0][1]):
        # §1.164 — a leading `${PWD:?…}` is the current folder itself: `"${PWD:?}"` and `"${PWD:?}"/*` are `.` and `*`
        c = Word("." + b.text[len(b.live[0][1]):])
        c.live, c.subs, c.tilde = b.live[1:], b.subs, b.tilde
        b = c
    for kind, shown in b.live:
        if kind in ("var", "cmd"):
            return ("eugo-deletion-guard: blocked %s — its operand `%s` expands `%s` with no guard, so an empty "
                    "or unset value deletes the parent instead (how `rm -rf /repo/$C` wiped the checkout on "
                    "2026-09-23). %s" % (what, show(a.text), show(shown), FIX))
    if b.live or not b.text:
        return None                                           # guarded / never-empty: not a static path
    p = posixpath.normpath(re.sub(r"/+", "/", b.text))
    # A NAMED find may start at `.` or another RELATIVE path, never at an absolute one or a home
    # (operator ruling 2026-09-24): `find ~ -name .git -exec rm -rf {} +` deletes every repo's .git.
    if named and not p.startswith("/") and not b.tilde:
        return None
    if a.every:
        # B10, root option B (RULED 2026-10-05) — a match-all or `!(…)` group reads as `*`: `/!(keep)`, `~/!(keep)` and
        # `?(*)` are roots; a bare `!(keep)` in the current folder is not. Parity: a `*(…)` keeps HEAD's reading of its
        # leading `*`, so `*(*)`, `/*(*)` and `~/*(*)` stay the roots they were.
        t = b.text
        for seg, op in a.every:
            t = t.replace(seg, "*")
        q = posixpath.normpath(re.sub(r"/+", "/", re.sub(r"\*+", "*", t)))
        for seg, op in a.every:
            if op == "*" and seg in b.text:
                r = posixpath.normpath(re.sub(r"/+", "/", b.text.split(seg)[0] + "*"))
                if is_root(r, b.tilde) or (r.endswith(("/*", "/.*")) and is_root(r.rsplit("/", 1)[0] or "/", b.tilde)):
                    q = r
        if not (q in ("*", ".*") and all(op == "!" for _, op in a.every)):
            if is_root(q, b.tilde) or (q.endswith(("/*", "/.*")) and is_root(q.rsplit("/", 1)[0] or "/", b.tilde)):
                p = q
    if roots and (is_root(p, b.tilde) or (p.endswith(("/*", "/.*")) and is_root(p.rsplit("/", 1)[0] or "/", b.tilde))):
        bound = "".join(" (`%s=%s` earlier in this command)" % (n, show(env[n])) for n in used)
        return ("eugo-deletion-guard: blocked %s of `%s`%s — it resolves to `%s`, a protected root (the "
                "filesystem root, a home, /repo, a whole /opt/eugo checkout or a cloud checkout under /home/user, or "
                "the current/parent directory). Name the literal path below it that you mean (`./build`, `find ./tools …`). %s"
                % (what, show(a.text), bound, show(p), FIX))
    return None


def split_rm(args):
    """An rm's (recursive?, operand words)."""
    recursive, operands, done = False, [], False
    for a in args:
        t = a.text
        if done or not t.startswith("-") or t == "-":
            operands.append(a)
        elif t == "--":
            done = True
        elif t.startswith("--"):
            recursive = recursive or "recursive".startswith(t[2:].split("=", 1)[0])   # GNU takes any unambiguous prefix
        elif "r" in t or "R" in t:
            recursive = True
    return recursive, operands


def check_rm(args, env):
    recursive, operands = split_rm(args)
    if not recursive:
        return None                                           # one file at most: never a parent tree
    for a in operands:
        r = operand_verdict(a, "a recursive rm", env)
        if r:
            return r
    return None


def cwd_rel(a):
    """§2.68 — a path bash resolves against the CURRENT directory: non-empty, starting with neither /, ~ nor an
    expansion (`"${X:?}"/build` names its own directory). §2.70 (n): except `~+`, `$PWD` and `${PWD…}`, which ARE the
    current directory — the one a failed cd left. §2.70 (p): so is a leading `$(pwd)` or `` `pwd` ``."""
    if a.tilde and (a.text == "~+" or a.text.startswith("~+/")):
        return True
    if a.live and a.text.startswith(a.live[0][1]) and (PWD_RE.match(a.live[0][1]) or (
            a.live[0][0] == "cmd" and PWD_CMD_RE.fullmatch(a.live[0][1]))):
        return True
    return bool(a.text) and not a.tilde and not a.text.startswith("/") and not (
        a.live and a.text.startswith(a.live[0][1]))


def cwd_glob(a):
    """§2.53 — a glob bash matches in the CURRENT directory: an unquoted *, ? or [ in a `cwd_rel` word."""
    return a.glob and cwd_rel(a)


def exec_deletes(words):
    """§1.164 — whether the command an `-exec` runs deletes: `rm` past `peel`'s wrappers (`sudo rm`, `env -i rm`), or a
    shell `-c` string holding an rm (`sh -c 'rm -rf "$1"' _ {}`). Only the MAIN rule asks (`find_parts(…, wide=True)`):
    the cd rule keeps a literal `rm`, as §2.70 (m) stays filed (RULED §6300)."""
    head = peel(words)
    if not head:
        return False
    base = posixpath.basename(head[0].text)
    if base == "rm":
        return True
    for inner in (shell_strings(head[1:]) if base in SHELLS else []):
        for ws, _ in commands(Lexer(inner.text).run(0, False)[0]):
            h = peel(ws)
            if h and posixpath.basename(h[0].text) == "rm":
                return True
    return False


def find_parts(args, wide=False):
    """A find's (starting points, expression words, the indices of its deleting actions in them). `wide` (the main
    rule, §1.164): an `-exec` whose command `exec_deletes`, up to its `;` or `{} +`."""
    i = 0
    while i < len(args):
        t = args[i].text
        if t in ("-H", "-L", "-P") or (t.startswith("-O") and len(t) > 2):
            i += 1
        elif t == "-D":
            i += 2
        else:
            break
    starts = []
    while i < len(args) and not args[i].text.startswith("-") and args[i].text not in ("(", "!", ")", ","):
        starts.append(args[i])
        i += 1
    words = args[i:]
    expr = [a.text for a in words]
    acts = [k for k, t in enumerate(expr) if t == "-delete" or (
        t in EXEC_ACTIONS and k + 1 < len(expr) and posixpath.basename(expr[k + 1]) == "rm")]
    if wide:
        for k, t in enumerate(expr):
            if t in EXEC_ACTIONS and k not in acts:
                e = next((j for j in range(k + 1, len(expr)) if expr[j] == ";" or (expr[j] == "+" and expr[j - 1] == "{}")),
                         len(expr))
                if exec_deletes(words[k + 1:e]):
                    acts.append(k)
        acts.sort()
    return starts, words, acts


def check_find(args, env):
    starts, words, acts = find_parts(args, wide=True)
    expr = [a.text for a in words]
    if not acts:
        return None
    # Only NAMED entries reach the delete: a positive name test before it, with a literal pattern that
    # names something, and no -o / `,` / parentheses that could route anything else to it.
    named = not any(t in ("-o", "-or", ",", "(", ")") for t in expr) and any(
        t in NAME_TESTS and k + 1 < acts[0] and not words[k + 1].live and re.search(r"[A-Za-z0-9]", expr[k + 1])
        and not (k and expr[k - 1] in ("!", "-not")) for k, t in enumerate(expr))
    for a in starts or [Word(".")]:                           # no starting point = `.`
        r = operand_verdict(a, "a find that deletes", env, named=named)
        if r:
            return r
    return None


def wrapped(base, args):
    """§1.103 L1 / §1.109 (b), shared by the cd rule since §2.70 (c) — what `runuser` or `flock` runs: ("cmd", words)
    for `runuser -u USER [--] cmd…` and `flock FILE cmd…`, ("text", the STRING word or None) for `flock FILE -c STRING`,
    ("su", None) for su-style `runuser [-] USER -c STRING`; None for any other base."""
    if base == "runuser":
        rest = args[skip_opts(args, 0, RUNUSER_VALUED):]
        opts = args[:len(args) - len(rest)]
        if any(w.text in ("-u", "--user") or w.text.startswith("--user=") or
               (w.text.startswith("-u") and not w.text.startswith("--")) for w in opts):
            return ("cmd", rest)
        return ("su", None)
    if base == "flock":
        rest = args[skip_opts(args, 0, FLOCK_VALUED) + 1:]    # past the lock FILE (or fd: no command)
        if rest and rest[0].text in ("-c", "--command"):
            return ("text", rest[1] if len(rest) > 1 else None)
        return ("cmd", rest)
    return None


def run_head(words):
    """§2.70 (c) — the words of the command the cd rule judges: `peel`, then through `runuser -u … cmd…` and `flock FILE
    cmd…`, which run it in this directory. A -c string is an inner shell (none); `docker … exec` is never entered: a cd
    on the host does not reach the container."""
    head = peel(words)
    while head:
        run = wrapped(posixpath.basename(head[0].text), head[1:])
        if run is None:
            break
        head = peel(run[1]) if run[0] == "cmd" else []
    return head


def check_command(words, env):
    """§1.176 — one nesting level: `docker exec … docker exec …` and `runuser -u U -- runuser …` recurse here."""
    enter()
    try:
        return _check_command(words, env)
    finally:
        _NEST[0] -= 1


def _check_command(words, env):
    words = peel(words)
    if not words:
        return None
    base = posixpath.basename(words[0].text)
    args = words[1:]
    if base in SHELLS:
        for inner in shell_strings(args):                     # a string the OUTER shell expands binds nothing
            r = check_text(inner.text, not inner.live)
            if r:
                return r
        return None
    if base in ("docker", "docker-compose"):
        inner = docker_exec(base, args)
        return check_command(inner, env) if inner else None
    run = wrapped(base, args)
    if run is not None and run[0] == "cmd":
        return check_command(run[1], env) if run[1] else None   # `runuser -u USER [--] cmd…`, `flock FILE cmd…`
    if run is not None and run[0] == "text":                  # `flock FILE -c STRING`
        return check_text(run[1].text, not run[1].live) if run[1] is not None else None
    if run is not None:
        base = "su"                                           # `runuser [-] USER -c STRING`: su's form
    if base == "su":
        inner = su_string(args)
        return check_text(inner.text, not inner.live) if inner is not None else None
    if base == "watch":
        rest = args[skip_opts(args, 0, WATCH_VALUED):]
        return check_text(" ".join(w.text for w in rest), False) if rest else None
    if base == "rm":
        return check_rm(args, env)
    if base == "find":
        return check_find(args, env)
    return None


class CdWatch(object):
    """§2.53 — one shell level's last cd/pushd whose failure may not have stopped the command: `cd` as shown
    (None: none, or `|| exit` proved it ran); `ok` — this point is reached only if it succeeded; `base` — the
    ok this level was entered with (a `;` falls back to it, so `cd X && (make; rm -f *)` stays guarded).
    §2.69 — `body`: None, or the nesting depth inside a then/do/`{` body entered while `ok` (every command in
    it runs only if the cd succeeded); `group`: inside the `{` of a `cd X || {` branch, watching for its exit."""
    __slots__ = ("cd", "ok", "base", "after_cd", "body", "group", "keep", "frames", "span", "seen", "bgcd", "snaps",
                 "grec", "folded", "negrec", "cdn", "lastcd")

    def __init__(self, parent=None, span=False):
        self.cd = parent.cd if parent else None
        self.ok = self.base = parent.ok if parent else False
        self.after_cd = False
        self.body, self.group = None, False
        # §2.71 — `keep`: the body is a whole compound entered while ok, so its end restores ok (an `&&` chain runs on
        # through it); `frames`: the compounds open at this level (the opener, or "func" for a function's `{`), a child
        # level starting empty, so `continue`/`break`/`return` know what they would end and a `do` knows its loop.
        self.keep, self.frames = False, []
        # §2.71 (c) (ruled 2026-10-05) — `span`: a level `subshell_spans` opened (a background job, a pipeline element, a
        # coproc), which never passes its cd to its parent; `seen`: the last cd recorded ON this level; `bgcd`: a cd that
        # ran in such a span before this point (inherited: a subshell starts in its parent's directory). A span keeps
        # only the function flag: bash runs `return` there (it ends the subshell), and a subshell has no loop.
        self.span, self.seen = span, None
        self.bgcd = parent.bgcd if parent else None
        if span and parent and any(f.rstrip("|") == "func" for f in parent.frames):
            self.frames = ["func"]
        # B9 (run 1255) — `snaps`: one record per open frame, pushed and popped with it ({kind, skip, alt, done, else}:
        # the state if the compound never runs, if this branch does not, each ended branch, an else seen); `grec`: the
        # record of the `{` of a `cd X || {` group, which closes exactly when that record is popped.
        self.snaps, self.grec = [None] * len(self.frames), None
        self.folded = parent.folded if parent else False    # B9: the cd came back from a path that skipped its proof
        self.negrec = None                                  # B11: an `if ! cd X` record waiting for its `then`
        # audit-w286 #19 — `cdn`: the cds this level has made, `lastcd`: the latest. A record keeps the count it opened
        # at (`cdn0`), so its closer knows whether a cd ran inside it and which was last, at no cost per open record.
        self.cdn, self.lastcd = 0, None


OPENERS = ("if", "while", "until", "for", "select", "case", "{")
CLOSERS = ("fi", "done", "esac", "}")
PIPE_BG = ("|", "|&", "&")                                  # audit-w276 #1: an exit joined so runs in a subshell
LOOPS = ("while", "until", "for", "select")
SCOPED = ("continue", "break", "return")


def scoped(st, base):
    """§2.71 (d) — whether `continue`/`break`/`return` stops this level's command list here: `return` needs a function
    frame, `continue`/`break` a loop as the innermost loop-or-function frame (a function defined in a loop is not it)."""
    if base == "return":
        return any(f.rstrip("|") == "func" for f in st.frames)
    for f in reversed(st.frames):
        kind = f.rstrip("|")
        if kind in LOOPS or kind == "func":
            return kind in LOOPS
        if f.endswith("|"):
            # watch:c41ccd2d — a compound between it and the loop is piped or backgrounded, so it runs in a subshell,
            # and bash >= 5.0 gives a subshell no loop: `continue` prints an error and the rm after it runs.
            return False
    return False


def piped_openers(cmds, bb=()):
    """watch:c41ccd2d — {(command index, word index)} of every opener whose compound is a pipeline element or
    backgrounded (`… | {`, `} | …`, `} &`), so it runs in a subshell. The same leading-word walk as `cd_verdict`'s
    frames, one stack per subshell level; a closer takes the command's join only when it is the last closer of the
    command's leading words (`} done | cat` pipes the loop, not the group)."""
    out, stacks = set(), [[]]
    for k, (words, seps) in enumerate(cmds):
        ops = []
        for s in seps:
            if s in (CASE_PAT, CASE_SEP):
                continue
            if s in ("(", ")"):
                ops = []
                if s == "(":
                    stacks.append([])
                elif len(stacks) > 1:
                    stacks.pop()
            else:
                ops.append(s)
        if CASE_PAT in seps:
            continue
        before = joined_by(ops) if ops else None
        after = joined_by(cmds[k + 1][1]) if k + 1 < len(cmds) else None
        run = [j for kind, j, _ in lead_words(words, brace=k in bb)[0] if kind in ("open", "func", "close")]   # B8
        last_closer = max([j for j in run if words[j].text in CLOSERS] or [-1])
        for j in run:
            if words[j].text in OPENERS:
                stacks[-1].append((k, j))
                if before in ("|", "|&"):
                    out.add((k, j))
            elif stacks[-1]:
                opener = stacks[-1].pop()
                if j == last_closer and after in PIPE_BG:
                    out.add(opener)
    return out


def brace_bodies(cmds):
    """run 1255 B8 (b), §2.70 (f) — the indices of the commands whose first word `{` is the BODY of the `for`/`select`
    before it (`for f in a; { …; }`, `for ((…)) { …; }`): a header (a command whose leading words end at a `for` or
    `select`) arms its paren depth, and the next command at that depth is its body when only `;`/newlines stand between
    and its first word is `{`. Any other command there, an `&&`/`||`/`|`/`&` or a case arm at that depth, disarms it;
    `for ((…))` lexes as two subshell levels, so the depth is tracked per `(`/`)`."""
    out, armed, depth = set(), set(), 0
    for k, (words, seps) in enumerate(cmds):
        for sp in seps:
            if sp == "(":
                depth += 1
            elif sp == ")":
                armed.discard(depth)
                depth -= 1
            elif sp != ";" and sp != CASE_PAT:
                armed.discard(depth)                          # `&&`, `||`, `|`, `&`, a case arm's `)`
        if depth in armed and words and kw(words[0]) == "{":
            out.add(k)
        armed.discard(depth)
        lw = lead_words(words, brace=k in out)[0]
        if lw and lw[-1][0] == "open" and words[lw[-1][1]].text in ("for", "select"):
            armed.add(depth)
    return out


def lead_words(words, fn=False, brace=False, text=False):
    """§2.71 (c) + run 1255 B8 — a command's leading reserved words, read ONE way by every walker (`cd_verdict`'s `lead`,
    its frames and body walks, `subshell_spans`, `piped_openers`): [(kind, index, start)] in order — "open" for an opener,
    "func" for a function's `{` (after `function NAME`, or first when `fn`: `f() {`), "close" for a closer, "co" for a
    `coproc` (it applies to the next element), "kw" for `function`, `!` and every other keyword — and where the simple
    command after them starts, or None. Stepped over, never listed: `time`, its `-p` and `--` (bash's TIMEIGN), a
    function's NAME, a coproc's NAME (`co_name`). An opener's element STARTS at the pipeline prefixes right before it
    (`!`, `time [-p] [--]`, `coproc [NAME]`): they are the element's, so a span cut there keeps `! cd X` negated. With
    `brace` (`brace_bodies`), a first `{` is a `for`/`select` body and reads as "kw", like `do`: it pushes no frame, its
    `}` ends the loop, and it opens no element. B10: a quoted word is no keyword (`kw`); `text` reads it as plain text, the
    reading `cd_verdict`'s proof gates keep (a quoted `"!"` there only adds denies)."""
    rd = (lambda w: w.text) if text else kw
    out, j, pfx, fbrace = [], 0, None, -1
    while j < len(words):
        t = rd(words[j])
        if brace and j == 0 and t == "{":
            out.append(("kw", j, None))
            pfx = None
        elif t in OPENERS:
            out.append(("func" if t == "{" and ((fn and j == 0) or j == fbrace) else "open", j, j if pfx is None else pfx))
            pfx = None
        elif t in CLOSERS:
            out.append(("close", j, None))
            pfx = None
        elif t == "function":
            out.append(("kw", j, None))
            j, fbrace, pfx = j + 2, j + 2, None
            continue
        elif t == "coproc":
            out.append(("co", j, None))
            pfx = j if pfx is None else pfx
            if co_name(words, j + 1):                       # §2.70 (o): `coproc until …` names no coproc
                j += 1
        elif t == "!":
            out.append(("kw", j, None))
            pfx = j if pfx is None else pfx
        elif t == "time" or (j and ((t == "-p" and rd(words[j - 1]) == "time")
                                    or (t == "--" and rd(words[j - 1]) in ("time", "-p")))):
            pfx = j if pfx is None else pfx
        elif t in KEYWORDS:
            out.append(("kw", j, None))
            pfx = None
        else:
            break
        j += 1
    return out, ((j if pfx is None else pfx) if j < len(words) else None)


def subshell_spans(cmds, bb=()):
    """§2.71 (c) (ruled 2026-10-05) — where bash runs commands in a subshell of their own: a backgrounded and-or list
    (`&` ends it; `cd X && foo &` backgrounds the whole list), EACH element of a pipeline of two or more (`|` binds
    tighter than `&&`/`||`, so `cd X && a | b` keeps the cd in this shell), and a coproc's command. An element is a
    simple command, a whole compound (opener to closer) or a `( … )`. Returns {(command, sep index, word index):
    [closes, opens]}: `(k, i, 0)` is before `seps[i]`, `(k, len(seps), j)` before word j (an element can start inside a
    command, after the reserved words of an enclosing compound), and `(k + 1, 0, 0)` after the command."""
    end = (len(cmds), 0, 0)
    spans = set()
    stack = [[[], None, None]]                                # [elements, pending join, the element it is the body of]

    def finish(ctr, term):
        elems, ctr[0], ctr[1] = ctr[0], [], None
        if not elems:
            return
        if term == "&":
            spans.add((elems[0]["start"], elems[-1]["end"] or end))
        run = []
        for e in elems + [None]:
            if e is not None and run and e["join"] in ("|", "|&"):
                run.append(e)
                continue
            if len(run) > 1:
                spans.update((x["start"], x["end"] or end) for x in run)
            run = [e] if e is not None else []
        spans.update((e["start"], e["end"] or end) for e in elems if e["co"])

    def connect(op):
        if op in ("&&", "||", "|", "|&"):
            stack[-1][1] = op
        else:
            finish(stack[-1], op)                             # `;`, a newline or `&` ends the list

    def start(pos, co, sub):
        e = {"start": pos, "end": None, "join": stack[-1][1], "co": co, "sub": sub}
        stack[-1][1] = None
        stack[-1][0].append(e)
        return e

    def close(pos, sub, inner=None):
        while len(stack) > 1 and (sub or not stack[-1][2]["sub"]):
            ctr = stack.pop()
            finish(ctr, None)
            ctr[2]["end"] = pos if ctr[2]["sub"] or inner is None else inner   # audit-w281 #15: before the `)`
            if ctr[2]["sub"] == sub:
                return

    for k, (words, seps) in enumerate(cmds):
        ops = []
        for i, s in enumerate(seps):
            if s == CASE_PAT:
                continue
            if s == CASE_SEP:                                 # an arm's body starts a list of its own
                ops = []
                finish(stack[-1], None)
            elif s == "(":
                if ops:
                    connect(joined_by(ops))
                    ops = []
                stack.append([[], None, start((k, i, 0), False, True)])
            elif s == ")":
                if ops:
                    connect(joined_by(ops))
                    ops = []
                close((k, i + 1, 0), True, (k, i, 0))
            else:
                ops.append(s)
        if ops:
            connect(joined_by(ops))
        if CASE_PAT in seps:
            continue                                          # a case pattern is data
        co = False
        lead, rest = lead_words(words, brace=k in bb)
        for kind, j, at in lead:
            if kind == "co":
                co = True
            elif kind == "close":
                # audit-w281 #14: a closer ends its compound right after its own word, not after the whole command
                close((k, len(seps), j + 1) if j + 1 < len(words) else (k + 1, 0, 0), False)
            elif kind in ("open", "func"):
                stack.append([[], None, start((k, len(seps), at), co, False)])
                co = False
        if rest is not None:
            start((k, len(seps), rest), co, False)["end"] = (k + 1, 0, 0)
    while len(stack) > 1:
        close(end, True)
    finish(stack[0], None)
    marks = {}
    for a, b in spans:
        if a < b:
            marks.setdefault(a, [0, 0])[1] += 1
            marks.setdefault(b, [0, 0])[0] += 1
    return marks


def push(levels, span=False):
    """Open a subshell or span level. watch:f4209728 — a command run there is one the parent never sees, so the parent's
    `if ! cd X` record stops waiting for its `then`: `if ! cd X; (false); then exit; fi` skips the then-branch."""
    levels[-1].negrec = None
    levels.append(CdWatch(levels[-1], span=span))


def pop_span(levels):
    """§2.71 (c) — leave a span: a cd recorded on it (or one it inherited from a span inside it) marks the parent, which
    it never moved; an explicit `( … )` inside the span marks nothing (`(cd X) & rm -f *.o` stays allowed, ruled)."""
    while len(levels) > 1 and levels[-1].span:                # audit-w281 #15: never past a non-span level
        child = levels.pop()
        if child.span:
            mark = child.seen or child.bgcd
            if mark:
                levels[-1].bgcd = mark
            levels[-1].after_cd = False
            return


def snap(st, ok=None):
    """B9 (h)(q) — the state a path leaves here: (cd, bgcd, ok, base); inside a body every path has the cd proven."""
    if st.body is not None:
        return (None, None, False, st.base)
    return (st.cd, st.bgcd, st.ok if ok is None else ok, st.base)


def fold(paths):
    """B9 (h)(q) — the deny-side union of the paths that reach a closer: the first unproven cd wins (starting from the
    live state, so a fold never clears one), a background cd is kept, and ok/base hold only if they hold on every path."""
    out = paths[0]
    for k in paths[1:]:
        if (out[0], out[1]) == (k[0], k[1]):
            continue
        if out[0] is None and out[1] is None:
            out = k
        elif k[0] is not None or k[1] is not None:
            out = (out[0] if out[0] is not None else k[0], out[1] or k[1], out[2] and k[2], out[3] and k[3])
    return out


def plain_to(st, rec):
    """B9 (i), §2.71 (b) — whether only plain, unpiped `{` groups are open above the record `rec`: an exit there is the
    group's own, whatever compounds ran (and closed) before it. False when `rec` is not open on this level."""
    if rec is None:
        return False
    for i in range(len(st.snaps) - 1, -1, -1):
        if st.snaps[i] is rec:
            return all(f == "{" for f in st.frames[i + 1:])
    return False


def leaves(st, base, args):
    """watch:68cb2fda — whether a `break`/`continue` (`return`) here leaves every loop (function) opened inside the
    watched `|| {` group, so the group's own exit never runs: `cd "$d" || { if c; then continue; fi; exit 1; }`."""
    i = next((i for i in range(len(st.snaps) - 1, -1, -1) if st.snaps[i] is st.grec), None)
    if i is None:
        return True
    inner = [f.rstrip("|") for f in st.frames[i + 1:]]
    if base == "return":
        return "func" not in inner
    return sum(f in LOOPS for f in inner) < jump_count(base, args)


def jump_count(base, args):
    """How many loops a `break N`/`continue N` leaves (1 without a count; `return` leaves its function). §6809 (the review
    watch on 3bab30a8d) — an ASCII count only: `str.isdigit` accepts `²`, which `int` refuses, and the checker crashed
    (FAILS OPEN) on `break ²`. bash and dash end a non-interactive shell on a count that is not a number (bash rc 128,
    dash rc 2); reading it as 1 keeps the jump on the deny side. The turn-end review of that cure: `int` also refuses
    more than 4,300 digits (Python 3.11+), so the count is read without it past nine significant digits, as more loops
    than any text nests (both shells end on an overflowing count; a larger count only adds escapes). `0002` is 2.
    §6812 (audit-w286): a count that is an expansion (`break $n`) is read the same way, as every loop, and `jump_rec`
    gives the jump to each of them, since `$n` may be any (§6817)."""
    if args and base != "return" and args[0].live:        # §6812: `break $n` may leave any number of loops
        return 10 ** 9
    t = args[0].text if args and base != "return" else ""
    t = t.lstrip("0") if t.isascii() and t.isdigit() else ""
    return int(t) if 0 < len(t) <= 9 else 10 ** 9 if t else 1


def jump_rec(st, base, args):
    """§2.70 (u) — the records of the compounds a `break`/`continue` (N: its N-th enclosing loop) or a `return` (its
    function) may leave on this level ([] for none): the state where the jump runs reaches each one's closer as one more
    path of its fold, so a later `cd C || exit` in the same body no longer hides an earlier unproven cd. §6817 (the
    review watch on 3d91c2252) — a count that is an expansion may be any number, so the jump reaches EVERY loop on this
    level; §6812 gave it the outermost alone, and an inner loop's closer lost the unproven cd (allow side)."""
    if not scoped(st, base):
        return []
    n = jump_count(base, args)
    every = base != "return" and bool(args) and args[0].live
    hits = []
    for f, r in zip(reversed(st.frames), reversed(st.snaps)):
        k = f.rstrip("|")
        if base == "return":
            if k == "func":
                return [r] if r is not None else []
        elif k == "func":
            break                                           # a loop outside the function is not its to leave
        elif k in LOOPS:
            hits, n = hits + [r] if every else [r], n - 1
            if not n:
                break
    return [r for r in hits if r is not None]               # a level's inherited frames carry no record (None)


def shell_runs(pre):
    """§2.70 (s), audit-w284 — whether the shell itself runs the command after these prefix words. `builtin` and
    `command` (bare, never a path) keep it in the shell; `time` is the shell's keyword only bare, unquoted, and before
    any assignment, `!`, `builtin` or `command` (`X=1 time exit`, `command time exit`, `/usr/bin/time exit` run the
    program); every other wrapper, and `flock`/`runuser`, runs a program of its own."""
    timeok = True
    for w in pre:
        t = w.text
        b = posixpath.basename(t)
        if ASSIGN_RE.match(t) or t == "!":
            timeok = False
        elif b == "time":
            if t != "time" or w.quoted or not timeok:
                return False
        elif b in ("builtin", "command"):
            if t != b:
                return False
            timeok = False
        elif b in WRAPPERS or b in ("flock", "runuser"):
            return False
    return True


def unproven(st):
    """Why nothing stops a delete after `st.cd` when that cd fails, for the deny reason (§2.70 (h): a fold's cd)."""
    if st.folded == "redir":
        return ("a redirect on the compound around it may fail, and then neither the cd nor its proof runs, §2.70 (x)")
    if st.folded:
        return ("the `|| exit` that would prove it sits in a body that may be skipped or a function that may never run, "
                "§2.70 (h)")
    return "it is not in the cd's `&&` chain"


def cd_join(st, op):
    if op not in (None, "&&", "|", "|&") and st.body is None:
        st.ok = st.base


def resolved(a, env):
    """audit-w279 #21 — `a` with a literal bound earlier in this command substituted (`resolve`), keeping its bare-glob
    flag: the cd rule reads the path bash will use, as the primary rule does."""
    b = resolve(a, env or {})[0]
    if b is not a:
        b.glob = a.glob
    return b



# audit-w284 #22 (STRUCTURAL cure, research) — B11a proves the cd only when nothing before its exit can fail WITHOUT
# ending the shell. bash discards the whole top-level list on an expansion error (bad substitution, `$((…))`, `$[…]`,
# `${x:o:-n}`, `${!ref}`, a failglob no-match, a nameref'd `$d`, a bad redirect target) and on a readonly bare
# assignment, then runs the NEXT line; a called function's body does the same to its caller (measured). Only the
# forms below were measured never to do that: a plain `$name`/`${name}`/special parameter (an unset one under
# `set -u` EXITS), `${#name}`, `${name OP literal}` for the default/alternate/trim/`?` operators (bash 5.2 + 3.2), a
# `$(…)`/backtick substitution (its errors stay in the child), literal text, and these builtins failing on their own.
_P = r"(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+)"
SAFE_EXP_RE = re.compile(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])|\$\{(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])\}"
                         r"|\$\{#" + _P + r"\}|\$\{" + _P + r"(?::?[-+?]|%%?|##?)[^$`}\\'\"]*\}")
SAFE_CMDS = ("echo", "printf", ":", "true", "false", "[", "test", "cd", "popd", "kill")   # each measured: status only
# audit-w284 #23 — names whose redefinition breaks the proof: the exit, its two prefixes, the whitelisted commands
# (a function named echo runs its body: measured), and cd/pushd (SIMILAR: `cd() { :; }` defeats every cd proof).
DANGER_FUNCS = frozenset(("exit", "builtin", "command", "cd", "pushd") + SAFE_CMDS)
VOID_CMDS = ("enable", "alias", "eval", "source", ".")
VOID_WORDS = ("extdebug", "failglob", "lastpipe")


def safe_word(w):
    """#22 — a word whose expansion cannot fail without ending the shell: literal text, plain parameters only."""
    return ((not w.glob or w.text == "[") and not w.every and "$[" not in w.text and not w.hd   # a lone `[`: no pattern
            and all(SAFE_EXP_RE.fullmatch(s) or (k == "cmd" and (s[:2] == "$(" and s[:3] != "$((" or s[:1] == "`"))
                    for k, s in w.live))


def safe_simple(words, i):
    """#22 — words[i:] is a whitelisted builtin with safe words, no redirect that may fail, no assignment, no -v."""
    if i >= len(words):
        return not words[0].redbad                         # the reserved words alone (`then`; a child level follows)
    if words[0].redbad or words[i].text not in SAFE_CMDS:
        return False
    if words[i].text == "printf" and any(w.text.startswith("-v") for w in words[i + 1:]):
        return False
    return all(safe_word(w) for w in words[i:])


CD_NAMES = frozenset(("cd", "pushd", "builtin", "command"))


def cd_redefined(cmds):
    """§2.70 (z) — whether this text defines `cd`, `pushd`, `builtin` or `command` (a cd runs through `builtin cd` and
    `command cd`, both peeled as wrappers) as a function
    or an alias, or sets BASH_ALIASES: a cd that succeeds may then not move the shell (bash ran the next command in the
    start folder after `cd() { :; }; cd X &&`, and after `alias cd=:` from the next line on). Anywhere in the text, as
    `exit_voided` reads it: a definition later in a loop or function body still runs before a later pass. §2.70 (af)
    (ruled run 1261): an `eval` — its text may define any of them — counts as a definition, as the exit void reads one
    (a command whose NAME is an expansion that may spell `eval` too), so after it no cd proves a folder: an `&&`, a
    then/do body, `|| exit` and `|| return|continue|break` alike. A sourced file is not looked for (a script is not read)."""
    prev = None
    for words, seps in cmds:
        if CASE_PAT in seps:
            prev = None
            continue
        if seps[:2] == ["(", ")"] and prev in CD_NAMES:
            return True                                    # `NAME() …` (the lexer splits the name from its `()`)
        lw, rest = lead_words(words)
        for kind, j, _ in lw:
            if words[j].text == "function" and j + 1 < len(words) and words[j + 1].text in CD_NAMES:
                return True
        prev = words[rest].text if rest is not None and rest == len(words) - 1 else None
        if any(w.text.startswith("BASH_ALIASES") for w in words):
            return True
        head = peel(words)
        if head and posixpath.basename(head[0].text) == "eval":
            return True                                    # §2.70 (af): the eval'd text may define cd
        if head and (head[0].live or head[0].subs):        # a name an expansion makes may spell `eval` (as exit_voided)
            cut = min([i for i in (head[0].text.find("$"), head[0].text.find("`")) if i >= 0] or [0])
            if "eval".startswith(head[0].text[:cut]):   # (a prefix holding a `/`, `./bin/$x`, never does)
                return True
        if head and posixpath.basename(head[0].text) == "alias" and any(
                w.live or w.subs or w.text.split("=", 1)[0] in CD_NAMES for w in head[1:]):
            return True                                    # `alias cd=…` (an expanded name may be any)
    return False


def exit_voided(cmds):
    """#23 — whether anything in this text can make `exit` (or a whitelisted command) not mean the builtin: a function
    named in DANGER_FUNCS, `enable`, `alias`, `eval`, `source`, `.`, a command whose NAME is an expansion, a DEBUG trap,
    a nameref (`declare -n`), a dynamic `shopt`, a BASH_ALIASES/BASH_ENV/ENV assignment, or the options extdebug,
    failglob, lastpipe named anywhere. Anywhere in the text: a definition later in a loop or function still runs first."""
    prev = None
    for words, seps in cmds:
        if CASE_PAT in seps:
            prev = None
            continue
        if seps[:2] == ["(", ")"] and prev in DANGER_FUNCS:
            return "fn:" + prev                            # `NAME() …` (the lexer splits the name from its `()`)
        lw, rest = lead_words(words)
        for kind, j, _ in lw:
            if words[j].text == "function" and j + 1 < len(words) and words[j + 1].text in DANGER_FUNCS:
                return "fn:" + words[j + 1].text
        prev = words[rest].text if rest is not None and rest == len(words) - 1 else None
        for w in words:
            m = ASSIGN_RE.match(w.text)
            if w.text in VOID_WORDS or w.text.startswith("BASH_ALIASES") or (m and m.group(1) in ("BASH_ENV", "ENV")):
                return "word:" + w.text
        head = peel(words)
        if not head:
            continue
        h = head[0]
        if h.live or h.subs:                               # `$E -n exit` with E=enable: measured. A name whose literal
            cut = min([i for i in (h.text.find("$"), h.text.find("`")) if i >= 0] or [0])   # prefix spells none of
            pre = h.text[:cut]                             # VOID_CMDS (`./$f`, `do_$x`) cannot reach one
            if "/" not in pre and any(c.startswith(pre) for c in VOID_CMDS + ("builtin", "command")):
                return "dyn:" + h.text
        b = posixpath.basename(h.text)
        if b in VOID_CMDS:
            return "cmd:" + b
        args = head[1:]
        if b == "trap":
            while args and args[0].text in ("--", "-p", "-l", "-P"):
                args = args[1:]
            if any(w.live or w.text.upper() in ("DEBUG", "SIGDEBUG") for w in args[1:]):
                return "trap"
        if b in ("declare", "typeset", "local") and any(w.text.startswith("-") and "n" in w.text[1:] for w in args):
            return "nameref"
        if b == "shopt" and any(w.live for w in args):
            return "shopt-dyn"
    return False


def cd_verdict(st, words, join, after, fn=False, piped=(), env=None, brace=False):
    """§2.53 — the deny reason for an rm of a current-directory glob after a cd that may have failed, else None;
    updates `st` with this command. `fn`: this command opens a function body (`f() {`); `piped`: the word indices
    of openers whose compound runs in a subshell (`piped_openers`), marked with a trailing `|` in `frames`."""
    ok_in = st.ok                                           # §2.70 (d): the left side's guarantee, before this join
    lw = lead_words(words, fn, brace)[0]                    # run 1255 B8: the one leading-word walk (B10: kw)
    lead, klead = [], []                                    # its keywords and compound words, prefixes and names out:
    for out, rd, ws in ((lead, (lambda w: w.text), lead_words(words, fn, brace, True)[0]), (klead, kw, lw)):
        for _, k, _ in ws:                                  # `lead` as text, for the gates that PROVE a cd (B10: a
            if rd(words[k]) not in KEYWORDS and rd(words[k]) not in COMPOUND:   # quoted word may only add denies
                break                                       # there); `klead` as the grammar reads it, for the walks
            out.append(rd(words[k]))                        # (`fi`/`done`/`esac` end both, as before)
    first, head = kw(words[0]), run_head(words)                # §2.70 (c): through flock / runuser -u
    base = posixpath.basename(head[0].text) if head else ""
    # §2.70 (s) — the words stripped before the command: an external program among them runs `exit`/`continue`/… as a
    # program of its own, which fails, so the shell goes on (only `builtin`, `command` and the `time` keyword run it here)
    prog = not shell_runs(words[:len(words) - len(head)])
    # audit-w284 #20 — an `exit` whose own redirect fails (`exit 1 >/no/such/f`, `exit 1 2>>$LOG` with LOG unset) is
    # skipped outside POSIX mode and the shell goes on: an exit carrying a redirect proves nothing. watch:a9c6a4fb —
    # only for the PROOFS: a jump out of a group still counts as an escape (`prog`), since its redirect may work.
    ext = prog or (bool(words) and words[0].redir)
    # §2.70 (u) — the jump this command runs, written in place. §2.70 (ae) (ruled run 1261): an `eval`'s text is not
    # read for jumps any more (§2.70 (ac)'s `eval_jumps`, retired): an eval anywhere voids every cd proof
    # (`cd_redefined`, §2.70 (af)), so an eval'd jump has no proven state to undo, and emptying it moved no verdict in
    # 57,831 replayed and generated commands or 9,144 targeted shapes before that
    jumps = [] if prog else [(base, head[1:])] if base in SCOPED else []
    after_cd, st.after_cd = st.after_cd, False
    # §2.71 — the loop a leading `do` belongs to is the innermost open one: one `opener` variable for the whole level
    # forgot an outer `until` once a nested loop's `do` had run, and its body runs exactly when the condition failed.
    loop = next((f.rstrip("|") for f in reversed(st.frames) if f.rstrip("|") in LOOPS), "") if first == "do" else ""
    closers = 0                                             # §2.71: the compounds this command opens and closes
    events = []                                             # B9: (event, record) in order
    in_body = st.body is not None                           # B9: this command started inside a guarded body
    for kind, k, _ in lw:                                   # §1.158 (a) `function NAME {`, §2.70 (o) `coproc [NAME]`
        t = kw(words[k])
        if kind in ("open", "func"):                        # (its compound's frames on the coproc's span level)
            st.frames.append(("func" if kind == "func" else t) + ("|" if k in piped else ""))
            # B9 (h)(q) — `skip`: the state when the compound never runs. A function body is MERGED (maybe called);
            # the first opener of a command entered by `&&` is skipped when its left side failed (the `&&` chain after
            # the closer is then unreachable: ok), by `||` when it succeeded (proven if the left side proved the cd).
            rec = {"kind": "func" if kind == "func" else t, "alt": None, "done": [], "else": False, "cdn0": st.cdn,
                   "skip": snap(st, st.base if join not in (None, "&&", "|", "|&") else None) if kind == "func"
                   else None}                       # watch:69795817 — the ok after this command's join (cd_join)
            if kind != "func" and not events and join in ("&&", "||"):
                rec["skip"] = (snap(st, True) if join == "&&" else
                               (None, None, False, st.base) if ok_in else snap(st, False))
            st.snaps.append(rec)
            events.append(("open", rec))
        elif kind == "close":
            if st.frames:
                st.frames.pop()
                events.append(("close", st.snaps.pop()))
            closers += 1
        elif t in ("then", "do", "else", "elif") or (brace and k == 0 and t == "{"):   # a brace body's `{` is its `do`
            rec = st.snaps[-1] if st.snaps else None
            if t != "else" and t != "elif" and rec is not None:
                rec["alt"] = snap(st, False)                # the branch not taken: an if/loop that ran none exits 0
            events.append(("else" if t == "else" else "elif" if t == "elif" else "then", rec))
    if st.negrec is not None:                              # B11: the command right after `if ! cd X` must be its then
        r, st.negrec = st.negrec, None
        r["negcd"] = "body" if first == "then" and any(e == "then" and x is r for e, x in events) else None
    if st.body is not None:                                 # §2.69: inside a body the cd's success already guards
        # watch:098be789 — walk EVERY leading reserved word: bash takes closers back to back with no `;` (`} fi`,
        # `fi fi`, `} }`, `} else`), and counting only the first left the body open past its own end.
        end = None
        for kind, k, _ in lw:                               # run 1255 B8: past `time -p`, `function NAME`, `coproc`
            t = kw(words[k])
            if t in ("function", "coproc"):
                continue
            if end is not None:                             # §2.71: a closer or `else` stacked on the end
                if t in CLOSERS or t in ("else", "elif"):
                    end = "stacked"
                    break
                if t not in KEYWORDS:
                    break
            elif t in CLOSERS or (t in ("else", "elif") and not st.keep):
                if st.body == 0:
                    end = t                                 # the body ended (or its branch did)
                elif t in CLOSERS:
                    st.body -= 1
            elif kind in ("open", "func"):                  # (a brace body's `{` is no opener: B8 (b))
                st.body += 1
            elif t not in KEYWORDS:
                break
        if end is not None:
            # §2.71 — a whole compound entered while ok ends with the cd's guarantee still standing, unless a closer or
            # `else` is stacked on it (`if cd A; then cd B && { :; } fi && rm` runs the rm when cd A failed).
            st.ok = True if st.keep and end != "stacked" else st.base
            st.body, st.keep = None, False
    else:
        if first not in ("then", "do"):                     # a then/do body runs only when its condition list succeeded
            cd_join(st, join)
        if loop == "until":
            st.ok = False                                   # an until body runs when the condition FAILED
        if first in ("then", "do") and st.ok:
            st.body, st.keep = sum(t in OPENERS for t in klead[1:]), False  # §2.69: entered only if the cd succeeded
        elif st.ok:
            # §2.71 (a) — a compound entered while ok is guarded whole, to its own closer, and the `&&` chain runs on
            # past it: `cd X && { make; } && rm -f *`, `cd X && if a; then :; else rm -f *; fi`.
            k = next((k for k, t in enumerate(klead) if t in OPENERS), None)
            if k is not None:
                st.body, st.keep = sum(t in OPENERS for t in klead[k + 1:]), True
    for ev, rec in events:                                  # B9: a case with no arm taken leaves this state
        if ev == "open" and rec["kind"] == "case":
            rec["alt"] = snap(st, False)
    for jb, ja in jumps:                                    # §2.70 (u): a jump the shell runs (a redirect may work)
        jrs = jump_rec(st, jb, ja)
        if jrs:                                             # reached only if the cd worked: nothing unproven leaves
            j = snap(st)
            for jr in jrs:                                  # §6817: each loop an expansion count may leave
                jr.setdefault("jumps", []).append((None, j[1], False, j[3]) if st.ok else j)
    # audit-w276 #1 — an `exit` piped or backgrounded (`exit 1 | cat`, `exit 1 &`) runs in a subshell and ends only
    # that, and so does a whole `{ …; exit; }` group piped or backgrounded at its `}`: none of them disarms the cd.
    ends = not ext and ((base == "exit" and not _MODE["noexit"]) or (base in SCOPED and scoped(st, base)))   # §2.71 (d),
    # §2.70 (s); #23: under the void (exit_voided) an exit proves nothing — at its source, so a `|| { …; exit; }` group
    # never reads it as its exit either (patch.py's edit F gated only the group's first branch, and the next proved it)
    if join == "||" and after_cd:
        if base == "exit" and not ext and not lead and after not in PIPE_BG and not _MODE["noexit"]:
            st.cd = None                                    # `cd X || exit [N]` ends the shell; `|| return` does not
                                                            # (measured) — outside a function
        elif base in SCOPED and not lead and after not in PIPE_BG and ends:
            st.ok, st.body, st.keep = True, 0, False        # §2.71 (d): the rest of the loop/function body is guarded
        elif first == "{":                                  # §2.69: `cd X || { …; exit [N]; }` — watch for its exit,
            st.grec = next((r for e, r in events if e == "open"), None)
            st.group = (base if ends and set(lead) <= {"{"} and after not in PIPE_BG
                        else True)                          # which counts only once the group closes un-piped
            if st.group is True and any(scoped(st, jb) for jb, _ in jumps) and st.grec is not None:
                st.grec["esc"] = True                       # watch:a9c6a4fb — a jump whose redirect may work may leave
    elif st.group:
        # §2.71 (b) (B9 (i)) — the group closes when ITS record is popped (a nested `{ :; }` closer is not its end), and
        # an exit counts when only plain `{` groups sit above it: a compound that ran and closed before it does not
        # cancel the watch, while an exit inside an open if/loop/case/function (`plain_to` false) never counts.
        if any(e == "close" and r is st.grec for e, r in events):
            esc = st.grec.get("esc")                        # watch:68cb2fda — a jump may have left before the exit:
            # §2.70 (x) — a redirect on the group's `}` that may fail skips the group, its exit with it: no proof
            skipped = bool(words) and words[0].redir
            if st.group == "exit" and not esc and not skipped and after not in PIPE_BG:   # then the rest of the body
                st.cd = None                                # is still skipped, but the cd is proven nowhere past it
            elif (st.group in SCOPED or st.group == "exit") and not skipped and after not in PIPE_BG and closers == 1:
                st.ok, st.body, st.keep = True, 0, False    # §2.71 (d): a closer stacked on the `}` ends the loop too
            st.group, st.grec = False, None
        elif st.group is True and ends and not lead and join == ";" and after not in PIPE_BG and plain_to(st, st.grec):
            st.group = base
        elif st.group is True and any(leaves(st, jb, ja) for jb, ja in jumps):
            st.grec["esc"] = True                           # watch:68cb2fda — a jump out of the group's loop or
                                                            # function, not its own last word, skips its exit
    top = st.snaps[-1] if st.snaps else None
    b11 = st.snaps[0] if st.snaps and st.snaps[0] is not None and st.snaps[0].get("negcd") == "body" \
        and not st.snaps[0].get("exited") else None
    if top is not None and top.get("negcd") == "body" and base == "exit" and not ext and after not in PIPE_BG \
            and (lead == ["then"] if first == "then" else (not lead and join == ";")):
        if top.get("safe") and not _MODE["noexit"] and not words[0].redbad and all(safe_word(w) for w in head[1:]):
            top["exited"] = True                            # B11: the then-branch of `if ! cd X` always exits
        else:
            top["safe"] = False                             # #22/#23: this exit may not run; a later one is unreachable
    elif b11 is not None and not (top is b11 and lead in ([], ["then"]) and safe_simple(words, len(lead))):
        b11["safe"] = False                                 # #22: a command before the exit that may abandon the if
    for ev, rec in events:                                  # B9 (h)(q): branch switches, then each closer's fold
        if rec is None or ev in ("open", "then"):
            continue
        if ev in ("else", "elif"):
            if rec.get("negcd") == "body":                  # B11: the then-branch of `if ! cd X` ends here
                rec["negcd"] = "done"
                if rec.get("exited"):                       # it always exited: this branch runs after the cd worked
                    st.cd, st.ok, st.after_cd = None, False, False
                    rec["else"], in_body = ev == "else", False
                    continue
            rec["done"].append((None, None, False, st.base) if in_body else snap(st))
            in_body = False
            a = rec["alt"]                                  # the next branch starts where the condition failed —
            if a is not None and (a[0] is not None or a[1] is not None):   # restored only to an unproven cd
                st.folded = st.folded or (a[0], a[1]) != (st.cd, st.bgcd)  # a cd the branch had proven came back
                st.cd, st.bgcd, st.ok, st.base = a
                st.after_cd = False
            rec["else"] = ev == "else"
            continue
        in_body = False
        if rec.get("negcd") in ("body", "done") and words and (words[0].redir or words[0].redbad):
            st.cd, st.ok, st.after_cd = rec["cdtext"], False, False   # audit-w284: a failed redirect on the closer
            continue                                        # skips the whole `if`, its cd and its exit with it
        if rec.get("negcd") == "body" and rec.get("exited"):
            st.cd, st.ok, st.after_cd = None, False, False  # B11: no branch but the exiting one: the cd worked
            continue
        paths = [(st.cd, st.bgcd, st.ok, st.base)] + rec["done"] + rec.get("jumps", [])   # §2.70 (u)
        if rec["kind"] in ("if", "case") + LOOPS and rec["alt"] is not None and not rec["else"]:
            paths.append(rec["alt"])                        # no branch taken
        if rec["skip"] is not None:
            paths.append(rec["skip"])                       # the compound never ran
        # §2.70 (x) — a redirect on a closer that may fail skips the whole compound: a cd made inside it did not run, so
        # the delete after it is not where that cd went (the `fi` of B11a's `if ! cd` had this rule alone: §6621)
        incd = st.lastcd if st.cdn > rec["cdn0"] else None   # the last cd made while it was open (#19)
        redir = words[0].redir and incd is not None
        if redir:
            paths.append((incd, st.bgcd, False, st.base))
        out = fold(paths)
        if out != (st.cd, st.bgcd, st.ok, st.base):
            st.folded = ("redir" if redir and out[0] == incd and out[0] != st.cd else
                         st.folded or (out[0], out[1]) != (st.cd, st.bgcd))
            st.cd, st.bgcd, st.ok, st.base = out
            st.after_cd = False
    # §2.71 (c) (ruled 2026-10-05) — with no cd of this shell's own that may have failed, a cd that ran in a background
    # job, a pipeline element or a coproc (`st.bgcd`) is the one the delete was written after, and it moved nothing.
    sub = st.cd is None and st.bgcd is not None
    if (st.cd is not None or sub) and not st.ok and st.body is None and base == "rm":
        recursive, operands = split_rm(head[1:])
        operands = [resolved(a, env) for a in operands]       # audit-w279 #21: `D=build; cd X; rm -rf $D/x`
        for a in operands:
            if cwd_glob(a) and sub:
                return ("eugo-deletion-guard: blocked an rm of `%s` after `%s` — the glob matches the CURRENT "
                        "directory, and a cd in a background job, a pipeline or a coproc runs in its own subshell and "
                        "never changes this shell's directory, so it deletes in the directory the command started in "
                        "(§2.71 (c)). %s" % (show(a.text), st.bgcd, CD_FIX))
            if cwd_glob(a):
                return ("eugo-deletion-guard: blocked an rm of `%s` after `%s` — the glob matches the CURRENT "
                        "directory, and nothing stops the rm when that cd fails (%s), so it deletes in the directory the "
                        "command started in (report:119: `cd $P/mx2; rm -f *` from a repo root). %s"
                        % (show(a.text), st.cd, unproven(st), CD_FIX))
        for a in (operands if recursive else ()):              # §2.68 (b): a recursive rm of a relative tree
            if cwd_rel(a) and sub:
                return ("eugo-deletion-guard: blocked a recursive rm of `%s` after `%s` — the path is relative to the "
                        "CURRENT directory, and a cd in a background job, a pipeline or a coproc runs in its own "
                        "subshell and never changes this shell's directory, so it deletes that tree in the directory "
                        "the command started in (§2.68, §2.71 (c)). %s" % (show(a.text), st.bgcd, CD_TREE_FIX))
            if cwd_rel(a):
                return ("eugo-deletion-guard: blocked a recursive rm of `%s` after `%s` — the path is relative to the "
                        "CURRENT directory, and nothing stops the rm when that cd fails (%s), so it deletes that tree in "
                        "the directory the command started in (§2.68, report:119's shape). %s"
                        % (show(a.text), st.cd, unproven(st), CD_TREE_FIX))
    if (st.cd is not None or sub) and not st.ok and st.body is None and base == "find":
        starts, _, acts = find_parts(head[1:])
        starts = [resolved(a, env) for a in starts]           # audit-w279 #21
        for a in (starts or [Word(".")]) if acts else ():     # §2.68 (a): a deleting find from a relative start
            if cwd_rel(a):
                return ("eugo-deletion-guard: blocked a find that deletes from `%s` after `%s` — the start is "
                        "relative to the CURRENT directory, and %s, so it deletes under the directory the command "
                        "started in (§2.68, %s). Chain it so a failed cd stops the find (`cd DIR && find . …`, or "
                        "`cd DIR || exit` first), or start it at `${VAR:?}` or an absolute literal path."
                        % (show(a.text), st.bgcd if sub else st.cd,
                           "a cd in a background job, a pipeline or a coproc runs in its own subshell and never changes "
                           "this shell's directory" if sub else
                           "nothing stops the find when that cd fails (%s)" % unproven(st),
                           "§2.71 (c)" if sub else "report:119's shape"))
    # audit-w281 #17 — a cd is this shell's only through peel's wrappers: one `flock FILE` or `runuser -u` runs is an
    # external program in a child, which moves nothing here (run_head is for the rm/find base alone).
    cd_head = peel(words)
    if cd_head and posixpath.basename(cd_head[0].text) in ("cd", "pushd") and join not in ("|", "|&") \
            and after not in ("|", "&", "|&"):
        st.cd = st.seen = show(" ".join(w.text for w in cd_head))
        st.bgcd, st.folded = None, False                    # §2.71 (c): this shell's own cd, after any subshell's
        st.cdn, st.lastcd = st.cdn + 1, st.cd               # §2.70 (x): for the compounds open around it, should
                                                            # their closer's redirect fail (audit-w286 #19)
        pre = [w.text for w in words[:len(words) - len(cd_head)]]  # every word peel stripped before the cd
        kpre = [kw(w) for w in words[:len(words) - len(cd_head)]]
        if kpre == pre and pre[:2] == ["if", "!"] and pre[2:] in ([], ["builtin"]) and join in (None, ";") \
                and len(st.frames) == 1 and st.snaps and st.snaps[-1] is not None and st.snaps[-1]["kind"] == "if" \
                and not fn:                                 # audit-w284: `f() if ! cd X; …` only defines f
            st.negrec = st.snaps[-1]                        # B11: `if ! cd X` alone, the level's only open compound
            st.negrec["cdtext"] = st.cd
            st.negrec["safe"] = not words[0].redbad and all(safe_word(w) for w in cd_head)   # #22: the condition too
        sure = "!" not in pre and (join != "||" or ok_in)    # §2.70 (d): a skipped `|| cd` guards only if the left side did
        sure = sure and not _MODE["nocd"]                   # §2.70 (z): a redefined cd may succeed without moving
        st.ok = sure and "until" not in pre
        st.base, st.after_cd = False, sure
        st.body, st.group, st.keep = None, False, False     # §2.69: a new cd ends any body's guarantee (never frames)
    return None


#: watch:db9ff1585 — `posix`: the reading `check_text` lexes in (a `'` in a double-quoted `${…}` is a character).
#: §3.52 R2 (run 1261; ruled at its widget: profile and cut the 1 MB cost) — `split`: the lexer met a spot that bash and
#: POSIX sh read apart, the four places `posix` is read (a `$'` or `'` in a double-quoted `${…}` operand where the two
#: conditions differ, a `$'…'`/`$"…"` heredoc delimiter). Both readings are the same computation up to the first such
#: spot, so a first read that met none would be repeated word for word: `check_text` re-reads only a text that met one,
#: where it re-read every text holding any `${` and any `'` (a `<<'EOF'` fed 1 MB script, read four times for two).
_MODE = {"posix": False, "noexit": False, "nocd": False, "split": False}    # #23: `noexit`, the void (`exit_voided`);
# §2.70 (z): `nocd`

#: §1.176 — the nesting the checker reads: every `$(…)`, `$((…))`, `<(…)` and top-level `${…}` level (`Lexer.dollar`,
#: `nested`), every text it checks (a substitution's body, a fed heredoc, a -c string) and every docker/runuser/flock
#: wrapper `check_command` recurses through counts one; a `${…}` nested in another's operand and `peel`'s wrappers
#: (`sudo`, `env`, …) recurse nowhere, so they need no count (audit-w286 #14). Past it the command is DENIED: reading on,
#: the stack overflowed near 500 levels, and a crash fails open by design (`rm -rf /` at the centre ran unchecked).
MAX_NEST = 100
_NEST = [0]


class TooDeep(Exception):
    """§1.176 — the command nests past MAX_NEST: a deny, never the crash's fail-open."""


class TooMuch(TooDeep):
    """§1.180 — the texts nested in the command would be read past its read budget: a deny, as TooDeep is."""


#: §1.180 — a fed heredoc, a string run by a shell or a substitution is checked as a text of its own, so a nest of them
#: re-reads the rest of the command at every level: MAX_NEST stops the depth at 100, which still leaves about 100 times
#: the command's size (90 levels around a 1 MB body took 5.3 s of CPU in-process, and a hook that times out ALLOWS).
#: Every text checked counts its length (the POSIX re-read too) against WORK_MULT times the whole command's length,
#: never under WORK_FLOOR characters; past it the command is denied. Measured on 27,962 real Bash commands from local
#: transcripts (run 1259): the most any was read is 4.8 times its length.
WORK_MULT, WORK_FLOOR = 16, 1 << 20
_WORK = [0, 0]                                                # characters read so far, the budget


def enter():
    """§1.176 — one nesting level deeper; past MAX_NEST, TooDeep (the caller's `finally` undoes only a level it took)."""
    _NEST[0] += 1
    if _NEST[0] > MAX_NEST:
        _NEST[0] -= 1
        raise TooDeep()


DEEP = ("eugo-deletion-guard: blocked a command that nests `$(…)`, `$((…))`, `<(…)`, `${…}`, strings run by a shell, "
        "fed heredocs or container wrappers more than %d levels deep — past what the guard reads, so it cannot tell what would run "
        "(§1.176). Split it into shallower commands. " % MAX_NEST + FIX)
BIG = ("eugo-deletion-guard: blocked a command whose nested `$(…)`, strings run by a shell and fed heredocs would have the "
       "guard read it more than %d times over — past what the guard reads within its timeout, so it cannot tell what "
       "would run (§1.180, the cost twin of §1.176's depth bound). Split it into smaller commands. " % WORK_MULT + FIX)


def check_text(text, bind=True):
    """The first deny reason in `text`, or None. With `bind`, a name assigned a literal earlier in
    `text` resolves to it where that assignment provably ran first (see the header). watch:db9ff1585 — a
    text whose first read met a spot bash and POSIX sh read apart (`_MODE["split"]`, §3.52 R2; it was any text holding
    both `${` and `'`) is read twice, bash's way and POSIX sh's (see `dollar`), at ANY depth (watch:ca5fcfbea: a `-c`
    string joined from quoted pieces, `"$''{x:-it'"'"'s}"`, holds them where the outer
    text does not); a text already read the POSIX way is not read twice again, so the cost grows with the
    nesting depth, never exponentially. §1.176: one nesting level, counted. §1.180: the whole command (no level open
    yet) starts a fresh read budget."""
    if _NEST[0] == 0:
        _WORK[0], _WORK[1] = 0, max(WORK_FLOOR, WORK_MULT * len(text))
    enter()
    split = _MODE["split"]                                    # §3.52 R2: a nested text's spot also re-reads its
    _MODE["split"] = False                                    # enclosing texts (as before: they hold its `${` and `'`)
    try:
        r = _check_text(text, bind)
        if r is None and not _MODE["posix"] and (_MODE["split"] or HD_DOLLAR_RE.search(text)):
            _MODE["posix"] = True
            try:
                r = _check_text(text, bind)
            finally:
                _MODE["posix"] = False
        return r
    finally:
        _NEST[0] -= 1
        _MODE["split"] = split or _MODE["split"]


def _check_text(text, bind=True):
    _WORK[0] += len(text)                                     # §1.180: every read counts, the POSIX re-read too
    if _WORK[0] > _WORK[1]:
        raise TooMuch()
    lx = Lexer(text)
    toks = lx.run(0, False)[0]
    cmds = commands(toks)
    # #23 — whether anything in this text can make `exit` (or a whitelisted builtin) not mean the builtin; every text
    # checked inside it inherits the answer (a definition there runs first), and never passes one back up
    saved, saved_cd = _MODE["noexit"], _MODE["nocd"]
    _MODE["noexit"] = saved or bool(exit_voided(cmds))
    _MODE["nocd"] = saved_cd or cd_redefined(cmds)          # §2.70 (z), inherited the same way
    try:
        return _walk(bind, lx, toks, cmds)
    finally:
        _MODE["noexit"], _MODE["nocd"] = saved, saved_cd


def _walk(bind, lx, toks, cmds):
    """`_check_text`'s walk over the commands of one text, once its void is known."""
    bound, frozen = {}, not bind                              # name -> (literal, bound in the current && chain)
    levels = [CdWatch()]                                      # §2.53: the cd watch, one per subshell level
    prev = []
    bb = brace_bodies(cmds)                                   # run 1255 B8 (b): `for f in a; { …; }`
    piped = piped_openers(cmds, bb)                           # watch:c41ccd2d
    spans = subshell_spans(cmds, bb)                          # §2.71 (c)
    cut_at = {}                                               # audit-w281 #16: each command's mid-word cuts, once
    for kk, ii, j in spans:
        if j:
            cut_at.setdefault(kk, set()).add((ii, j))
    for k, (words, seps) in enumerate(cmds):
        before = joined_by(seps)
        after = joined_by(cmds[k + 1][1]) if k + 1 < len(cmds) else None
        if before != "&&":
            bound = dict((n, v) for n, v in bound.items() if not v[1])     # a chain's bindings end with it
        if "(" in seps or ")" in seps or words[0].text in COMPOUND:
            bound, frozen = {}, True
        # §2.53 — an operator before `(` joins the PARENT level before the push, and after `)` the pop comes first:
        # otherwise `cd X; (true) && rm -f *` keeps a stale ok and passes. §2.70: a case token neither pushes nor pops.
        ops = []
        for i in range(len(seps) + 1):
            # §2.71 (c) — a subshell span closes (the operator before it is the span's own) and opens here; an operator
            # before an open joins the PARENT first, so the span starts in the state its list is entered with.
            closes, opens = spans.get((k, i, 0), (0, 0))
            for _ in range(closes + opens):
                if ops:
                    cd_join(levels[-1], joined_by(ops))
                    ops = []
                if closes:
                    closes -= 1
                    pop_span(levels)
                else:
                    push(levels, span=True)
            if i == len(seps):
                break
            s = seps[i]
            if s in (CASE_PAT, CASE_SEP):
                continue
            if s in ("(", ")"):
                if ops:
                    cd_join(levels[-1], joined_by(ops))
                    ops = []
                if s == "(":
                    push(levels)
                elif len(levels) > 1:
                    levels.pop()
            else:
                ops.append(s)
        if CASE_PAT in seps:                                  # §2.70: a case pattern is data, not a command
            cd_join(levels[-1], joined_by(ops) if ops else None)
            levels[-1].after_cd = False
            continue
        r = check_command(words, dict((n, v[0]) for n, v in bound.items()))
        if r:
            return r
        # §2.71 — `f() {` / `function f() {`: the `{` opens a function body (the previous command named it).
        named = [w.text for w in prev]
        while named and named[0] in KEYWORDS:
            named = named[1:]                                 # `do g() {`: the name, not the keyword
        fn = seps[:2] == ["(", ")"] and (len(named) == 1 or (len(named) == 2 and named[0] == "function"))
        # audit-w284 #3 #4 — `function NAME` alone, its `{` on the next line, defines the function too
        fn = fn or (len(named) == 2 and named[0] == "function" and joined_by(seps) == ";" and kw(words[0]) == "{")
        prev = words
        # §2.71 (c) — a span may open inside this command, after the reserved words of the compound that encloses it
        # (`then cd Y &`, `f() { { cd "$1" || …; } | cat`): those words run on THIS level, the rest in the span. The
        # last command of a span ends its subshell, so nothing follows it there.
        cuts = sorted(j for ii, j in cut_at.get(k, ()) if ii == len(seps) and 0 < j < len(words))
        env = dict((n, v[0]) for n, v in bound.items())
        for a, b in zip([0] + cuts, cuts + [len(words)]):
            if a:
                closes, opens = spans[(k, len(seps), a)]
                for _ in range(closes):
                    pop_span(levels)
                for _ in range(opens):
                    push(levels, span=True)
            last = b == len(words)
            r = cd_verdict(levels[-1], words[a:b], (joined_by(ops) if ops else None) if not a else None,
                           (None if spans.get((k + 1, 0, 0), (0, 0))[0] else after) if last else None, fn and not a,
                           {j - a for kk, j in piped if kk == k and a <= j < b}, env, k in bb and not a)
            if r:
                return r
        head = peel(words)
        base = posixpath.basename(head[0].text) if head else ""
        if base in FORGET or (base == "printf" and any(w.text.startswith("-v") for w in head[1:])):
            bound, frozen = {}, True
        assigns, new, mk = [ASSIGN_RE.match(w.text) for w in words], {}, {}
        for w, m in zip(words, assigns):
            if m is None:
                bound.pop(w.text, None)                       # a bare NAME may be set: `unset C`, `printf -v C`
                continue
            bound.pop(m.group(1), None)                       # any other assignment forgets the name
            if m.group(1) == "IFS":
                bound, frozen = {}, True                      # a new IFS splits every unquoted value its own way
            value = w.text[m.end():]
            if not w.live and not m.group().endswith("+=") and BIND_VALUE_RE.fullmatch(value) \
                    and m.group(1) not in NEVER_BIND:
                new[m.group(1)] = value
            elif len(w.live) == 1 and w.live[0][0] == "cmd" and value == w.live[0][1] \
                    and value.startswith("$(") and len(w.subs) == 1 and MKTEMP_RE.fullmatch(w.subs[0]) \
                    and not m.group().endswith("+=") and m.group(1) not in NEVER_BIND:
                mk[m.group(1)] = MKTEMP_BOUND
        if not frozen and all(assigns) and before in (None, ";", "&&") and after not in ("|", "&", "|&"):
            bound.update((n, (v, before == "&&")) for n, v in new.items())
            bound.update((n, (v, True)) for n, v in mk.items())      # §1.103 L2: its && chain only
    for t in toks:
        if isinstance(t, Word):
            for body in t.subs:
                r = check_text(body)
                if r:
                    return r
    for body, fbind in lx.feeds:                              # §1.163: a heredoc or here-string fed to a shell
        r = check_text(body, fbind)
        if r:
            return r
    return None


try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)                                               # not a hook payload: nothing to check
ti = d.get("tool_input") if isinstance(d, dict) else None
cmd = ti.get("command") if isinstance(ti, dict) and d.get("tool_name") == "Bash" else None
if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(0)
try:
    reason = check_text(cmd)
except TooDeep as e:                                          # §1.176: too deep to read is a deny, not a crash;
    reason = BIG if isinstance(e, TooMuch) else DEEP          # §1.180: so is too much
except Exception as e:                                        # the checker broke: exit 4, MAIN fails CLOSED (§3.52 S3.7)
    print("the checker failed (%s)" % type(e).__name__)
    sys.exit(4)
if reason:
    print(reason)
    sys.exit(3)
sys.exit(0)
PY
}

MSG="$(verdict)"
RC=$?
case "$RC" in
  0) exit 0 ;;
  3) ;;
  4) printf 'eugo-deletion-guard: %s, so this command was not checked; exit 1: blocked where the row carries onFailure:block (Claude Code 2.1.295+) — split or simplify it\n' "$(printf '%s' "$MSG" | tr '\n\t' '  ')" >&2
     exit 1 ;;
  *) printf 'eugo-deletion-guard: the checker exited %s; the command was allowed unchecked\n' "$RC" >&2
     exit 0 ;;
esac
# The reason travels inside JSON; escape the four characters that could break it.
ESC="$(printf '%s' "$MSG" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  ')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$ESC"
exit 0
