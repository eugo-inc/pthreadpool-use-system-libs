#!/usr/bin/env bash
# §2981 — the PUBLISH GUARD: external publication is a human step (central §publish-manual).
#
# WHY THIS EXISTS. A session that finds a defect in third-party software may DRAFT the
# report, PR or comment, but never POST it: the operator reviews every outbound text for
# internal details and is accountable for what the org publishes. Prose said so nowhere
# until §2978, and the central instructions actively authorised external writes. This hook
# is the mechanical backstop for the honest mistake — a skill that says "file an upstream
# issue", a vendored pack that says "file a bug to PyTorch".
#
# WHAT IT DOES. On `PreToolUse` it inspects a Bash command (matcher `Bash`) or a GitHub
# MCP write call (matcher `mcp__github__.*`, registered with `--mcp`). A WRITE VERB whose
# target owner is POSITIVELY resolved to lie outside the publish allowlist does not run
# unasked: the hook answers `permissionDecision: "ask"`, so an interactive operator sees
# the exact command and approves or rejects it, and an unattended / headless session
# never publishes. PROBED 2026-09-19: "ask" stopped the command with Bash pre-allowed AND
# under `--permission-mode bypassPermissions`; the reason text reached the model; the
# negative control ran.
#
# WHAT IT NEVER DOES. It never blocks a READ (`gh api` reads are a standing research
# duty), never an org write, and never a write whose owner it cannot resolve: replayed
# over every write-verb command in this box's transcripts (703 runs: 614 bare `git push`,
# 82 explicit eugo-inc, 6 shell-variable targets, 1 false text match, 0 outside owners) it
# asks ZERO times. Wrappers are peeled by BASENAME (`/bin/bash -c`, `timeout --signal=KILL 30`),
# a literal `cd` moves the checkout the remotes are read from, and an `ssh://host:port/` URL resolves.
# A `gh gist create` and a `git send-email` publish under a personal identity and are
# asked always. It is a backstop, not a sandbox: `curl -X POST api.github.com`, `glab`,
# `xargs gh`, a script file that calls gh, are not parsed — the central rule names them.
#
# TRANSPORT. Payload on stdin, program on fd 3, verdict by EXIT CODE (0 pass, 3 ask) with
# the reason on stdout — never argv (a 128 KiB command would E2BIG and fail OPEN) and never
# a heredoc inside `$(…)` (bash 3.2's paren/quote scanning).
#
# Contract (each line is a test in tools/tests/test_external_publish_guard_hook.py):
#   - every path exits 0; a verdict of "ask" is ONE JSON line on stdout, else stdout empty
#   - nothing on stderr, never a traceback
#   - EVERY line of a multi-line command is classified (a newline is a separator; a
#     trailing backslash joins a continuation; `if … then` / `do` / `else` prefixes are
#     peeled) — the repo's own commit ritual puts `git push` on its own line
#   - reads pass; org writes pass; unresolvable-owner writes pass; outside writes ASK;
#     gist create / send-email ASK; `--dry-run` push passes; quoted strings and heredoc
#     bodies are never commands; an env assignment inline (`EUGO_PUBLISH_ORGS=x gh …`) is
#     not honoured — the allowlist is the hook's OWN environment plus the committed file
#   - allowlist = EUGO_PUBLISH_ORGS (space/comma; default `eugo-inc`) + the lines of
#     .claude/data/publish-allowlist.txt AS OF HEAD (an uncommitted edit has no effect)
#   - a checkout with a remote outside the allowlist and no explicit -R on a gh write ASKS
#     (gh may default to the upstream parent of a fork)
#   - malformed stdin, no python3, no git -> silent pass; bash 3.2 safe
#   - an errexit INHERITED through BASH_ENV is disarmed first: the eugo deploy image's /usr/local/etc/bash_env
#     turns on `set -eE -o pipefail` + an ERR trap, and under it `MSG="$(verdict)"` died with the ask's own
#     exit 3 before the JSON printed — a non-2 exit is non-blocking, so the write ran UNASKED (measured
#     2026-09-23 in the gb10-extended lap image; reached whenever Claude Code runs inside the devcontainer)
set +eE +o pipefail
trap - ERR
set -u

