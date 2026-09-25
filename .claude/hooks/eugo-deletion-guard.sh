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
# `find` with `-delete` or `-exec|-execdir|-ok|-okdir rm`, when one of its path operands
#   (a) carries an UNGUARDED expansion — `$NAME`, `${NAME}`, `${NAME%…}`, `${NAME#…}`,
#       `${NAME:-…}`, `${NAME-…}` (a default can still be empty), `${NAME?…}` (it aborts only
#       when NAME is UNSET: a failed `C=$(…)` leaves C set and empty, and that passes), `$1`,
#       `$@`, `$(…)`, backticks; `${NAME:?…}` is GUARDED (empty or unset aborts the command),
#       and `$$`, `$?`, `$#`, `$-`, `$((…))` never expand to nothing; or
#   (b) normalises (repeated and trailing slashes, leading `./`, `.`/`..` components) to a
#       protected root, or to one followed by `/*` or `/.*`: / . .. (and any run of ..) * .* ~
#       /repo /opt /opt/eugo /opt/eugo/<one component> (a whole checkout) /home /home/<user>
#       /root — `~user` counts as a home. find with no starting point starts at `.`. A find
#       whose delete only reaches NAMED entries — a positive -name/-path/-regex test before the
#       action, its literal pattern holding a letter or digit, and no -o, `,` or parentheses
#       (`find . -name __pycache__ -exec rm -rf {} +`) — may start at `.` or another RELATIVE
#       path, never at an absolute path or a home (operator ruling 2026-09-24: `find ~ -name .git
#       -exec rm -rf {} +` deletes every repo's .git); (a) still holds.
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
# It splits on ; && || | & ( ) and newlines, reads quotes the way bash does (a single-quoted
# `$X` is text, a double-quoted one expands), skips comments and heredoc bodies, and recurses
# into the string of `bash|sh|zsh|dash|ksh -c` (any cluster holding c: `-lc`, `-ec`), into
# every `$(…)` / backtick / `<(…)` body, and past `sudo`, `env`, `xargs`, `timeout`, `nice`,
# `nohup`, `time`, `command`, `exec`, `setsid`, `ionice`, `stdbuf`, `busybox <applet>`, into
# `su … -c STRING` / `--session-command STRING`, `runuser -u USER [--] cmd…` and su-style
# `runuser [-] USER -c STRING`, `flock <file> -c STRING` / `flock <file> cmd…` and `watch` (whose words it
# joins and runs with `sh -c`, so they are checked as that string: nothing binds), past
# leading `VAR=value` words, shell keywords (`then`, `do`, `!`,
# `{`, …), `docker [compose] exec|run` (`<container|service|image>`) and `docker-compose
# exec|run` — the incident's blast radius, since `run` bind-mounts the checkout just as well.
# The deny is `permissionDecision: "deny"` with a one-line reason naming the operand and the
# fix. That a deny stops the call is the Claude Code hooks contract; it was NOT probed on this
# box (the publish guard's probe covered "ask"), including under bypassPermissions.
#
# WHAT IT NEVER DOES. It never blocks a NON-recursive rm (`rm -f "$f"` deletes one file at
# most, never a parent tree), a literal path below a root (`rm -rf build/ outputs/_state/x`),
# `git rm`, `docker rm`, `docker run --rm`, `npm rm`, `rmdir`, or `rm` inside a quoted string,
# a comment or a heredoc body. It is a backstop, not a sandbox: a script file, a heredoc or a
# pipe fed to a shell (`bash <<EOF`, `… | sh`), `eval`, `env -S`, `docker container exec|run`,
# `kubectl exec`, `ssh`, python's `shutil.rmtree` (it only opens the parser: nothing denies on
# it) and a variable whose VALUE is `/` or `.` but was set outside this command are not parsed
# or cannot be known.
#
# TRANSPORT. Payload on stdin, program on fd 3, verdict by EXIT CODE (0 allow, 3 deny, 4 the
# checker failed) with the one-line reason on stdout — never argv and never a heredoc inside
# `$(…)`, for the publish guard's reasons (E2BIG fail-open; bash 3.2's paren/quote scanning).
#
# Contract (each line is a test in tools/tests/test_deletion_guard_hook.py):
#   - every path exits 0; a deny is ONE JSON line on stdout, an allow prints nothing
#   - a command with no `rm` word, no `-delete` and no `rmtree` never starts python
#   - the guard FAILS OPEN: a crash or a dead checker allows the command with ONE stderr line,
#     and so does a missing python3 (only for a command that reached the checker)
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
HOME_RE = re.compile(r"(?:/opt/eugo|/home)/[^/]+(?:/\*)?")
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
NAME_TESTS = ("-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex")


