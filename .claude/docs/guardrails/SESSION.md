<!-- guardrails-kit: v1.1.3 (§2001 harness-agnostic task widget) | Editing this file? Read .claude/docs/guardrails/_FORMAT.md first. Never paraphrase kit text. -->
You are here because you return from compaction or /resume, the user pauses ("stop", "later"), or a task spanning a compaction has no .claude/docs/guardrails/STATE.md.

> Reconciliation: the LIVE running/done/next list belongs in your harness's **native task widget** (Claude Code: `TodoWrite`), not a file. `.claude/docs/guardrails/STATE.md` is the OPTIONAL persistent store for cross-compaction Constraints / Facts / Decisions only — create it via S2 when a task spans a compaction. Post-compaction recovery ALSO reads whatever THIS repo's `CLAUDE.md` names as its own recovery sources, plus `git log --oneline -10` + `git status`. A `## Done` RESULT that is durable TECHNICAL knowledge beyond this repo also gets ONE `donate_fact` over eugo-kb (§facts-donate; run-metadata never qualifies).
> (athena's are the approved plan file under `~/.claude/plans/` and, on overnight runs, the `.claude/data/overnight/` breadcrumbs — an EXAMPLE of the shape, not the list your repo uses.)

- S1. Returned from compaction or /resume? Do this FIRST, before any file-modifying tool call:
    1. Read .claude/docs/guardrails/STATE.md in full. Missing? Create it via S2, filling Goal/Now from the compaction summary plus `git log --oneline -10` and `git diff --stat HEAD`, marking every entry UNVERIFIED.
    2. Run `git status` and `git diff --stat HEAD`.
    3. Restate in one line the Goal and the current Next step.
    Treat every compaction-summary claim about file contents or completed work as UNVERIFIED until confirmed by a Read or git evidence.
- S2. No .claude/docs/guardrails/STATE.md the moment this doc fires (or PLAN.md P9 fires)? Create it NOW with EXACTLY these nine `##` headers — headers verbatim; replace each `<...>` line with real content, delete unused placeholders:
```markdown
## Goal
<the user's original request, one line, near-verbatim>
## Now
<current step>
## Next
<ordered remaining steps>
## Constraints
<verbatim user limits: "don't touch X", "only change Y">
## Decisions
<what — why, one line each>
## Facts
<canonical ports, paths, run/test commands, versions, key symbol locations>
## Done
<milestone — RESULT: the conclusion/numbers, with evidence>
## Open items
<deferred TODOs, each actionable without the transcript>
## Failed attempts
<ATTEMPT entries per .claude/docs/guardrails/DEBUG.md D6>
```
    Keep it under 80 lines by deleting old Done entries — never by trimming specifics. Every line must read correctly to a fresh Claude with ZERO chat context: no "the fix we discussed", no "as above" — explicit files, commands, symbols, outcomes.
- S3. Update triggers — each is mandatory, in the SAME turn as the event:
| The moment... | Update |
|---|---|
| the task starts | Goal / Now / Next |
| the user states any "don't / only / keep / stop" | Constraints — verbatim (athena's CLAUDE.md iron rule 11 is the compressed form); SECOND correction of the same behavior -> tag `[RECURRING]` and re-read `## Constraints` before every edit for the rest of the session |
| a design choice is settled (by you or the user) | Decisions — per S6 |
| a milestone or expensive investigation completes | Done: `<what> — RESULT: <conclusion/numbers>` + refresh Now/Next |
| you write or think "later / after this / also need to / TODO" | Open items — a deferral that exists only in prose does not exist |
| a fix attempt fails | Failed attempts — exact format per .claude/docs/guardrails/DEBUG.md D6 |
| you are about to run /compact, see a context-low warning, or run a command expected to emit >200 lines or take >2 min | bring Now / Next / Failed attempts current FIRST; route the output per .claude/docs/guardrails/EFFICIENCY.md E10 |
| a canonical value is established (port, path, command, version) | Facts |
- S4. Before starting each new task-widget item or numbered plan step (PLAN.md P6), and after any RETURNING line, write: `ANCHOR: goal=<original request in <=15 words> | this step serves it by <reason>`. Cannot truthfully complete the line? Stop, re-read `## Goal`, re-plan or ask.
- S5. The moment you start ANY work not in the original request or approved plan, write: `DETOUR(depth n): <sub-problem> — RETURN-TO: <the step you left>` and mirror it in `## Now`; write `RETURNING: <step>` when it resolves. Max depth 2: a depth-2 detour needing another detour -> STOP and present the chain to the user.
- S6. When a design decision is settled, append `DECISION: <what> — <why>` to `## Decisions` in the same turn. Before introducing any new dependency, pattern, or naming scheme: scan `## Decisions` and either conform or write `REVERSING DECISION '<text>' because <new evidence>` and get user confirmation. Silent deviation is forbidden.
- S7. `CONSTRAINT CHECK:` — before the first edit of each file; exact format and procedure owned by .claude/docs/guardrails/CODE.md C4.

--- reference ---

## You are about to type a port, path, command, or symbol name from memory
Last seen more than 10 messages ago? Copy it from `## Facts` or re-derive it with a fresh Grep/Glob/Read — never retype from recall (near-miss corruption: 8080 for 8000, getUserById for get_user_by_id). A "not found" error on a value YOU typed: check `## Facts` first, not the codebase.

## You are about to rely on environment state you have not verified in 15 messages
Server up, port bound, package installed, branch checked out, env var set — re-verify with one command first; the command list and the debugging entry point are owned by .claude/docs/guardrails/DEBUG.md D2.

## You are about to start an expensive operation (full suite, multi-file audit, install, long build)
Check `## Done` for a matching entry and reuse its recorded RESULT unless the files it depended on changed. Recording results — not just activities — is what makes this possible.