IN="$(cat 2>/dev/null || true)"
if [ -z "$IN" ]; then
  exit 0
fi
# Cheap pre-filter: the common Bash call never starts python.
case "$IN" in
  *'gh '*|*'"gh"'*|*git*push*|*git*send-email*|*mcp__github__*) ;;
  *) exit 0 ;;
esac
command -v python3 >/dev/null 2>&1 || exit 0

ORGS="${EUGO_PUBLISH_ORGS:-eugo-inc}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"

verdict() {
  printf '%s' "$IN" | PG_ORGS="$ORGS" PG_ROOT="$ROOT" PYTHONUTF8=1 python3 -S /dev/fd/3 3<<'PY' 2>/dev/null
import json, os, re, shlex, subprocess, sys

ALLOW_FILE = ".claude/data/publish-allowlist.txt"
DRAFTS = ".claude/data/external-drafts/<YYYY-MM-DD>-<slug>.md"
GH_ISSUE_W = {"create", "comment", "edit", "close", "reopen", "transfer", "delete", "lock", "unlock", "pin", "unpin", "develop"}
GH_PR_W = {"create", "comment", "review", "merge", "edit", "close", "reopen", "ready", "lock", "unlock", "update-branch"}
GH_RELEASE_W = {"create", "edit", "delete", "upload", "delete-asset"}
GH_GIST_W = {"create", "edit", "delete", "rename"}
MCP_W = {"create_issue", "create_pull_request", "add_issue_comment", "update_issue", "create_or_update_file",
         "push_files", "fork_repository", "create_branch", "merge_pull_request", "update_pull_request",
         "create_pull_request_review", "submit_pull_request_review", "add_pull_request_review_comment",
         "delete_file", "create_repository", "request_copilot_review", "assign_copilot_to_issue",
         "dismiss_notification", "mark_all_notifications_read", "manage_notification_subscription"}
MCP_W_PREFIX = ("create_", "add_", "update_", "delete_", "push_", "merge_", "fork_", "submit_", "request_",
                "assign_", "dismiss_", "manage_", "mark_")
# LOCAL PATCH 2026-09-23 (Ben: "Patch locally + send to athena"): the github MCP server's consolidated tools are
# named by SUFFIX (`issue_write`, `pull_request_review_write`, `sub_issue_write`), which no prefix above matches, so
# all three passed UNASKED. Guard: protomolecule packages/tests/unit/test_the_publish_guard_asks_before_every_github_write_tool.py.
MCP_W_SUFFIX = ("_write",)


def allowlist(cwd):
    out = {t.strip().lower() for t in re.split(r"[\s,]+", os.environ.get("PG_ORGS", "")) if t.strip()}
    for root in (cwd, os.environ.get("PG_ROOT") or "."):
        try:
            r = subprocess.run(["git", "-C", root, "show", "HEAD:" + ALLOW_FILE],
                               capture_output=True, text=True, timeout=5)
        except Exception:
            continue
        if r.returncode == 0:
            for ln in r.stdout.splitlines():
                ln = ln.split("#", 1)[0].strip().lower()
                if ln:
                    out.add(ln)
            break
    return out


def owner_of_url(u):
    m = re.match(r"(?:git@|ssh://git@|ssh://|https?://(?:[^@/]+@)?)([\w.-]+)(?::\d+)?[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$", u.strip())
    if not m:
        m = re.match(r"https?://(?:[^@/]+@)?([\w.-]+)/([\w.-]+)/([\w.-]+)", u.strip())
        if not m:
            return None
    host, owner = m.group(1).lower(), m.group(2).lower()
    return owner if host in ("github.com", "api.github.com") else f"{host}/{owner}"


def owner_of_repo_arg(v):
    v = v.strip()
    if "://" in v or v.startswith("git@"):
        return owner_of_url(v)
    parts = v.split("/")
    if len(parts) == 2:
        return parts[0].lower()
    if len(parts) == 3:
        host = parts[0].lower()
        return parts[1].lower() if host == "github.com" else f"{host}/{parts[1].lower()}"
    return None


def strip_heredocs(cmd):
    out, i = [], 0
    for m in re.finditer(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n(.*?)\n\2\s*$", cmd, re.S | re.M):
        out.append(cmd[i:m.start(3)]); i = m.end(3)
    out.append(cmd[i:])
    return "".join(out)


def tokens(line):
    """One LINE of shell into tokens. shlex treats a newline as WHITESPACE, never as a
    separator — measured 2026-09-19 (the HANDOFF-publish-guard-newline-bypass hand-over):
    `echo hi\ngit push origin main` came back as ONE segment whose argv[0] was `echo`, so
    a write on any line but the first was never classified. Lines are split BEFORE this
    runs (`lines_of`); an unbalanced quote falls back to a plain whitespace split of that
    same line, so the fallback examines the same line, never fewer."""
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return line.split()


def lines_of(cmd):
    """Physical command lines after heredoc bodies are gone: a trailing backslash joins a
    continuation, everything else splits on the newline the tokenizer would swallow."""
    return [ln for ln in re.sub(r"\\\n", " ", cmd).split("\n") if ln.strip()]


# `(` and `)` are NOT separators: shlex splits them out of `v$(cat VERSION)` too, so treating
# them as segment ends severed `-R foo/bar` from its write (review verdict on 5fd774a6). A bare
# `(` opening a subshell is peeled as a wrapper instead, and a bare `)` is DROPPED here: left in
# argv it became the push's positional target (`(git push)` -> `rem.get(")")` -> None -> pass;
# review verdict on f5228e32). No classifier reads a `)`, so dropping it can only add inspection.
_SEPARATORS = (";", "&", "&&", "||", "|", "|&", ";;", "{", "}")


def segments(toks):
    seg, out = [], []
    for t in toks:
        if t == ")":
            continue
        if t in _SEPARATORS:
            if seg:
                out.append(seg)
            seg = []
        else:
            seg.append(t)
    if seg:
        out.append(seg)
    return out


def peel(seg):
    """Skip leading assignments and wrappers; return (argv, inline_env)."""
    env = {}
    i = 0
    while i < len(seg):
        t = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            k, v = t.split("=", 1); env[k] = v; i += 1; continue
        if t in ("sudo", "env", "command", "time", "nice", "nohup", "(", "{",
                 "then", "do", "else", "elif", "if", "while", "until", "!"):
            i += 1; continue     # shell keywords that precede a command on the same line
        if t == "timeout":
            i += 1
            while i < len(seg) and seg[i].startswith("-"):          # --signal=KILL, -k 5, --preserve-status
                i += 2 if seg[i] in ("-s", "--signal", "-k", "--kill-after") else 1
            i += 1                                                  # the duration
            continue
        break
    return seg[i:], env


def gh_owner(argv, env, cwd):
    for j, t in enumerate(argv):
        if t in ("-R", "--repo") and j + 1 < len(argv):
            return owner_of_repo_arg(argv[j + 1]), True
        if t.startswith("--repo="):
            return owner_of_repo_arg(t.split("=", 1)[1]), True
        if t.startswith("-R") and len(t) > 2:
            return owner_of_repo_arg(t[2:]), True
    for t in argv:
        if "github.com/" in t:
            o = owner_of_url(t) or owner_of_url(t.split("#")[0])
            if o:
                return o, True
    if "GH_REPO" in env:
        return owner_of_repo_arg(env["GH_REPO"]), True
    return None, False


def remotes(cwd, git_c):
    root = git_c or cwd
    try:
        r = subprocess.run(["git", "-C", root, "remote", "-v"], capture_output=True, text=True, timeout=5)
    except Exception:
        return {}
    out = {}
    for ln in r.stdout.splitlines():
        parts = ln.split()
        if len(parts) >= 2:
            out.setdefault(parts[0], owner_of_url(parts[1]))
    return out


def api_write(argv):
    method = None
    fields = False
    for j, t in enumerate(argv):
        if t in ("-X", "--method") and j + 1 < len(argv):
            method = argv[j + 1].upper()
        elif t.startswith("--method="):
            method = t.split("=", 1)[1].upper()
        elif t.startswith("-X") and len(t) > 2:
            method = t[2:].upper()
        elif t in ("-f", "-F", "--field", "--raw-field", "--input") or t.startswith(("--field=", "--raw-field=", "--input=")):
            fields = True
    if method:
        return method in ("POST", "PATCH", "PUT", "DELETE")
    return fields


def api_owner(argv):
    for t in argv:
        s = re.sub(r"^https?://api\.github\.com/", "", t).lstrip("/")
        m = re.match(r"(?:repos|orgs)/([\w.{}-]+)/", s)
        if m and "{" not in m.group(1):
            return m.group(1).lower()
    return None


def ask(reason):
    print(reason)
    sys.exit(3)


def check_bash(cmd, cwd):
    allow = allowlist(cwd)
    cmd = strip_heredocs(cmd)
    cur = cwd                                   # follows a literal `cd`, so remotes are read where gh/git will run
    for seg in [s for ln in lines_of(cmd) for s in segments(tokens(ln))]:
        git_c = None                            # per segment: `git -C /a push; git push` reads /a then `cur` (§2989 dropped
        argv, env = peel(seg)                   # this reset; the by-name push then raised UnboundLocalError -> fail-open)
        if not argv:
            continue
        base = os.path.basename(argv[0])
        if base in ("bash", "sh", "zsh", "dash", "ksh") and "-c" in argv[:3]:
            k = argv.index("-c")
            if k + 1 < len(argv):
                check_bash(argv[k + 1], cwd)
            continue
        if base == "cd" and len(argv) >= 2 and not argv[1].startswith(("$", "~")):
            cur = argv[1] if os.path.isabs(argv[1]) else os.path.join(cur, argv[1])   # a literal cd persists for the rest of the command
            continue
        if base == "gh" and len(argv) >= 2:
            sub = argv[1]
            verb = argv[2] if len(argv) >= 3 else ""
            write = False
            if sub == "gist" and verb in GH_GIST_W:
                ask("external publication is a human step (§publish-manual): `gh gist %s` publishes under a personal "
                    "identity, outside the org. Approve only if the operator named this draft and asked to publish it; "
                    "otherwise draft it to %s and hand the path over via AskUserQuestion." % (verb, DRAFTS))
            if (sub == "issue" and verb in GH_ISSUE_W) or (sub == "pr" and verb in GH_PR_W) or \
               (sub == "release" and verb in GH_RELEASE_W) or (sub == "repo" and verb == "fork"):
                write = True
            elif sub == "api":
                if not api_write(argv[2:]):
                    continue
                path = next((t for t in argv[2:] if not t.startswith("-") and t != "graphql"), "")
                if any(t == "graphql" or t.endswith("/graphql") for t in argv[2:]):
                    if not re.search(r"\bmutation\b", cmd):
                        continue
                    # A GraphQL mutation names no owner in its path; it is a write whose
                    # target this hook cannot read, and mutations are rare (0 in the
                    # 703-command corpus) — so ask, the one exception to "unresolvable passes".
                    ask("external publication is a human step (§publish-manual): `gh api graphql` carries a mutation "
                        "whose target repository this guard cannot resolve. Approve only if it writes to an org repo "
                        "or the operator asked for it; otherwise draft it to %s and hand the path over via "
                        "AskUserQuestion." % DRAFTS)
                owner = api_owner(argv[2:])
                if owner is None:
                    continue                      # unresolvable: pass, never guess
                if owner not in allow:
                    ask("external publication is a human step (§publish-manual): `gh api` writes to `%s`, outside the "
                        "publish allowlist (%s). Approve only if the operator named this draft and asked to publish it; "
                        "otherwise draft it to %s and hand the path over via AskUserQuestion." % (owner, " ".join(sorted(allow)), DRAFTS))
                continue
            if not write:
                continue
            owner, explicit = gh_owner(argv, env, cwd)
            if explicit:
                if owner is not None and owner not in allow:
                    ask("external publication is a human step (§publish-manual): `gh %s %s` targets `%s`, outside the "
                        "publish allowlist (%s). Approve only if the operator named this draft and asked to publish it; "
                        "otherwise draft it to %s and hand the path over via AskUserQuestion." % (sub, verb, owner, " ".join(sorted(allow)), DRAFTS))
                continue
            rem = remotes(cur, None)
            outside = sorted({n for n, o in rem.items() if o and o not in allow})
            if outside:
                ask("external publication is a human step (§publish-manual): `gh %s %s` names no -R and this checkout has "
                    "a remote outside the publish allowlist (%s), which gh may default to. Approve only if the operator "
                    "named this draft and asked to publish it; otherwise draft it to %s, or re-run with -R <org>/<repo>."
                    % (sub, verb, ", ".join("%s=%s" % (n, rem[n]) for n in outside), DRAFTS))
            continue
        if base == "git" and len(argv) >= 2:
            j = 1
            if argv[1] == "-C" and len(argv) >= 4:
                git_c = argv[2]; j = 3
            sub = argv[j] if j < len(argv) else ""
            if sub == "send-email":
                ask("external publication is a human step (§publish-manual): `git send-email` mails a patch under a "
                    "personal identity, outside the org. Approve only if the operator named this draft and asked to "
                    "publish it; otherwise draft it to %s and hand the path over via AskUserQuestion." % DRAFTS)
            if sub != "push":
                continue
            rest = argv[j + 1:]
            if "--dry-run" in rest or "-n" in rest:
                continue
            valued = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
            pos = []
            k = 0
            while k < len(rest):
                t = rest[k]
                if t in valued:
                    k += 2; continue
                if t.startswith("-"):
                    k += 1; continue
                pos.append(t); k += 1
            target = pos[0] if pos else None
            if target and ("://" in target or target.startswith("git@")):
                owner = owner_of_url(target)
            elif target and target.startswith("$"):
                continue
            else:
                rem = remotes(cur, git_c)
                if not target:
                    target = "origin"
                owner = rem.get(target)
            if owner is None or owner in allow:
                continue
            ask("external publication is a human step (§publish-manual): `git push` targets `%s` (owner `%s`), outside "
                "the publish allowlist (%s). Approve only if the operator asked to publish there; otherwise draft the "
                "change to %s and hand it over via AskUserQuestion." % (target, owner, " ".join(sorted(allow)), DRAFTS))


def check_mcp(name, tool_input, cwd):
    action = name.split("mcp__github__", 1)[1]
    if action in ("create_gist", "update_gist"):
        ask("external publication is a human step (§publish-manual): `%s` publishes under a personal identity, "
            "outside the org. Approve only if the operator named this draft and asked to publish it; otherwise "
            "draft it to %s and hand the path over via AskUserQuestion." % (name, DRAFTS))
    if action not in MCP_W and not action.startswith(MCP_W_PREFIX) and not action.endswith(MCP_W_SUFFIX):
        return
    allow = allowlist(cwd)
    owner = str((tool_input or {}).get("owner") or "").strip().lower()
    if not owner or owner in allow:
        return
    ask("external publication is a human step (§publish-manual): `%s` targets `%s`, outside the publish allowlist "
        "(%s). Approve only if the operator named this draft and asked to publish it; otherwise draft it to %s and "
        "hand the path over via AskUserQuestion." % (name, owner, " ".join(sorted(allow)), DRAFTS))


try:
    d = json.loads(sys.stdin.read())
    if not isinstance(d, dict):
        sys.exit(0)
    name = str(d.get("tool_name") or "")
    ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
    cwd = str(d.get("cwd") or os.environ.get("PG_ROOT") or ".")
    if name == "Bash":
        cmd = ti.get("command")
        if isinstance(cmd, str) and cmd.strip():
            check_bash(cmd, cwd)
    elif name.startswith("mcp__github__"):
        check_mcp(name, ti, cwd)
except SystemExit:
    raise
except Exception:
    sys.exit(0)
sys.exit(0)
PY
}

MSG="$(verdict)"
RC=$?
if [ "$RC" != 3 ]; then
  exit 0
fi
# The reason travels inside JSON; escape the four characters that could break it.
ESC="$(printf '%s' "$MSG" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  ')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$ESC"
exit 0