class Word(object):
    """One shell word. `text` has its quotes removed and every expansion kept verbatim; `live`
    lists the expansions the SHELL performs (never one inside single quotes) as (kind, shown):
    "var" can be empty, "guarded" is ${X:?}/${X?}, "fixed" never expands to nothing, "cmd" is a
    $(…)/backtick/<(…) whose BODY is in `subs` (checked as a command of its own)."""
    __slots__ = ("text", "live", "subs", "tilde")

    def __init__(self, text=""):
        self.text, self.live, self.subs, self.tilde = text, [], [], False


class Lexer(object):
    """Bash's word/operator split, enough of it to know which words are commands. Lenient: an
    unterminated quote or substitution runs to the end (bash would refuse to run it at all)."""

    def __init__(self, s):
        self.s, self.n = s, len(s)

    def run(self, i, stop):
        """Lex from i. With `stop` it ends at the `)` closing a $( or <( body: returns
        (tokens, index after that `)`, closed)."""
        s, n = self.s, self.n
        toks, heredocs, w, depth = [], [], None, 0
        while i < n:
            c = s[i]
            if c == "\\":
                if s.startswith("\\\n", i):                    # a line continuation joins the lines
                    i += 2
                    continue
                w = w or Word()
                w.text += s[i + 1:i + 2]
                i += 2
                continue
            if c in " \t\r\n":
                if w is not None:
                    toks.append(w)
                    w = None
                i += 1
                if c == "\n":
                    toks.append(";")                          # a newline separates commands
                    if heredocs:
                        i = self.bodies(i, heredocs, stop)    # heredoc bodies are data, never commands
                        heredocs = []
                continue
            if c == "#" and w is None:                        # a comment runs to the end of its line
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "'":
                j = s.find("'", i + 1)
                j = n if j < 0 else j
                w = w or Word()
                w.text += s[i + 1:j]
                i = j + 1
                continue
            if c == '"':
                w = w or Word()
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
            if c == ")" and stop and depth == 0:
                if w is not None:
                    toks.append(w)
                return toks, i + 1, True
            if c in "<>" and s.startswith("(", i + 1):        # process substitution: a command body
                _, j, closed = self.run(i + 2, True)
                w = w or Word()
                w.text += s[i:j]
                w.live.append(("cmd", s[i:j]))
                w.subs.append(s[i + 2:j - 1] if closed else s[i + 2:j])
                i = j
                continue
            if c in ";&|()<>":
                if c in "<>" and w is not None and w.text.isdigit() and not w.live:
                    w = None                                  # `2>`: the digits are a file descriptor
                if w is not None:
                    toks.append(w)
                    w = None
                if s.startswith("<<<", i):
                    toks.append(REDIR)
                    i += 3
                    continue
                if s.startswith("<<", i):
                    strip = s.startswith("<<-", i)
                    delim, i = self.delimiter(i + (3 if strip else 2))
                    heredocs.append((delim, strip))
                    continue
                for op in ("&>>", "&>", ">>", ">&", ">|", "<&", "<>", ">", "<"):
                    if s.startswith(op, i):                   # `2>&1` / `&>` never split on `&`
                        toks.append(REDIR)
                        i += len(op)
                        break
                else:
                    for op in (";;&", ";;", ";&", "&&", "||", "|&", ";", "&", "|", "(", ")"):
                        if s.startswith(op, i):
                            break
                    depth += 1 if op == "(" else -1 if op == ")" else 0
                    toks.append(";" if op.startswith(";") else op)
                    i += len(op)
                continue
            if w is None:
                w = Word()
                w.tilde = c == "~"
            w.text += c
            i += 1
        if w is not None:
            toks.append(w)
        return toks, n, False

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
                    w.text += s[i + 1]
                    i += 2
                else:
                    w.text += c
                    i += 1
                continue
            if c == "$" and s[i + 1:i + 2] not in ("'", '"'):  # `$"` / `$'` are text inside "…"
                i = self.dollar(i, w)
            elif c == "`":
                i = self.backtick(i + 1, w)
            else:
                w.text += c
                i += 1
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
        w.text += "`" + s[i:j] + "`"
        w.live.append(("cmd", "`" + s[i:j] + "`"))
        w.subs.append("".join(body))
        return j + 1

    def dollar(self, i, w):
        s, n = self.s, self.n
        nx = s[i + 1:i + 2]
        if s.startswith("$((", i):                            # arithmetic: always a number
            j, d = i + 3, 2
            while j < n and d:
                d += 1 if s[j] == "(" else -1 if s[j] == ")" else 0
                j += 1
            w.text += s[i:j]
            w.live.append(("fixed", s[i:j]))
            return j
        if nx == "(":
            _, j, closed = self.run(i + 2, True)
            w.text += s[i:j]
            w.live.append(("cmd", s[i:j]))
            w.subs.append(s[i + 2:j - 1] if closed else s[i + 2:j])
            return j
        if nx == "{":
            j, d = i + 2, 1
            while j < n and d:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == "'":
                    k = s.find("'", j + 1)
                    j = n if k < 0 else k + 1
                    continue
                if s[j] == '"':
                    j = self.dquote(j + 1, Word())
                    continue
                if s.startswith("$(", j):
                    j = self.run(j + 2, True)[1]
                    continue
                if s.startswith("${", j):
                    d += 1
                    j += 2
                    continue
                if s[j] == "}":
                    d -= 1
                j += 1
            w.text += s[i:j]
            w.live.append(("guarded" if GUARDED_RE.match(s, i + 2) else "var", s[i:j]))
            return j
        if nx == "'":                                         # $'…' ANSI-C quoting: text
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            w.text += s[i + 2:j]
            return j + 1
        if nx == '"':
            return self.dquote(i + 2, w)
        m = NAME_RE.match(s, i + 1)
        if m:
            w.text += "$" + m.group()
            w.live.append(("var", "$" + m.group()))
            return m.end()
        if nx and (nx.isdigit() or nx in "@*!"):
            w.text += s[i:i + 2]
            w.live.append(("var", s[i:i + 2]))
            return i + 2
        if nx and nx in "$?#-":
            w.text += s[i:i + 2]
            w.live.append(("fixed", s[i:i + 2]))
            return i + 2
        w.text += "$"
        return i + 1

    def delimiter(self, i):
        s, n = self.s, self.n
        while i < n and s[i] in " \t":
            i += 1
        j = i
        while j < n and s[j] not in " \t\r\n;&|()<>":
            if s[j] in "'\"":
                k = s.find(s[j], j + 1)
                j = n if k < 0 else k + 1
                continue
            j += 1
        return s[i:j].replace("'", "").replace('"', "").replace("\\", ""), j

    def bodies(self, i, heredocs, stop):
        s, n = self.s, self.n
        for delim, strip in heredocs:
            while i < n:
                j = s.find("\n", i)
                end = n if j < 0 else j
                line = s[i:end]
                probe = line.lstrip("\t") if strip else line
                if probe == delim:
                    i = n if j < 0 else j + 1
                    break
                if stop and probe.startswith(delim) and probe[len(delim):].lstrip().startswith(")"):
                    i += len(line) - len(probe) + len(delim)  # `EOF)` closes the $( on the same line
                    break
                i = n if j < 0 else j + 1
        return i


