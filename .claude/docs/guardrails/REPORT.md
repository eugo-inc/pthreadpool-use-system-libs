<!-- guardrails-kit: v1.2.2 (§2001 harness-agnostic task widget) | Editing this file? Read .claude/docs/guardrails/_FORMAT.md first. Never paraphrase kit text. -->
You are here because you are about to write a verdict, finding, recommendation, or the turn's final answer to the user.

Checklist — cite the ID with one line of evidence when an item fires; skipping a fired item is a violation.

- R1. Open with ONE plain-English paragraph a non-specialist can parse — no jargon, no code tokens; every technical detail comes after it. (Compressed as athena's CLAUDE.md iron rule 14.) The plain-English lead counts inside .claude/docs/guardrails/EFFICIENCY.md E15's 10-line cap.
- R2. Presenting a search/lookup result that is not the exact location asked for: label it `SIMILAR — not the location asked for` in the SAME sentence that introduces it, never disclosed later in the turn. (Compressed as athena's CLAUDE.md iron rule 15.)
- R3. Presenting a trade-off: MEASURE the cheap side first and quote the number — "buys 67 ms" beats "is faster". A number obtainable in under ~5 minutes is mandatory before recommending. Cheap probes: `time.perf_counter` medians over >=20 interleaved reps, `len(sys.modules)` deltas, an A/B on the shipped artifact.
- R4. Name the checks you did NOT run — one `NOT CHECKED: <thing> — <why>` line each (implied coverage you did not have misleads the reader into skipping their own).
- R5. Every refused/skipped/dropped item gets its one-line reason; an empty refusal list prints `refused: none` (a silent no-op on a destructive or requested action reads as success).
- R6. Every number in the answer was recomputed this turn or quoted from pasted tool output — never hand-totaled, never remembered (restated figures rot; anchored ones do not).
- R7. End the answer with what REMAINS: one `NEXT:` line per open item naming its owner, or `NEXT: nothing owed`. Sources to sweep: the task widget's unfinished rows, every `NOTED (not done):` you logged this turn, and .claude/docs/guardrails/SESSION.md `## Open items` (a user who must ask "what's left?" was handed an unfinished report).
- R8. Any `NEXT:` item needing the user's ACTION, INPUT or ATTENTION goes through AskUserQuestion in THIS turn, not the next one — .claude/docs/guardrails/PLAN.md P10 owns the rule; this is its report-time trigger (a NEXT line is a record, and the record is not the ask).

--- reference ---

## The reader asked "where is X" and you found something like X
Lead with the label: `SIMILAR — not the location asked for: <path:line>`, then either keep looking or state plainly that the exact site was not found. Leading with the analogue reads as "X does not exist" and sends the reader hunting the wrong subsystem. Similar sites alongside the real one are welcome; a genuine not-found is fine too — only the unlabeled substitute is forbidden.

## You are about to summarize a multi-item outcome
GOOD (5-line shape): one plain-English sentence of outcome; the items as `VERIFIED / EDITED-UNVERIFIED / NOT-DONE / refused: <reason>` lines with numbers quoted from output; `NOT CHECKED:` lines; the R7 `NEXT:` lines.
BAD (never do this): a prose paragraph mixing done and not-done with totals recalled from memory.
