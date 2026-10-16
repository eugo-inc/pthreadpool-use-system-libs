#!/usr/bin/env bash
# §3.43 — the LANE GUARD: a fan-out lane never commits, checks out or resets in the SHARED checkout.
#
# WHY THIS EXISTS. eugo-parallel-fanout-base gives every lane its own scratch folder and tells it to work
# in a clone or worktree there, but that was prompt text: when the lane's clone, worktree or `cd` step
# failed, every later git command ran in whatever checkout the shell was in — and a subagent's Bash call
# STARTS in the main conversation's directory, the shared checkout, because "within a subagent, `cd`
# commands don't persist between Bash or PowerShell tool calls" (code.claude.com/docs/en/sub-agents).
# protomolecule measured three escapes: 2026-09-24 a failed `git worktree add` left the cwd unchanged and
# a lane committed 835 files to the shared branch (b292f3ca1c); 2026-09-27 a verifier detached HEAD and
# mixed-reset the shared index; 2026-09-28 a lane commit swept 172 files of other sessions' uncommitted
# work onto the shared branch (e05ab3fcaa). report:139.
#
# THE MARKER (settled §3.43, 2026-10-13). An environment variable does not survive between a lane's Bash
# calls (each is a fresh shell), so the lane is marked by a FILE the orchestrator writes before the wave,
# `<lane folder>/.eugo-lane`, `key=value` lines:
#     lane_dir=<the lane folder, absolute>          (must name the folder the file sits in, or it is ignored)
#     shared_checkout=<absolute path>                (one or more lines; the checkout lanes must never touch)
#     invocation=<id>   item=<slug>                  (informational)
# and a calling agent is BOUND to that lane by the hook input's `agent_id`, which Claude Code sets on every
# tool call a subagent (Agent tool or Workflow `agent()`) makes: "the input carries the `agent_id` and
# `agent_type` common input fields that identify the subagent" (code.claude.com/docs/en/hooks). The first
# call by an agent that names a path inside a marked lane folder (its literal LANE_DIR, its `cd`, its
# clone target) — or runs with its cwd there — writes the binding; every later call by that agent is
# checked against it, whatever its own text says. A call with NO `agent_id` is the main conversation (the
# orchestrator, whose serial harvest commits ARE the commit path) and is never checked.
#
# WHAT IT REFUSES. For a bound agent, `git commit|checkout|switch|reset|restore|stash|clean` whose target
# resolves to a shared checkout — the hook cwd, moved by each literal `cd`/`pushd` that cannot fail now
# (the target exists), or held where a `cd` that may fail is followed by `;`, a newline, `|`, `&` or `||`
# (a failed cd falls through into the directory the call started in); a `popd` returns to a cwd a `pushd`
# of the same call saved (a fresh shell's stack is empty, so with none it fails and stays). `git -C`
# overrides the directory, and a wrapper is seen through (`nice -n 5 git …`; `env -C D git …` runs in D).
# A repository named by `--git-dir` or `GIT_DIR` (before the command, or exported earlier in the call) that
# is a shared checkout's own is refused wherever the call runs, and so is a work tree (`--work-tree`,
# `GIT_WORK_TREE`, or the cwd under a named repository) inside a shared checkout; `--work-tree` alone still
# commits to the repository found from the cwd. `stash` is also refused in a lane WORKTREE of the shared
# repository: refs/stash is shared by every worktree, so a lane's stash lands on the shared checkout's
# stack. A target that cannot be resolved (an expansion the hook cannot see the value of) is refused too:
# lane prompts write their paths literally (eugo-parallel-fanout-base Step 4). The refusal is
# `permissionDecision: "deny"`, so the call fails and the lane is told why; the reason names the lane
# folder, the shared checkout and the cure.
#
# THE BLOCK RULE (review of 86914c9d4, and the review of that fix). The walk follows every path the call may
# take. A command whose outcome it cannot know (anything but a cd) takes BOTH branches of a following
# `&&`/`||`. A compound command is a SCOPE: an `exit` ends only the paths that reach it, and the paths that
# pass the block by rejoin the walk where it closes — the branch of an `&&`/`||` that does not enter a
# `{ … }`, an `if` condition's other branch (on to `elif`/`else`/`fi`), every path at `do` (a loop may run
# zero times), every path outside a `( … )` subshell or a compound run in a pipeline or behind `&`, and every
# path at a function definition (it runs nothing). A `break` or `continue` takes its path out of its loop
# (`break N`: N loops out; a count it cannot read: the outermost), so an exit later in the body never ends
# it. Only `}` hands its list's outcome to a following `&&`/`||` — inverted after a `!`, which negates the
# whole compound and never its first command; `fi`, `esac`, `)` and `done` forget it (a loop that ran no
# body exits 0, whatever its test did). `return` ends a path only inside a function body (at the top of a
# call bash refuses it and runs on), and an `exit`, `cd` or `break` in a pipeline or behind `&` changes
# nothing. What runs BEFORE a command is walked before it, from the paths that run it: its substitutions —
# `$( … )` (inside double quotes and in a redirect's target too), `<( … )`, `>( … )`, `$(( … ))` — each a
# subshell whose cd and exit never leave it, then its here-document bodies, each walked as a script of its
# own like `bash -c` (a body whose delimiter line is missing is walked as lost structure) when it RUNS: its
# command is a shell, or pipes into one; any other body is DATA (`cat > f`, `git commit -F -`) and is walked
# flat, with no structure and no exit, as before the block rule. `${ … }` is one word whatever operator
# characters it holds, and the `&` or `|` before a `( … )` is still the command's before it. `case` arms are
# modelled coarsely: each arm runs from the paths the `case` started with, an exit ends only its own arm,
# and every starting path survives past `esac` (no arm need match). A quoted or escaped reserved word
# (`'fi'`, `"}"`, `\done`) is a command, never structure; an fd number on a redirect (`} 2>&1`) is not a
# word. Structure the walk cannot follow — a closer with no opener, a `then` outside an `if`, a `;;` outside
# a case arm, a word after a closer — fails CLOSED: every guarded git after it is refused, and no exit ends
# anything.
#
# WHAT IT NEVER DOES. It never checks the main conversation, an agent bound to no lane, or a read (status,
# log, diff, show, rev-parse, add, fetch, worktree add, clone). It is a backstop, not a sandbox: a git
# alias (`git ci`), `xargs git`, `eval`, `env -S`, a script file, a backquoted command, and a cwd set
# through a variable it cannot read (`cd "$D"` with D from `$(…)`) are not followed — the last is refused
# when a guarded git follows it. It walks a loop's body ONCE (a second pass starting where the first left
# off is not walked) and a function's body where it is DEFINED (not where it is called, from that cwd). It
# evaluates no condition and no loop's word list: `if true` and `for i in 1` count as able to go either
# way, so a form whose safety rests on them is refused.
#
# TRANSPORT. Payload on stdin, program on fd 3, verdict by EXIT CODE (0 allow, 3 deny, 4 the checker failed)
# with the one-line reason on stdout — the deletion guard's transport, for its reasons.
#
# Contract (each line is a test in tools/tests/test_lane_guard_hook.py):
#   - every path exits 0 but one; a deny is ONE JSON line on stdout, an allow prints nothing
#   - a payload with no "agent_id", or no `git` word, never starts python
#   - a CRASH in the checker FAILS CLOSED: ONE stderr line and exit 1 (the row carries onFailure: "block");
#     a missing python3 allows with one stderr line
#   - EUGO_LANE_GUARD=off in the HOOK's environment disables it; bindings live under
#     EUGO_LANE_GUARD_STATE (default ${XDG_CACHE_HOME:-$HOME/.cache}/eugo-lane-guard/<session>/<agent>)
#   - it stays ARMED inside a reviewer subprocess (EUGO_REVIEW_SUBPROCESS), like the other two guards
#   - an errexit inherited through BASH_ENV is disarmed first; bash 3.2 safe; the python runs on 3.9+
set +eE +o pipefail
trap - ERR
set -u