def commands(toks):
    """Tokens -> (the word list of each simple command, the separators just before it); a redirect's
    target is not an argument."""
    out, cur, seps, skip = [], [], [], False
    for t in toks:
        if isinstance(t, Word):
            if skip:
                skip = False
            else:
                cur.append(t)
        elif t == REDIR:
            skip = True
        else:
            if cur:
                out.append((cur, seps))
                cur, seps = [], []
            seps.append(t)
            skip = False
    if cur:
        out.append((cur, seps))
    return out


def joined_by(seps):
    """The operator joining a command to the one before it: None first, `;` for `;` or a newline
    (a newline straight after `&&` / `|` continues that operator)."""
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


def shell_string(args):
    """The command-string WORD of `bash -c STRING` (any option cluster holding c), else None."""
    has_c, i = False, 0
    while i < len(args):
        t = args[i].text
        if t in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            i += 2
            continue
        if t == "--":
            i += 1
            break
        if t.startswith("--"):
            i += 1
            continue
        if len(t) > 1 and t[0] in "-+":
            has_c = has_c or (t[0] == "-" and "c" in t[1:])
            i += 1
            continue
        break
    return args[i] if has_c and i < len(args) else None


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
    if roots and (is_root(p, b.tilde) or (p.endswith(("/*", "/.*")) and is_root(p.rsplit("/", 1)[0] or "/", b.tilde))):
        bound = "".join(" (`%s=%s` earlier in this command)" % (n, show(env[n])) for n in used)
        return ("eugo-deletion-guard: blocked %s of `%s`%s — it resolves to `%s`, a protected root (the "
                "filesystem root, a home, /repo or a whole /opt/eugo checkout, or the current/parent "
                "directory). Name the literal path below it that you mean (`./build`, `find ./tools …`). %s"
                % (what, show(a.text), bound, show(p), FIX))
    return None


