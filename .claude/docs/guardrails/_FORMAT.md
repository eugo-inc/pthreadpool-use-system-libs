<!-- guardrails-kit: v1.2.2 (§1996 iron-rule back-pointers say athena's) -->
You are here because you are about to edit CLAUDE.md or any .claude/docs/guardrails file. These contracts govern the kit's FORM; violating them silently degrades every other rule.

- F1. Every rule is one line, <=20 words where possible, opening with an imperative verb or a trigger clause (`When/Before/After <observable event>:`). No paragraphs. No hedges (usually / consider / try / generally). A checklist line over ~30 words splits into sub-lines under the same ID.
- F2. Triggers are observable events the model detects while typing ("writing a condition containing ! plus &&") — never judgment states ("when logic is complex"), predictions ("will outlive this sitting"), or topic nouns ("debugging").
- F3. CLAUDE.md hard budget: <=15 iron rules, 1 routing table, <=12 routing rows, <=5 CAPS lines, kit core + footer <=60 lines, <=140 lines total. Adding a rule over budget requires demoting one to a guardrail doc in the same edit. Never merge two rules into one line to dodge the cap.
- F4. NEVER/ALWAYS/MUST in caps: at most 5 lines in CLAUDE.md, reserved for irreversible damage (data loss, killed processes, pushed history, secrets). Adding a 6th requires downgrading one. Scope: kit zones only — migrated `## Project` lines keep their original casing and do not count.
- F5. Every prohibition carries its replacement action on the same line after `->` or an em-dash. The literal ` -> instead: ` form is mandatory for the CAPS hard-stop lines in CLAUDE.md. A prohibition without a replacement is invalid — rewrite it.
- F6. Every iron rule ends with a parenthesized reason, <=8 words, naming the concrete harm ("kills your own harness", "missed callers break silently"). Long rationale lives below the owning doc's divider.
- F7. Single source: a rule lives in exactly one file; cross-references are pointers by path + ID, never restatements. ONE sanctioned exception: a CLAUDE.md iron rule may be the COMPRESSED form of a doc rule — then the doc side cites the iron rule, and every trigger-phrase list or threshold shared by the pair is byte-identical in both. Sanctioned pairs: the registry below — naming a pair is not enough, the registry names WHAT is shared.
- F8. CLAUDE.md layout: routing table first, iron rules immediately after, `## Project` is the only block between iron rules and the footer, hard stops + the post-compaction re-arm line are the LAST block.
- F9. Every rule names a greppable literal token — an exact command, path, or number (`git diff --stat HEAD`, `.claude/docs/guardrails/STATE.md`, `>50 hits`). A rule with no literal token gets rewritten until it has one, or leaves the kit.
- F10. Kit verbs are tool names: Read, Grep, Glob, Edit, Write, run (Bash). Never "see / consult / check / refer to" when a tool call is meant. Every doc reference is the full literal path `.claude/docs/guardrails/<NAME>.md`, optionally + rule ID.
- F11. Guardrail doc shape: the first non-comment line restates the doc's routing-table trigger VERBATIM (glue words for grammar allowed, shared trigger TOKENS unchanged); the ID'd checklist fills the top; named procedures invoked by ID from a checklist or CLAUDE.md (e.g. REFERENCE SWEEP, ESCALATION LADDER) may sit between the checklist and the `--- reference ---` divider; reference-section headers are second-person situations ("Your fix didn't change the error"), never topic nouns. Caps: ~120 lines AND ~1,100 words; a doc that must grow past either splits by trigger.
- F12. Checklist IDs (P1.., C1.., D1.., V1.., E1.., S1.., R1.., F1.., M1.., RS1.., T-rows) are stable forever — never renumber, never reuse a retired ID. Grouping by theme may make numbering non-sequential; that is intentional. Compliance is cited by ID + one line of evidence.
- F13. Examples: at most one GOOD/BAD pair per core rule, below the divider. GOOD = 5-10 line mini-transcript of the correct tool sequence. BAD <=3 lines, always prefixed `BAD (never do this):`. No unlabeled example code anywhere.
- F14. Numbers, not judgment words: "10 messages" not "recently", "2 failures" not "repeatedly", ">200 lines" not "long output". The exact value matters less than its existence.
- F16. Retiring or moving a kit/reference doc leaves a RETIRED pointer-stub at the old path naming the successor path — never silent deletion (dead paths keep getting cited).
- F15. Kit files are edited only deliberately and verbatim-carefully: never regenerate a kit file from memory, never "clean up" wording in passing, never reflow. Any kit edit bumps the version comment on the file's first line, adds an entry under .claude/docs/guardrails/README.md `## Upgrade notes`, AND lands the identical bytes in skills/eugo/eugo-guardrails-kit/references/guardrails/ in the SAME commit — tools/tests/test_guardrails_kit_mirror.py gates it (doctor certifies consumers against the CATALOG hash, so a one-tree edit forks the kit org-wide; STATE.md is the sole live-only file). Exemption: the project-authored reference archives are verbatim slices of the pre-restyle CLAUDE.md — never reformat their transported content to these contracts. They live in TWO trees: `docs/reference/*.md` (layout.md + env-vars.md are byte-guarded by tests, plus cli-catalog.md, environment.md, ingest-and-retention.md, logging.md, doc-style.md, mcp-tools.md) and `.claude/docs/reference/*.md` (operating-rules.md, conventions.md).

## Compression-pair registry (F7) — the shared material, byte-identical in BOTH members
Ported from ring's `_FORMAT.md` (athena §1991, where `tools/tests/test_f7_compression_pairs.py`
checks every row; a consumer of this kit owns the table but not that test).
Naming a pair only says the compression is sanctioned; this says what may not drift.
In a cell, the BACKTICKED runs are the claim and everything after `NOTE:` is commentary — the gate
reads only the former, so a note may quote a retired value without asserting it.
⚠ The `iron N` numbers below are ATHENA'S. A repo that adopted the kit's routing template numbers its
own; a repo that kept its existing CLAUDE.md (every consumer as of 2026-09-05) has no such numbering
at all, and the `iron N` back-pointers in the rule docs say `athena's CLAUDE.md` for that reason.