if [ "${EUGO_LANE_GUARD:-}" = "off" ]; then
  exit 0
fi
IN="$(cat 2>/dev/null || true)"
case "$IN" in
  *'"agent_id"'*) ;;
  *) exit 0 ;;
esac
# `git` as a WORD; a JSON `\n` / `\t` / `\r` escape before it counts as a boundary, or `cd x\ngit commit` slips past
GIT_WORD='(^|[^A-Za-z0-9_.-]|\\[nrt])git([^A-Za-z0-9_.-]|$)'
[[ $IN =~ $GIT_WORD ]] || exit 0
if ! command -v python3 >/dev/null 2>&1; then
  printf 'eugo-lane-guard: python3 not found; the command was allowed unchecked\n' >&2
  exit 0
fi

verdict() {
  printf '%s' "$IN" | PYTHONUTF8=1 python3 -S /dev/fd/3 3<<'PY' 2>/dev/null
import json, os, re, subprocess, sys

GUARDED = frozenset(("commit", "checkout", "switch", "reset", "restore", "stash", "clean"))
OPS = ("&&", "||", ";;&", ";;", ";&", ";", "|", "&", "\n", "(", ")")
MARKS = ("(", ")", ";;", ";&", ";;&")                         # structure, not a joiner: commands() yields (mark, None)
CONTINUED = ("&", "|", "&&", "||")                             # a joiner a newline right after it does not replace
RESERVED = frozenset(("if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}", "time"))
OPENERS = {"if": "if", "while": "loop", "until": "loop", "for": "loop", "select": "loop", "case": "case", "{": "{"}
CLOSERS = {"fi": "if", "done": "loop", "esac": "case", "}": "{"}
STRUCT = RESERVED | frozenset(OPENERS) | frozenset(CLOSERS) | frozenset(("in", "function"))   # reserved only unquoted
PEEL = frozenset(("command", "builtin", "exec", "nice", "nohup", "sudo", "env", "stdbuf", "ionice", "setsid"))
PEEL_ARG = {"nice": ("-n", "--adjustment"), "ionice": ("-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid",
                                                        "--pgid", "--uid"),
            "sudo": ("-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-T", "-U", "--user", "--group", "--close-from",
                     "--chdir", "--host", "--prompt", "--role", "--type", "--command-timeout", "--other-user"),
            "env": ("-u", "-C", "-S", "--unset", "--chdir", "--split-string"), "exec": ("-a",),
            "stdbuf": ("-i", "-o", "-e", "--input", "--output", "--error"),
            "timeout": ("-s", "-k", "--signal", "--kill-after")}       # a wrapper's options that take an argument
PEEL_CD = {"env": ("-C", "--chdir"), "sudo": ("-D", "--chdir")}       # … and the ones that set its directory
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
FD_RE = re.compile(r"[0-9]+|\{" + NAME + r"\}")                 # `2>`, `{fd}>`: a redirect's own fd, not a word
QW = "\x01"                                                    # marks a quoted reserved word: a command, not structure
HEREDOC = ("<<", "<<?")                                        # a body no command owns; `<<?`: its delimiter is missing
ASSIGN_RE = re.compile(r"(" + NAME + r")=(.*)\Z", re.S)
ABS_RE = re.compile(r"(?<![A-Za-z0-9_.~$-])/[^\s'\";|&()<>`]*")
EXPAND_RE = re.compile(r"\$(?:\{(" + NAME + r")(?::?[?\-=+][^}]*)?\}|(" + NAME + r"))")
GIT_OPT_ARG = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"))
#: §3.43 (b) — `-c KEY=VALUE` keys whose value can move the repository or work tree git acts on, or pull in a config file
#: that can (lowercase; git config keys are case-insensitive): their value must resolve. Any other key's value changes
#: nothing about WHERE git acts, so an expansion in it is no reason to refuse (`git -c user.email="$(…)" commit` in a
#: lane's own clone); its `$( … )` still runs and is still walked (nested()).
CONFIG_REDIRECT = ("core.worktree", "core.bare")
CONFIG_INCLUDE = ("include.", "includeif.")
ENV_OK = ("HOME", "TMPDIR", "USER")
SQ = "\x00"                                                    # a `$` inside single quotes: never expanded


class Unresolved(Exception):
    pass


def heredoc(text, i, delim, strip):
    """(body, index after its delimiter line, whether that line was there) of a here-document whose body starts at i;
    `<<-` strips leading tabs."""
    lines, n = [], len(text)
    while i < n:
        j = text.find("\n", i)
        j = n if j < 0 else j
        line, i = text[i:j], j + 1
        if (line.lstrip("\t") if strip else line) == delim:
            return "\n".join(lines), min(i, n), True
        lines.append(line)
    return "\n".join(lines), min(i, n), False


def paren_end(text, i):
    """The `(` at text[i] opens `$(`, `<(`, `>(` or `((`: (index after its closer, the text inside, arithmetic). `((…))`
    is arithmetic when its two closing parentheses touch; anything else is a command list, lexed to find its `)`."""
    n = len(text)
    if text.startswith("((", i):
        depth, j, one = 0, i, -1
        while j < n:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
                if depth == 1:
                    one = j
                elif depth == 0:
                    if one == j - 1:
                        return j + 1, text[i + 2:j - 1], True
                    break
            j += 1
    j = lex(text, i + 1, True)[1]
    return j, text[i + 1:j - 1] if text[j - 1:j] == ")" and j > i + 1 else text[i + 1:j], False


def brace_end(text, j):
    """`${` opens a parameter expansion whose body starts at text[j]: (index after its `}`, the `$( … )` texts inside
    it), or None when no `}` closes it. Inside, `|`, `;`, `&`, `(`, `)`, `<`, `>` and blanks are part of the expansion,
    never operators (`${v#*|}` read as a pipe made the walk lose its structure: the re-check of e699f5d75); a `$( … )`
    in it still runs."""
    n, depth, subs = len(text), 1, []
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
        elif c == "'":
            q = text.find("'", j + 1)
            if q < 0:
                return None
            j = q + 1
        elif c == '"':                                       # `${v:-"$(git commit)"}`: a substitution in double
            j += 1                                           # quotes runs too (watch review of the §7325 tree)
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 2
                elif text.startswith("$(", j):
                    j, inner, _ = paren_end(text, j + 1)
                    subs.append(inner)
                else:
                    j += 1
            if j >= n:
                return None
            j += 1
        elif text.startswith("$(", j):
            j, inner, _ = paren_end(text, j + 1)
            subs.append(inner)
        else:
            depth += {"{": 1, "}": -1}.get(c, 0)
            j += 1
            if not depth:
                return j, subs
    return None


def tokens(text):
    return lex(text)[0]


def lex(text, i=0, sub=False):
    """([token], index after) — words and operators, quote-aware. A word is ("w", text, quoted), quoted when any of it
    was quoted or escaped; `$` inside '…' becomes SQ. Each command substitution (`$(…)`, in double quotes too), process
    substitution and arithmetic in a word is a ("subst", its text) token BEFORE that word. A here-document's body is ONE
    ("doc", body, delimiter found) token after the newline it starts at, and its delimiter word is followed by
    ("docref",). With `sub`, lexing stops after the `)` that closes a `$(` (nested parentheses and case patterns are
    followed) and returns the index after it."""
    out, n = [], len(text)
    docs, want = [], None                                      # bodies owed at the next newline; a `<<` owed a word
    depth, case, start = 0, [], True                           # sub: open `(`s, case states; at a command's start
    while i < n:
        c = text[i]
        if c in " \t":
            i += 1
            continue
        if c == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
            continue
        if c == "#" :
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("((", i):                           # `(( … ))`: an arithmetic command, no here-document
            j, inner, arith = paren_end(text, i)
            if arith:
                out += [("subst", inner), ("w", text[i:j], True)]
                i, start = j, False
                continue
        op = next((o for o in OPS if text.startswith(o, i)), None)
        if op:
            if sub and op == ")":
                if case and case[-1] == "pat":
                    case[-1] = "body"
                elif depth:
                    depth -= 1
                else:
                    return out, i + 1                          # the `)` that closes the substitution
            elif sub and op == "(" and not (case and case[-1] == "pat"):
                depth += 1
            elif sub and op in (";;", ";&", ";;&") and case and case[-1] == "body":
                case[-1] = "pat"
            out.append(("op", op))
            i, start = i + len(op), True
            if op == "\n":
                for delim, strip in docs:
                    body, i, found = heredoc(text, i, delim, strip)
                    out.append(("doc", body, found))
                docs = []
            continue
        if c in "<>":
            j = i + 1
            while j < n and text[j] in "<>&":
                j += 1
            if text[i:j] in ("<", ">") and j < n and text[j] == "(":     # `<(…)`, `>(…)`: a process substitution
                e, inner, _ = paren_end(text, j)
                out += [("subst", inner), ("w", text[i:e], True)]
                i, start = e, False
                continue
            if text[i:j] == "<<":                                # a here-document (`<<<` is a here-string)
                want = j < n and text[j] == "-"
                j += 1 if want else 0
            out.append(("op", "redir"))
            i = j
            continue
        buf, quoted, subs = [], False, []
        while i < n:
            c = text[i]
            if c in " \t\n;&|()<>" :
                break
            if c == "\\" and i + 1 < n:
                buf.append(text[i + 1])
                quoted = quoted or text[i + 1] != "\n"
                i += 2
            elif c == "'":
                j = text.find("'", i + 1)
                j = n if j < 0 else j
                buf.append(text[i + 1:j].replace("$", SQ))
                quoted, i = True, j + 1
            elif c == '"':
                j = i + 1
                while j < n and text[j] != '"':
                    if text[j] == "\\":
                        j += 2
                    elif text.startswith("$(", j):               # a substitution inside double quotes runs too
                        j, inner, _ = paren_end(text, j + 1)
                        subs.append(inner)
                    else:
                        j += 1
                buf.append(re.sub(r'\\(["\\$`])', r"\1", text[i + 1:j]))
                quoted, i = True, j + 1
            elif c == "$" and text.startswith("$(", i):
                j, inner, _ = paren_end(text, i + 1)
                subs.append(inner)
                buf.append(text[i:j])
                i = j
            elif c == "$" and text.startswith("${", i) and brace_end(text, i + 2) is not None:
                j, inner = brace_end(text, i + 2)            # one word, whatever operator characters it holds
                subs += inner
                buf.append(text[i:j])
                i = j
            else:
                buf.append(c)
                i += 1
        word = "".join(buf)
        if want is None and not quoted and not subs and i < n and text[i] in "<>" and FD_RE.fullmatch(word):
            continue                                             # `2>&1`, `{fd}>f`: part of the redirect
        out += [("subst", s) for s in subs] + [("w", word, quoted)]
        if sub and not quoted:                                   # enough of a case to tell a pattern's `)` apart
            if word == "case" and start:
                case.append("head")
            elif word == "in" and case and case[-1] == "head":
                case[-1] = "pat"
            elif word == "esac" and start and case and case[-1] in ("pat", "body"):
                case.pop()
        start = start and not quoted and word in STRUCT
        if want is not None:                                     # the delimiter word, its quotes removed
            docs.append(("".join(buf).replace(SQ, "$"), want))
            out.append(("docref",))
            want = None
    return out, n


class Words(list):
    """A simple command's words. `subs`: the substitutions in them, which run BEFORE it; `docs`: its here-document
    bodies, [(body, delimiter found)], fed to it before anything later on its line runs."""

    def __init__(self):
        list.__init__(self)
        self.subs, self.docs = [], []


class Cmds(list):
    """commands()'s list. `before[k]`: the operator right before the `(` mark at k, which the mark would otherwise hide
    from nxt() — `cd X & ( git reset --hard )` backgrounds the cd (the re-check of e699f5d75)."""

    def __init__(self):
        list.__init__(self)
        self.before = {}


def commands(text, flat=False):
    """[(joiner, words)] — joiner is the operator BEFORE the simple command, words a Words. A MARKS operator is
    (mark, None); a here-document body no command owns is ("<<", body), ("<<?", body) when its delimiter is missing. A
    quoted or escaped reserved word carries QW, so it is a command and never structure. `flat`: no structure at all —
    the marks are dropped and so is every unquoted reserved word a command starts with (`then git commit` is a git
    command), the walk of a DATA here-document body (nested())."""
    toks = tokens(text)
    bodies = [t[1:] for t in toks if t[0] == "doc"]
    cmds, words, joiner, drop, nref, ndoc = Cmds(), Words(), ";", False, 0, 0
    for t in toks:
        if t[0] == "w":
            if drop:                                           # a redirect's target, a here-document's delimiter
                drop = False
            else:
                words.append(QW + t[1] if t[2] and t[1] in STRUCT else t[1])
            continue
        if t[0] == "subst":                                    # (a redirect target's substitution runs too)
            words.subs.append(t[1])
            continue
        if t[0] == "docref":
            if nref < len(bodies):
                words.docs.append(bodies[nref])
            nref += 1
            continue
        if t == ("op", "redir"):
            drop = True
            continue
        drop = False
        if flat:
            while words and words[0] in STRUCT:                # a reserved word steers nothing in a flat walk
                del words[0]
        pending = bool(words or words.subs or words.docs)
        if pending:
            cmds.append((joiner, words))
            words = Words()
        if t[0] == "doc":
            if ndoc >= nref:                                   # no command owns it
                cmds.append(("<<" if t[2] else "<<?", t[1]))
            ndoc += 1
        elif t[1] in MARKS and flat:
            joiner = ";"
        elif t[1] in MARKS:
            if t[1] == "(" and not pending:
                cmds.before[len(cmds)] = joiner                # `a & ( … )`: the `&` is a's, not the mark's
            fn = t[1] == ")" and bool(cmds) and cmds[-1] == ("(", None)    # `name ()`: a function body follows
            cmds.append((t[1], None))
            joiner = joiner if fn else ";"                 # a case arm's body starts fresh: `echo & case x in
                                                           # x) exit 1;; esac & git …` (escape fuzz, run 1262)
        elif pending or not (t[1] == "\n" and joiner in CONTINUED):
            joiner = t[1]
        # else: a newline RIGHT after `&`, `|`, `&&` or `||` (no command between) is no separator of its own — `a &⏎b`
        # still backgrounds a, and `a |⏎b` / `a &&⏎b` / `a ||⏎b` go on to the next line (review of e699f5d75: the
        # newline overwrote the `&`). In `a & b⏎c` the newline ends b, which runs in the foreground.
    if flat:
        while words and words[0] in STRUCT:
            del words[0]
    if words or words.subs or words.docs:
        cmds.append((joiner, words))
    return cmds


def expand(word, env):
    def sub(m):
        name = m.group(1) or m.group(2)
        if name in env:
            return env[name]
        if name in ENV_OK and os.environ.get(name):
            return os.environ[name]
        raise Unresolved(word)
    word = word.replace(QW, "")
    if "`" in word or "$(" in word or "<(" in word or ">(" in word:
        raise Unresolved(word)
    out = EXPAND_RE.sub(sub, word)
    if "$" in out.replace("$$", ""):
        raise Unresolved(word)
    out = out.replace(SQ, "$")
    if out == "~" or out.startswith("~/"):
        out = os.environ.get("HOME", "~") + out[1:]
    return out


def absol(base, path):
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))