def check_rm(args, env):
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
    if not recursive:
        return None                                           # one file at most: never a parent tree
    for a in operands:
        r = operand_verdict(a, "a recursive rm", env)
        if r:
            return r
    return None


def check_find(args, env):
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


def check_command(words, env):
    words = peel(words)
    if not words:
        return None
    base = posixpath.basename(words[0].text)
    args = words[1:]
    if base in SHELLS:
        inner = shell_string(args)                            # a string the OUTER shell expands binds nothing
        return check_text(inner.text, not inner.live) if inner is not None else None
    if base in ("docker", "docker-compose"):
        inner = docker_exec(base, args)
        return check_command(inner, env) if inner else None
    if base == "runuser":
        rest = args[skip_opts(args, 0, RUNUSER_VALUED):]
        opts = args[:len(args) - len(rest)]
        if any(w.text in ("-u", "--user") or w.text.startswith("--user=") or
               (w.text.startswith("-u") and not w.text.startswith("--")) for w in opts):
            return check_command(rest, env) if rest else None   # `runuser -u USER [--] cmd…`
        base = "su"                                           # `runuser [-] USER -c STRING`: su's form
    if base == "su":
        inner = su_string(args)
        return check_text(inner.text, not inner.live) if inner is not None else None
    if base == "flock":
        rest = args[skip_opts(args, 0, FLOCK_VALUED) + 1:]    # past the lock FILE (or fd: no command)
        if rest and rest[0].text in ("-c", "--command"):
            return check_text(rest[1].text, not rest[1].live) if len(rest) > 1 else None
        return check_command(rest, env) if rest else None
    if base == "watch":
        rest = args[skip_opts(args, 0, WATCH_VALUED):]
        return check_text(" ".join(w.text for w in rest), False) if rest else None
    if base == "rm":
        return check_rm(args, env)
    if base == "find":
        return check_find(args, env)
    return None


def check_text(text, bind=True):
    """The first deny reason in `text`, or None. With `bind`, a name assigned a literal earlier in
    `text` resolves to it where that assignment provably ran first (see the header)."""
    toks = Lexer(text).run(0, False)[0]
    cmds = commands(toks)
    bound, frozen = {}, not bind                              # name -> (literal, bound in the current && chain)
    for k, (words, seps) in enumerate(cmds):
        before = joined_by(seps)
        after = joined_by(cmds[k + 1][1]) if k + 1 < len(cmds) else None
        if before != "&&":
            bound = dict((n, v) for n, v in bound.items() if not v[1])     # a chain's bindings end with it
        if "(" in seps or ")" in seps or words[0].text in COMPOUND:
            bound, frozen = {}, True
        r = check_command(words, dict((n, v[0]) for n, v in bound.items()))
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
except Exception as e:                                        # the guard itself broke: FAIL OPEN
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
  4) printf 'eugo-deletion-guard: %s; the command was allowed unchecked\n' "$(printf '%s' "$MSG" | tr '\n\t' '  ')" >&2
     exit 0 ;;
  *) printf 'eugo-deletion-guard: the checker exited %s; the command was allowed unchecked\n' "$RC" >&2
     exit 0 ;;
esac
# The reason travels inside JSON; escape the four characters that could break it.
ESC="$(printf '%s' "$MSG" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  ')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$ESC"
exit 0