| Pair | Shared material — byte-identical in both |
|---|---|
| iron 1 <-> CODE.md C1 | `Read the enclosing function/class plus the import block` · `Grep snippet is not a Read` |
| iron 3 <-> CODE.md C12 | `signature, symbol name, return shape, config key, route, CLI flag, env var, or enum member` |
| iron 4 <-> CODE.md C5 | `nfamiliar or third-party API with 2+ arguments: paste its real signature` |
| iron 6 <-> VERIFY.md forbidden-phrases | `"should work", "should fix", "likely resolves",` · `` `Verified: <command> -> <result line>` `` · `` `UNVERIFIED — to confirm, run: <command>` `` |
| iron 10 <-> EFFICIENCY.md E14 | `"probably / presumably / likely / I assume / should be" about this repo's code` · `run the Grep or Read that answers it` |
| iron 11 <-> SESSION.md S3 | `"don't / only / keep / stop"` · `task spans a compaction` |
| iron 12 <-> EFFICIENCY.md E5+E6 | `at most ONE short line` NOTE: the pair's ONLY shared token; in athena it read "at most one line" on the CLAUDE.md side until athena §1991, which is the drift a registry of names could not see |
| iron 13 <-> PLAN.md P10 | the whole trigger sentence, `Every TODO list goes to the user BEFORE the first Edit:` through `never prose, never only a row in a doc` |
| iron 14 <-> REPORT.md R1 | `plain-English paragraph` NOTE: the pair shares a CONCEPT, not a list; this token is all F7 can hold it to |
| iron 15 <-> REPORT.md R2 | `` `SIMILAR — not the location asked for` `` |

--- reference ---

## Why form is load-bearing
Weaker models obey what they can pattern-match at the moment of action. Event-phrased triggers fire because they match tokens the model actually generates ("pytest exited 1"); topic headers never fire. Paste-verbs ("paste the output") are self-enforcing because compliance is visible in the transcript; check-verbs ("ensure") invite assertion. Budgets exist because always-on compliance is roughly constant-sum: every rule added over the cap silently taxes obedience to all the others. Paired trigger lists must stay byte-identical because a model greps its own draft against whichever copy it last read. When editing the kit, you are editing its enforcement mechanics, not its prose.