def git(args):
    try:
        r = subprocess.run(["git"] + args, capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def repo_of(path):
    """(toplevel, common dir) of the repository `path` is in, realpath'd; (None, None) when none."""
    top = git(["-C", path, "rev-parse", "--show-toplevel"])
    common = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    return (os.path.realpath(top) if top else None, os.path.realpath(common) if common else None)


def marker_of(path):
    """The lane folder holding `path` (or `path` itself), by its .eugo-lane marker; (lane_dir, shared[])."""
    p = os.path.realpath(path)
    for _ in range(24):
        m = os.path.join(p, ".eugo-lane")
        if os.path.isfile(m):
            info = read_marker(m)
            if info and info[0] == p:
                return info
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent
    return None


def read_marker(m):
    try:
        with open(m, encoding="utf-8") as f:
            lines = f.read(65536).splitlines()
    except OSError:
        return None
    lane, shared = None, []
    for ln in lines:
        k, _, v = ln.partition("=")
        v = v.strip()
        if k.strip() == "lane_dir" and os.path.isabs(v):
            lane = os.path.realpath(v)
        elif k.strip() == "shared_checkout" and os.path.isabs(v):
            shared.append(os.path.realpath(v))
    return (lane, shared) if lane else None


def safe(s):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(s))[:128] or "_"


def binding_file(d):
    root = os.environ.get("EUGO_LANE_GUARD_STATE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.join(os.environ.get("HOME", "/tmp"), ".cache"), "eugo-lane-guard")
    return os.path.join(root, safe(d.get("session_id") or "nosession"), safe(d["agent_id"]))


def candidates(text, cwd):
    """Every absolute path the call names (best effort, expansions it can resolve), then its cwd."""
    seen, env, todo = [], {}, [text]
    while todo:                                                # the call, then the substitutions it holds
        for joiner, words in commands(todo.pop(0)):
            groups = [words or ()]
            if joiner in HEREDOC:                              # a here-document: the paths it names, as written
                groups = [ABS_RE.findall(words)]
            elif words is not None:
                todo += words.subs
                groups += [ABS_RE.findall(body) for body, _ in words.docs]
            for w in (w for g in groups for w in g):
                m = ASSIGN_RE.match(w)
                val = m.group(2) if m else w
                try:
                    val = expand(val, env)
                except Unresolved:
                    continue
                if m:
                    env[m.group(1)] = val
                for part in ABS_RE.findall(val):                 # a `bash -c "cd '/x'; …"` string included
                    if part not in seen:
                        seen.append(part)
                if len(seen) >= 64:
                    return seen + [cwd]
    return seen + [cwd]


def bind(d, text, cwd):
    """The lane this agent is bound to: (lane_dir, shared[]) or None. A first call naming a lane binds it."""
    bf = binding_file(d)
    try:
        with open(bf, encoding="utf-8") as f:
            lane = f.read(4096).strip()
    except OSError:
        lane = None
    if lane:
        info = read_marker(os.path.join(lane, ".eugo-lane"))
        return info if info and info[0] == lane else None   # marker removed: the lane is over
    for path in candidates(text, cwd):
        info = marker_of(path)
        if info:
            try:
                os.makedirs(os.path.dirname(bf), exist_ok=True)
                with open(bf, "w", encoding="utf-8") as f:
                    f.write(info[0] + "\n")
            except OSError:
                pass                                           # unbound next call; THIS call is still checked
            return info
    return None


def inert_config(word, env):
    """A `-c` operand whose KEY reads plainly and cannot redirect the repository (CONFIG_REDIRECT, CONFIG_INCLUDE)."""
    try:
        key = expand(word.split("=", 1)[0], env).strip().lower()
    except Unresolved:
        return False
    return bool(key) and key not in CONFIG_REDIRECT and not key.startswith(CONFIG_INCLUDE)


def git_target(words, cwd, env, genv=None):
    """(subcommand, directory, git dir, work tree) of a git invocation, or None when it is not one. The git dir and work
    tree are what --git-dir / --work-tree (or GIT_DIR / GIT_WORK_TREE in `genv`; a None value is one this guard cannot
    read) name, resolved against the final -C directory as git does; None when nothing names them."""
    genv = genv or {}
    if None in genv.values():
        raise Unresolved("GIT_DIR")
    target, i, gdir, wtree = cwd, 1, genv.get("GIT_DIR"), genv.get("GIT_WORK_TREE")
    while i < len(words):
        w = expand(words[i], env)
        if w in GIT_OPT_ARG and i + 1 < len(words):
            if w == "-c" and inert_config(words[i + 1], env):
                i += 2                                         # §3.43 (b): its value cannot move where git acts
                continue
            val = expand(words[i + 1], env)
            if w == "-C":
                target = absol(target, val)
            elif w == "--work-tree":
                wtree = val
            elif w == "--git-dir":
                gdir = val
            i += 2
            continue
        if w.startswith("--git-dir="):
            gdir = w.split("=", 1)[1]
        elif w.startswith("--work-tree="):
            wtree = w.split("=", 1)[1]
        elif not w.startswith("-"):
            return (w, target, None if gdir is None else absol(target, gdir),
                    None if wtree is None else absol(target, wtree))
        i += 1
    return None


def peel(words, env):
    """Drop assignments and wrapper words; (head, rest, dirs) — head expanded, rest from the head's word on, dirs the
    directories a wrapper runs it in (`env -C D`, `sudo -D D`). A wrapper's option that takes an argument skips it."""
    i, dirs = 0, []
    while i < len(words):
        w = words[i]
        m = ASSIGN_RE.match(w)
        if m:
            i += 1
            continue
        try:
            h = expand(w, env)
        except Unresolved:
            return None, words[i:], dirs
        base = os.path.basename(h)
        if base in RESERVED and not w.startswith(QW):
            i += 1
        elif base in PEEL or base == "timeout":
            i += 1
            while i < len(words) and words[i].startswith("-"):
                opt, eq, val = words[i].partition("=")
                takes = not eq and opt in PEEL_ARG.get(base, ())
                if takes:
                    val = words[i + 1] if i + 1 < len(words) else ""
                cds = PEEL_CD.get(base, ())
                if opt in cds:
                    dirs.append(val)
                elif opt[:2] in cds and not opt.startswith("--"):      # `-C/dir`: attached
                    dirs.append(opt[2:])
                i += 2 if takes else 1
            if base == "timeout":
                i += 1                                       # its duration
        else:
            return base, words[i:], dirs
    return None, [], dirs


class Frame(object):
    """One open compound command: its kind, the states that pass it by, and where its branches stand."""

    def __init__(self, kind, bypass, fn):
        self.kind, self.bypass, self.fn = kind, list(bypass), fn     # fn: a function body — a definition runs nothing
        self.phase, self.loop = None, None
        self.pend, self.done, self.entry, self.carry = [], [], [], []
        self.start, self.piped = [], False                         # the states before it; a pipeline element
        self.neg, self.dirs = False, 0                             # `! { … }`; pushd's stack depth when it opened


CLOSE_PHASES = {"}": (None,), "fi": ("then", "else"), "done": ("body",), "esac": ("pattern", "body")}


def uniq(states):
    out = []
    for s in states:
        if s not in out:
            out.append(s)
    return out


def unknown(states):
    """The states with their outcome forgotten: after a compound command, a subshell, or any command but a cd."""
    return uniq([(c, None) for c, _ in states])


def split(states, joiner):
    """(run, skip) for a command after `joiner`. A state whose outcome this guard cannot know (ok None: any command but
    a cd) took BOTH branches, so it runs the command AND passes it by — as a success past `||`, a failure past `&&`:
    `make || exit 1; git commit` still commits (run 1262 review of 2f8da398b), and `make || cd X; git commit` may
    commit where the call started."""
    if joiner == "&&":
        return [s for s in states if s[1] is not False], [(c, False) for c, ok in states if ok is not True]
    if joiner == "||":
        return [s for s in states if s[1] is not True], [(c, True) for c, ok in states if ok is not False]
    return list(states), []


def collapse(states, frames, start_states):
    """Every state the walk holds, the open frames' included: past structure it lost, any of them may go on."""
    out = list(states) + list(start_states)
    for f in frames:
        out += f.bypass + f.pend + f.done + f.entry + f.carry
    return unknown(out)


def nxt(cmds, k):
    """The joiner of the next command from index k on, past the here-document bodies no command owns; at a `(` mark,
    the operator right before it (Cmds.before)."""
    while k < len(cmds) and cmds[k][0] in HEREDOC:
        k += 1
    if k >= len(cmds):
        return None
    return getattr(cmds, "before", {}).get(k, cmds[k][0])


def list_scan(cmds, k, words=None):
    """Whether the `&&`/`||` list the command before index k belongs to runs as a background job: past it, the first
    joiner at its own nesting level that is not `&&`, `||` or `|` is `&`. A `&` backgrounds the WHOLE list, not its last
    command — `cd X && popd & git reset --hard` resets in the shared checkout (escape fuzz, run 1262). A compound command
    or a `( … )` in the list is stepped over to its closer (`cd X || { echo no; exit 1; }; git …` ends at the `;`);
    `words`, the command's own, counts the compound IT opens (`{ exit 1; } & git …`: the list is the whole group).
    (True / False, or None when the nesting never closes; and the index of the command after the joiner that
    ended the list — for a background list, where the shell goes on)."""
    stack = []                                               # open compounds; a `(` mark pushes "("

    def step(word):                                          # False when it closes a block the list sits in
        if word in OPENERS:
            stack.append(word)
        elif word in CLOSERS:
            if not stack:
                return False
            stack.pop()
        return True

    for word in words or ():
        if word not in STRUCT:
            break
        if word in OPENERS or (word in CLOSERS and stack):
            step(word)
    while k < len(cmds):
        j, w = cmds[k]
        if j in HEREDOC:
            k += 1
            continue
        op = getattr(cmds, "before", {}).get(k, j)
        if not stack and op not in ("&&", "||", "|"):
            return op == "&", k                           # (and the index of the command after it)
        if w is None:
            if j == "(":
                stack.append("(")
            elif j == ")":                                   # a `)` closes only an open `(` — any other is a case
                if stack and stack[-1] == "(":               # pattern's (`case y in y) …`, review of 3ddeb61d1)
                    stack.pop()
                elif not stack:
                    return False, k                          # the `( … )` the list sits in ends
        else:
            for word in w:                                   # the reserved words a command starts with
                if word not in STRUCT:
                    break
                if not step(word):
                    return False, k                          # the list ends inside an enclosing block
        k += 1
    return (None if stack else False), k


def list_bg(cmds, k, words=None):
    """list_scan()'s answer alone: True / False / None."""
    return list_scan(cmds, k, words)[0]


def bg_here(cmds, k, words):
    """list_bg() for a command that may open a compound: when the list that starts INSIDE it (`{ cd X && true & }`) is a
    background one, that is the list its own first command runs in (the review of the §7327 tree); else the list of the
    compound it opens (`{ exit 1; } & git …`)."""
    if words and words[0] in OPENERS:
        inner = list_scan(cmds, k)
        if inner[0] is not False:
            return inner[0]
    return list_scan(cmds, k, words)[0]


def bg_lists(cmds, k, words):
    """Every list that STARTS at the command before index k, as list_scan() pairs, outermost first: at a command that
    opens compounds, the list of each compound it opens (`{ … } &`) and the list that starts inside the last one
    (`{ true & …`). They all begin here, so each must be tracked from here — keeping only the inner one let a cd later
    in the group count past the outer `&` (reviews of 44bf92a3934e and e548d7fac4ed: `cd <shared>; { true & cd <clone>;
    } & git reset --hard` reset the shared checkout)."""
    lead = []
    for word in words or ():
        if word not in STRUCT:
            break
        lead.append(word)
    opens = [i for i, word in enumerate(lead) if word in OPENERS]
    if not opens:
        return [list_scan(cmds, k, words)]
    return [list_scan(cmds, k, words[i:]) for i in opens] + [list_scan(cmds, k, words[len(lead):])]


def moved(states, dirs, env):
    """The states with each cwd moved through `dirs` (a wrapper's `env -C D`); None where a D cannot be read."""
    out = []
    for c, ok in states:
        for d in dirs:
            try:
                c = absol(c, expand(d, env)) if c is not None else None
            except Unresolved:
                c = None
        out.append((c, ok))
    return out


def inside(path, shared):
    """The shared checkout `path` lies in (realpath'd), or None."""
    p = os.path.realpath(path)
    return next((t for t in shared if p == t or p.startswith(t.rstrip(os.sep) + os.sep)), None)


SHELLS = frozenset(("sh", "bash", "dash", "zsh", "ksh", "mksh", "ash", "yash", "fish", "busybox", "source", "."))


def body_runs(words, cmds, k, env):
    """Whether a command's here-document bodies RUN as shell: its head is a shell (or one this guard cannot read), or
    it pipes into one (`cat <<EOF | bash`: the next command's head, likewise). Any other body is DATA — `cat > f`, `git
    commit -F -`, a loop's `done <<EOF` — and is walked flat (the re-check of e699f5d75: prose in a data body, `then` or
    `fi`, made the walk lose its structure and refuse the lane's own commit)."""
    def shellish(ws):
        head, rest, _ = peel(ws, env)
        return head in SHELLS if head is not None else bool(rest)
    if words and shellish(words):
        return True
    while k < len(cmds) and cmds[k][0] in HEREDOC:
        k += 1
    return k < len(cmds) and cmds[k][0] == "|" and cmds[k][1] is not None and shellish(cmds[k][1])


def nested(words, states, shared, shared_commons, lane, depth, lost, pushed, runs=True):
    """The reason, if any, from what runs BEFORE a command, walked from `states`: its substitutions (`$( … )` — in
    double quotes too — `<( … )`, `>( … )`, `$(( … ))`: each a subshell, so no cd or exit of theirs leaves it), then its
    here-document bodies (each a script of its own, like `bash -c`; one whose delimiter line is missing is walked as
    lost structure; when they do not `runs` — body_runs() — walked flat, with no structure and no exit, as this guard
    read every body before the block rule). A substitution inherits the pushd stack `pushed`; a body starts a new one."""
    if not states or words is None:
        return None
    for s in words.subs:
        reason = check(s, unknown(states), shared, shared_commons, lane, depth, lost, pushed)
        if reason:
            return reason
    for body, found in words.docs if depth < 4 else ():
        why = lost if lost is not None or found or not runs else "a here-document whose delimiter line is missing"
        reason = check(body, unknown(states), shared, shared_commons, lane, depth + 1, why, flat=not runs)
        if reason:
            return reason
    return None


def check(text, start_states, shared, shared_commons, lane, depth=0, lost=None, pushed=None, flat=False):
    """Walk the call; the reason string for the first guarded git that may run in a shared checkout.

    A compound command is a SCOPE (the header's THE BLOCK RULE). `frames` holds the open ones, each keeping the
    states that pass it by; they rejoin the walk where it closes, so an exit inside a block ends only the states that
    reached it. `lost` names the first structure the walk could not follow: past it every guarded git is refused and
    no exit ends anything."""
    states = list(start_states)                              # [(cwd or None, ok: True/False/None)]
    frames, env, fundef, cmds, k = [], {}, False, commands(text, flat), 0
    dirstack, gitenv = [list(d) for d in pushed or ()], {}   # pushd's saved cwds; an exported GIT_DIR / GIT_WORK_TREE
    bg_open = []                                             # open background lists: (the states each began from,
                                                             # the index of the command after its own `&`)
    while k < len(cmds):
        joiner, words = cmds[k]
        k += 1
        blk = frames[-1] if frames else None
        if joiner not in HEREDOC:
            # A list behind a `&` runs in a subshell of its own: inside it every command runs in order (a cd in it
            # moves the commands after it IN the list), and at the `&` the shell goes on from the states the list
            # began with (the review of §7326's tree: `cd <shared> && git commit &` commits in the shared checkout)
            # Each list ends at the `&` at ITS OWN nesting level — an inner `{ true & }` does not end it (the review
            # of §7327: `cd <shared> && { true & } && git commit &` committed in the shared checkout). A command that
            # opens a group starts the group's list AND the one inside it: both open here, the outer first so the
            # inner, which ends sooner, sits on top (bg_lists(); a list seen again at the `}` is already open)
            while bg_open and k - 1 >= bg_open[-1][1]:
                states = unknown(bg_open.pop()[0])
            for found, ends in bg_lists(cmds, k, words):
                if found is True and all(e != ends for _, e in bg_open):
                    bg_open.append((list(states), ends))
        if joiner in HEREDOC:                                # a here-document no command owns: a script of its own
            if depth < 4 and states:
                why = lost if lost is not None or joiner == "<<" else "a here-document whose delimiter line is missing"
                reason = check(words, unknown(states), shared, shared_commons, lane, depth + 1, why)
                if reason:
                    return reason
            continue
        if words is None:
            if joiner == "(" and k < len(cmds) and cmds[k] == (")", None):
                k += 1                                       # `name ()`: a function body follows
                fundef = True
            elif joiner == "(":
                in_case = blk is not None and blk.kind == "case" and blk.phase in ("head", "pattern")
                if not in_case or blk.phase != "pattern":    # else a pattern's optional `(`
                    f = Frame("(", [], fundef)
                    f.entry, f.dirs, fundef = list(states), len(dirstack), False
                    frames.append(f)
            elif joiner == ")" and blk is not None and blk.kind == "(":
                frames.pop()
                del dirstack[blk.dirs:]
                states = unknown(blk.entry)                  # a subshell's cd and exit never leave it
            elif joiner == ")" and blk is not None and blk.kind == "case" and blk.phase == "pattern":
                blk.phase, states = "body", unknown(blk.entry + blk.carry)    # an arm runs from the case's entry
            elif joiner != ")" and blk is not None and blk.kind == "case" and blk.phase == "body":
                blk.done += states                           # `;;` ends the arm; `;&` and `;;&` carry it on
                blk.carry = [] if joiner == ";;" else list(states)
                blk.phase, states = "pattern", []
            else:
                if lost is None:
                    lost = "a `%s` that belongs to no compound command" % joiner
                states, frames = collapse(states, frames, start_states), []
            continue
        cmd = words                                          # the Words: what runs before it rides on it
        if blk is not None and blk.kind == "case" and blk.phase in ("head", "pattern"):
            if blk.phase == "head" and "in" in words:
                blk.phase, words = "pattern", words[words.index("in") + 1:]
            if blk.phase != "pattern" or not words or words[0] != "esac":
                reason = nested(cmd, unknown(blk.entry), shared, shared_commons, lane, depth, lost, dirstack,
                                body_runs(cmd, cmds, k, env))
                if reason:                                   # a case's word and patterns expand from its entry
                    return reason
                continue                                     # the case's word, or a pattern: nothing runs
        i, began = 0, []
        while i < len(words) and words[i] in CLOSERS:        # `}`, `fi`, `done`, `esac` (`fi }` closes two)
            w, blk = words[i], (frames[-1] if frames else None)
            i += 1
            if blk is None or blk.kind != CLOSERS[w] or blk.phase not in CLOSE_PHASES[w]:
                if lost is None:
                    lost = "a `%s` that closes nothing" % w
                states, frames = collapse(states, frames, start_states), []
                continue
            frames.pop()
            began += blk.start
            if blk.piped or blk.fn or (i == len(words) and nxt(cmds, k) in ("|", "&")):
                del dirstack[blk.dirs:]                      # a subshell's pushd never leaves it
            if blk.piped or (i == len(words) and nxt(cmds, k) in ("|", "&")):
                states = unknown(blk.start)                  # a pipeline element or a background job: a subshell
                continue
            if w == "fi":
                states = blk.done + states + blk.pend
            elif w == "esac":
                states = blk.done + (states if blk.phase == "body" else []) + blk.entry
            elif w == "}" and not blk.fn:                    # `{ list; }` ends as its list did, `! { list; }` inverted
                if blk.neg:
                    states = [(c, None if ok is None else not ok) for c, ok in states]
                states = uniq(states + blk.bypass)
                continue
            states = unknown(states + blk.bypass)            # `done`: a loop that ran no body exits 0, not as its test
        if i:
            if i < len(words):
                if lost is None:
                    lost = "`%s` after `%s`" % (words[i], words[i - 1])
                states, frames = collapse(states, frames, start_states), []
            reason = nested(cmd, uniq(began + states), shared, shared_commons, lane, depth, lost, dirstack,
                            body_runs(cmd, cmds, k, env))
            if reason:                                       # `done < <(…)`: a closer's redirect
                return reason
            continue
        run, skip = split(states, joiner)
        before, piped = states, joiner == "|"
        states, i, neg = run, 0, False
        while i < len(words):                                # the reserved words that open or steer a compound
            w, blk = words[i], (frames[-1] if frames else None)
            if w in OPENERS:
                f = Frame(OPENERS[w], skip + (states if fundef else []), fundef)
                f.start, f.piped, f.neg, f.dirs = list(before), piped, neg, len(dirstack)
                skip, fundef, before, piped, neg = [], False, states, False, False      # `! {`: the block's, not
                frames.append(f)                                                     # its first command's
                i += 1
                if f.kind in ("if", "loop"):
                    f.phase, f.loop = "cond", w
                    if w in ("for", "select"):
                        i = len(words)                       # `for NAME in WORDS`: a header, not a command
                elif f.kind == "case":
                    after = words[i + 1:]                    # past the case's WORD
                    f.entry, f.phase, i = list(states), "head", len(words)
                    if "in" in after:
                        f.phase, after = "pattern", after[after.index("in") + 1:]
                        if after and after[0] == "esac":    # `case x in esac`: no arms at all
                            frames.pop()
                            states = unknown(f.entry + f.bypass)
                continue
            if w in ("then", "elif", "else", "do"):
                need = ("loop", ("cond",)) if w == "do" else ("if", ("cond",) if w == "then" else ("then",))
                if blk is None or blk.kind != need[0] or blk.phase not in need[1]:
                    if lost is None:
                        lost = "a `%s` outside its compound command" % w
                    states, frames = collapse(states, frames, start_states), []
                elif w == "then":
                    states, blk.pend = split(states, "&&")   # the condition's other branch waits for elif/else/fi
                    blk.phase = "then"
                elif w == "do":
                    blk.bypass += states                     # a loop body may run zero times
                    if blk.loop in ("while", "until"):
                        states = split(states, "&&" if blk.loop == "while" else "||")[0]
                    blk.phase = "body"
                else:                                        # `elif` / `else`: the branch so far is done
                    blk.done += states
                    states, blk.pend = blk.pend, []
                    blk.phase = "cond" if w == "elif" else "else"
                i += 1
                continue
            if w == "!":
                neg = True
            elif w == "function" and i + 1 < len(words):
                fundef = True
                i += 1                                       # its name
            elif w != "time":
                break
            i += 1
        reason = nested(cmd, states, shared, shared_commons, lane, depth, lost, dirstack,   # once the joiner lets it
                        body_runs(cmd, cmds, k, env))
        if reason:
            return reason
        words = words[i:]
        if words:
            fundef = False                                   # a simple command: no function body is pending
        if not words or not states:
            states = uniq(skip + states)
            continue
        for w in words:
            m = ASSIGN_RE.match(w)
            if not m:
                break
            try:
                env[m.group(1)] = expand(m.group(2), env)
            except Unresolved:
                env.pop(m.group(1), None)
        head, rest, dirs = peel(words, env)
        bgk = bg_here(cmds, k, cmd)                              # its `&&`/`||` list behind a `&`: True/False/None
        alone = joiner == "|" or nxt(cmds, k) in ("|", "&")     # a pipeline element / background job
        if head in ("break", "continue") and lost is None and not alone and bgk is False:
            loops = []                                       # the loops it can leave: not past a subshell's edge
            for f in reversed(frames):
                if f.kind == "loop":
                    loops.append(f)
                if f.kind == "(" or f.fn or f.piped:
                    break
            if loops:                                        # `break N`; a count it cannot read: the outermost
                arg = rest[1] if len(rest) > 1 else "1"
                n = int(arg) if arg.isdigit() and int(arg) > 0 else len(loops)
                loops[min(n, len(loops)) - 1].bypass += states   # it leaves the loop (`continue`: through the test)
                states = uniq(skip)
                continue
        if head in ("exit", "return"):
            # `cd X || exit` — only the cd's success goes on. An exit ends ONLY the states that reach it: the other
            # branch of an `||`/`&&` is in `skip` (a state of unknown outcome took both — split()), every state that
            # passed an enclosing block by waits in its frame and rejoins where the block closes — `make || { echo x;
            # exit 1; }; git commit` still commits (review of 86914c9d4) — and a state that left a loop by `break` or
            # `continue` waits in the loop's frame. It ends nothing when it runs in a subshell of its own (a pipeline
            # element, a background job; `( … )` is a frame, and a substitution is a walk of its own — nested()),
            # when `return` is outside every function body (bash refuses it and runs on), or once the walk has lost
            # the structure. `return None` only when no state is left AND no block is open.
            if (lost is None and not alone and not flat and bgk is False     # in a background list: its subshell
                    and (head == "exit" or any(f.fn for f in frames))):
                states = uniq(skip)
                if not states and not frames:
                    return None                                  # nothing after this point can run
                continue
        if head in ("cd", "pushd", "popd") and not alone:        # a cd in a subshell of its own moves nothing
            args = [a for a in rest[1:] if not a.startswith("-") or a == "-"]
            new = []
            if head == "popd" or (head == "pushd" and (not args or args[0][:1] == "+")):
                # popd returns to a cwd some pushd of this call saved (any of them: a pushd that failed saved nothing),
                # or fails and stays — every call is a fresh shell, so with no pushd seen it fails ("directory stack
                # empty"); a popd or pushd that rotates the stack (`+N`, no directory) leaves the cwd unknown
                back = uniq([p for saved in dirstack for p in saved]) if head == "popd" and not args else [None]
                if head == "popd" and dirstack and not args:
                    dirstack.pop()
                for c, _ in states:
                    new += [(p, True) for p in back] + [(c, False)]
            else:
                if head == "pushd":
                    dirstack.append([c for c, _ in states])
                for c, _ in states:
                    try:
                        dest = expand(args[0], env) if args else os.environ.get("HOME", "/")
                        dest = None if dest == "-" else absol(c or "/", dest)
                    except Unresolved:
                        dest = None
                    if dest is not None and c is not None and os.path.isdir(dest):
                        new.append((dest, True))
                    else:
                        new.append((dest, True))                # the success branch
                        new.append((c, False))                   # the failure branch: cwd unchanged
            if neg:                                              # `! cd X`: its outcome, inverted
                new = [(c, None if ok is None else not ok) for c, ok in new]
            if flat or bgk is None:                              # a flat walk cannot tell whether the cd ran (its
                new += [(c, None) for c, _ in states]            # `if` is gone): it keeps the cwd it moved from, so
            states = uniq(skip + new)                            # it is never more permissive than the structured
            continue                                             # walk (review of af8344a18)
        if head == "export" and not alone:                       # an exported GIT_DIR / GIT_WORK_TREE moves later gits
            for a in rest[1:]:
                m = ASSIGN_RE.match(a)
                if m and m.group(1) in ("GIT_DIR", "GIT_WORK_TREE"):
                    try:
                        gitenv[m.group(1)] = expand(m.group(2), env)
                    except Unresolved:
                        gitenv[m.group(1)] = None
        if head in ("bash", "sh", "zsh", "dash") and "-c" in rest and depth < 4:
            ci = rest.index("-c")
            if ci + 1 < len(rest):
                try:
                    inner = expand(rest[ci + 1], env)
                except Unresolved:
                    inner = rest[ci + 1].replace(SQ, "$")
                reason = check(inner, unknown(moved(states, dirs, env)), shared, shared_commons, lane, depth + 1, lost)
                if reason:
                    return reason
            states = uniq(skip + unknown(states))
            continue
        if head == "git":
            pre = {}                                             # GIT_DIR=… git …: for this command alone
            for w in words[:len(words) - len(rest)]:
                m = ASSIGN_RE.match(w)
                if m and m.group(1) in ("GIT_DIR", "GIT_WORK_TREE"):
                    try:
                        pre[m.group(1)] = expand(m.group(2), env)
                    except Unresolved:
                        pre[m.group(1)] = None
            genvs = [pre] if pre else [{}] + ([dict(gitenv)] if gitenv else [])   # an export may not have run
            if lost is not None:
                try:
                    got = git_target(rest, "/", env)
                except Unresolved:
                    got = (next((w for w in rest[1:] if w in GUARDED), None),)
                if got is not None and got[0] in GUARDED:
                    return deny(got[0], lane, shared, "it follows %s, a shape this guard cannot follow" % lost)
            for (c, _), genv in ((s, g) for s in moved(states, dirs, env) for g in genvs):
                try:
                    got = git_target(rest, c or "/", env, genv) if c is not None else ("?", None, None, None)
                except Unresolved:
                    got = ("?", None, None, None)
                if not got:
                    continue
                sub, target, gdir, wtree = got
                if sub == "?":
                    sub = next((w for w in rest[1:] if w in GUARDED), None)
                    if sub is None:
                        continue
                    return deny(sub, lane, shared, "its directory comes from an expansion this guard cannot read")
                if sub not in GUARDED:
                    continue
                if c is None or target is None:
                    return deny(sub, lane, shared, "its directory comes from an expansion this guard cannot read")
                if not os.path.isdir(target):
                    continue                                     # git cannot enter it: the command fails alone
                if gdir is not None and os.path.realpath(gdir) in shared_commons:
                    return deny(sub, lane, shared, "its repository %s is the shared checkout's" % gdir)
                wt = wtree if wtree is not None else (target if gdir is not None else None)
                hit = inside(wt, shared) if wt is not None else None
                if hit:                                          # --work-tree / GIT_WORK_TREE, or a cwd under GIT_DIR
                    return deny(sub, lane, shared, "its work tree %s is inside the shared checkout %s" % (wt, hit))
                if gdir is not None:
                    continue                                     # the repository is named: nothing is discovered
                top, common = repo_of(target)
                if top and top in shared:
                    why = ("it runs in %s" % c) if c == target else ("its target is %s" % target)
                    return deny(sub, lane, shared, why + ", inside the shared checkout %s" % top)
                if sub == "stash" and common and common in shared_commons:
                    return deny(sub, lane, shared, "refs/stash is shared by every worktree of %s" % common)
        states = uniq(skip + unknown(states))
    return None


def deny(sub, lane, shared, why):
    return ("eugo-lane-guard: refused `git %s` — this agent is fan-out lane %s (marker %s/.eugo-lane) and %s. "
            "A failed clone, worktree or cd falls through into the directory the call started in, and a "
            "subagent's every Bash call starts in the shared checkout. Work only in the lane's own copy: "
            "`cd '%s/clone' || exit 1; git …` or `git -C '%s/clone' …` (a worktree lane: its worktree path) — §3.43."
            % (sub, lane, lane, why, lane, lane))


raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or d.get("tool_name") != "Bash" or not isinstance(d.get("agent_id"), str) \
        or not d["agent_id"]:
    sys.exit(0)
ti = d.get("tool_input")
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(0)
try:
    cwd = d.get("cwd") if isinstance(d.get("cwd"), str) and os.path.isabs(d["cwd"]) else os.getcwd()
    info = bind(d, cmd, cwd)
    if not info:
        sys.exit(0)
    lane, shared_list = info
    shared = set()
    for s in shared_list + [p for p in (os.environ.get("CLAUDE_PROJECT_DIR"),) if p]:
        top, _ = repo_of(s) if os.path.isdir(s) else (None, None)
        shared.add(top or os.path.realpath(s))
    shared_commons = {c for c in (repo_of(s)[1] for s in shared if os.path.isdir(s)) if c}
    shared_commons |= {os.path.realpath(g) for g in (git(["-C", s, "rev-parse", "--absolute-git-dir"])
                                                     for s in shared if os.path.isdir(s)) if g}   # their own git dirs
    reason = check(cmd, [(cwd, None)], shared, shared_commons, lane)
except SystemExit:
    raise
except Exception as e:
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
  4) printf 'eugo-lane-guard: %s, so this command was not checked; exit 1: blocked where the row carries onFailure:block (Claude Code 2.1.295+) — split or simplify it\n' "$(printf '%s' "$MSG" | tr '\n\t' '  ')" >&2
     exit 1 ;;
  *) printf 'eugo-lane-guard: the checker exited %s; the command was allowed unchecked\n' "$RC" >&2
     exit 0 ;;
esac
ESC="$(printf '%s' "$MSG" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  ')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$ESC"
exit 0
