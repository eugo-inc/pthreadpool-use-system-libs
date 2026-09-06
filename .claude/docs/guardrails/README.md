<!-- guardrails-kit: ledger | the _FORMAT.md F15 upgrade-notes ledger for the kit files in this directory + CLAUDE.md. -->
# Guardrails kit — version + upgrade notes

Kit: **v1.1.1-eugo** (§1.37 fixing wave: F15 mirror clause + mirror gate). Core: CLAUDE.md
(routing table, iron rules, hard stops); the 10 docs here carry the routed checklists.
Per F15, every kit edit bumps the touched file's first-line version comment and adds
an entry below.

## Upgrade notes

- **2026-09-05 §1996 (CODE v1.0.2, EFFICIENCY v1.1.1, REPORT v1.2.1, PLAN v1.2.2-eugo,
  SESSION v1.1.2, VERIFY v1.2.2-eugo, _FORMAT v1.2.2)** — the THIRD shape of §1990's defect, and the
  worst of the three, because this one does not merely dead-end: it points a consumer at a rule that
  EXISTS and is about something else. Fourteen rule lines across seven docs cited
  "`CLAUDE.md` iron rule N" — meaning ATHENA's numbering — as though it were the reading repo's.
  Measured across the five consumer branches opened this day: **not one of the five shared trigger
  phrases appears in any consumer's CLAUDE.md**, and in protomolecule "iron rule 13" is
  `Leave @TODO+:Slava: markers untouched`. So `PLAN.md` P10 told a protomolecule session that its
  ask-the-user rule was compressed into a rule about Slava's TODO markers.
  Every such back-pointer now reads **`athena's CLAUDE.md iron rule N`**. F7's own sentence keeps the
  GENERIC referent — that clause describes the contract, which applies beside whatever CLAUDE.md the
  kit is installed next to — and the compression-pair registry gained a header warning that its
  `iron N` numbers are athena's. `SESSION.md`'s and `PLAN.md`'s `CLAUDE.md ## Project` pointers got
  the same qualifier for the same reason.
  Found by an adversarial audit of this session's own work, not by a gate: nothing checks that a
  cross-reference resolves in the repo the kit lands in.

- **2026-09-05 §1995 (_FORMAT.md v1.2.0 → v1.2.1)** — an F15 repair on F15's own home file, found by
  an adversarial audit of this session's work rather than by any gate. §1994 made two substantive
  content edits to `_FORMAT.md` (labelling the F7 registry's athena citation, and rewriting the
  iron-12 row's NOTE) and **left line 1 at the byte-identical `v1.2.0` stamp inherited from §1991**.
  F15's first clause — "Any kit edit bumps the version comment on the file's first line" — was
  simply not honoured, while its README and mirror clauses were. The consequence is a version-string
  COLLISION: two different `_FORMAT.md` contents both shipped as `v1.2.0`, so a consumer comparing
  version markers could not tell them apart. `test_guardrails_kit_mirror.py` never catches this class
  — it compares the live tree to the mirror, and both halves of a one-commit edit move together.
  ⚠ Filed, not fixed: **nothing gates the version-bump clause.** A gate would have to compare a kit
  file's bytes against its bytes at the last commit that changed its version line.

- **2026-09-05 §1994 (DEBUG.md v1.1.3-eugo → v1.1.4-eugo, _FORMAT.md text)** — §1990's defect
  was BIGGER than the `make` targets, and the evidence was sitting in epstein-drive the whole
  time: it had hand-edited **four RULES across three installed kit files** — not the one §1990 knew
  about. (§1995 correction: §1994's own subject and this sentence both said "four kit FILES". The
  files are `DEBUG.md`, `SESSION.md` and `VERIFY.md`; DEBUG.md carries two of the four edits, D13
  and D15. Measured by diffing all ten against athena `4bf3f97c`, the `source_commit` its
  `.claude/eugo-installs.json` pins: 3 of 10 differ.) D13's concurrency clause and SESSION.md's
  reconciliation block were replaced there too, and every one of those edits swapped ATHENA'S
  SPECIFICS for its own. That is the same defect wearing a
  different shape — the kit presenting athena's stack as the reader's.
  **D13** read `eugo §622: … two pytest runs share one Postgres …`. The `eugo:` prefix claims
  org-wide scope for a fact about athena's database, and epstein-drive had rewritten it to name
  its in-image build and `cdk synth` instead. D13 now STATES the rule portably ("any build or
  suite still running reads the SAME live tree") and keeps athena's case as a labelled
  `(athena §622: …)` example the reader substitutes.
  `test_guardrails_kit_is_portable.py` gained the check: an athena `§` id inside a shipped RULE
  must say it is athena's. **It immediately caught a line §1991 had just written** — the F7
  registry's own header cited `athena §1991` and `tools/tests/test_f7_compression_pairs.py` as
  if a consumer owned that test. Both are labelled now.
  ⚠ **STILL OPEN — SESSION.md's tailoring slot.** Its `eugo reconciliation` block is a large
  athena-shaped paragraph that consumers plainly rewrite (epstein-drive's names its FUTURE.md
  ED-ledger and nested `AGENTS.md` checklists). There is no mechanism to preserve such an edit
  across `eugo-skills install`, so **a refresh of any consumer that has tailored it destroys
  that work**. Naming it here rather than papering over it: the kit needs either a
  preserved-region convention or those slots must move into each repo's own CLAUDE.md.

- **2026-09-05 §1991 (_FORMAT.md v1.1.2 → v1.2.0)** — three contract improvements PORTED FROM
  RING, plus the drift the first of them immediately caught. ring's guardrails are a documented
  SIBLING of this kit, not a stale copy of it: both descend from guardrails-kit v1.0, ring's via a
  2026-07-07 Fable rewrite against its own 341-line CLAUDE.md, with full transport accounting in
  `ring/.claude/references/guardrails/DISPOSITION-LOG.md` — including a `## Kit provenance` section
  naming every lifted line. Its docs live at `.claude/references/guardrails/` and carry their own
  `ring-guardrails: v1.0` markers and their own ID space (C13–C20, IR1–IR15), and **those IDs are
  cited across ring's `src/` and `tests/`** (47 fixed-string replacements in its citation sweep), so
  ring's numbering is never to be renamed to match this kit's. Nothing had ever flowed BACK.
  **(1) F7 gains a compression-pair REGISTRY.** F7 permits exactly one duplication — an iron rule
  compressing a doc rule — provided "every trigger-phrase list or threshold shared by the pair is
  byte-identical in both". The doc listed only the pair NAMES, which says the compression is
  sanctioned and nothing about what may not drift, so nothing could check it and nothing did. The
  table now names the shared strings, `tools/tests/test_f7_compression_pairs.py` parses it and
  checks every row in both members. §1985's `test_ask_and_report_rules_survive.py` had to
  hand-write a `_SHARED_TRIGGER` tuple to do this for the ONE pair it cared about; that test stays
  (it also pins the rules' existence and the unattended carve-out), but the byte-identity half is
  now covered generically for all ten pairs, so the next pair needs a table row, not a new test.
  **It found a live drift on its first run**: iron 12 read `at most one line` while EFFICIENCY.md
  E6 read `at most ONE short line` — the pair's ONLY shared threshold, and not shared. CLAUDE.md
  now matches E6. Two rows are deliberately one token long (iron 12, and iron 14 ↔ R1 which share
  a concept rather than a list); recording that honestly is the point.
  **(2) F3 gains ring's two caps** — `<=12 routing rows` and `<=140 lines total`. Both were ALREADY
  satisfied when adopted (athena: 10 rows, 89 lines), which is what made them a ratchet rather than
  a change; the new gate pins them from below.
  **(3) F11's flat "VERBATIM"** became ring's honest form — "glue words for grammar allowed, shared
  trigger TOKENS unchanged" — because athena's own routing rows already compress their docs'
  trigger lines, so the strict reading was a rule the repo did not follow.

- **2026-09-05 §1990 (VERIFY.md v1.2.0-eugo → v1.2.1-eugo, PLAN.md v1.2.0-eugo → v1.2.1-eugo,
  DEBUG.md v1.1.2-eugo → v1.1.3-eugo)** —
  the kit was shipping ATHENA'S OWN GATE COMMANDS to every consumer. Found by installing the kit
  into a protomolecule clone and reading what landed: `VERIFY.md`'s commit-gate line named
  `make docker-test` / `make lint` / `make route-coverage`, none of which exist in protomolecule —
  an agent obeying it there gets `No rule to make target`, which reads as a broken gate rather
  than the wrong one. It was wrong three ways at once. (1) **Not portable**, as above.
  (2) **An F7 violation**: it RESTATED the commit gate that lives in `CLAUDE.md` `## Project`,
  where F7 allows only a pointer. (3) **Stale for athena itself**: §746 split the per-commit gate
  (NARROW) from the full-suite CHECKPOINT (~6 commits) after the conflated reading cost three
  findings a ~6× overstatement — and it fixed `CLAUDE.md` only, so the conflation survived
  untouched in the doc routed to at every commit. `test_claude_md_gate_cadence.py` never caught it
  because that gate reads `CLAUDE.md` and nothing else. The line now POINTS at whatever gate set
  the reading repo declares, which is correct in all of them and cannot go stale in any.
  ⚠ **epstein-drive had already hand-edited this exact line** to name its own gates
  (`docker build --build-arg EUGO_RUN_TESTS=true` + `pre-commit run --all-files` + working
  agreement 7) — a correct fix that the next `eugo-skills install` would have silently
  overwritten. The pointer form is what makes that local edit unnecessary; on its next refresh it
  should take the kit's line and move its command list into its own `CLAUDE.md`.
  `PLAN.md` **P5** carried the same defect and one more on top: it told every repo to baseline with
  `make docker-test` — and offered athena's WHOLE SUITE as the first option under the word
  "narrowest", contradicting its own rule. It now reads `pytest <path>::<test>` where one exists,
  else the smallest gate the reading repo declares.
  `DEBUG.md` D15's `(eugo: docs/reference/environment.md …)` became `(athena: …)`: the other
  `eugo:` slots (CODE C4, DEBUG D6, PLAN P9, EFFICIENCY E17) name TodoWrite and STATE.md, which
  are org-wide, but that one names an athena-only file. NOTE: this bump makes every consumer's
  `doctor` report the kit stale until it re-installs.

- **2026-09-05 §1985 (REPORT.md v1.1.0 → v1.2.0, PLAN.md v1.1.0-eugo → v1.2.0-eugo)** — the two
  duties a session kept having to be ASKED for. **P10 widened**: its trigger was "BEFORE the first
  Edit", so an item needing the operator that surfaced late had no rule pointing at it — it now
  fires "the moment it arises — before the work, during it, or in the final answer", and its
  subject widened from "open question" to anything needing the user's ACTION, INPUT or ATTENTION.
  Iron rule 13 carries the same trigger phrases byte-identical (F7's sanctioned pair); the F3
  budget is untouched at 15/15 because nothing was added, only widened. **R7** requires the answer
  to END with what remains (`NEXT:` lines, or `NEXT: nothing owed`) — the repo already MANDATED
  next-steps from every subagent (EFFICIENCY.md E9) while the main agent's answer to the user owed
  none, and the correct shape was written down only as an unnumbered example below REPORT.md's
  divider, where nothing could fire on it. **R8** is P10's report-time trigger, closing the gap
  that the doc CLAUDE.md routes to at final-answer time said nothing about the widget. The sole
  exception is named where it lives: `eugo-run-overnight-base` `INVOLVEMENT: unattended` FILEs
  instead of blocking — and now discharges those filed forks through the widget at the run's close.

- **2026-08-20 §922 (VERIFY.md v1.1.0-eugo → v1.2.0-eugo)** — added **V20**, the companion to
  V14. V14 says a regression test is evidence only beside a RED run on the un-fixed baseline. It
  does not say that the RED run itself can lie, and in window 22 it lied **five times**, each in a
  different way, each caught only because a banked pre-cure copy was actually run:
  §902 (`"[dev]" not in block` matched the block's own `(see [dev] above)`), §910 (a fixed
  `[:2000]` slice ran past `exit 1` into code that mentions `$SNAPSHOT` for its own reasons, so the
  scope assertion passed on the broken script), §913 (the counting stub lacked
  `get_signing_key_from_jwt`, so the baseline raised `AttributeError` and the refresh count was 0
  for the wrong reason), §914 (a `yaml.safe_load` round-trip passed against the broken emitter,
  because a Python dict repr IS valid YAML), §917 (`"RECLAIMED" not in stdout` matched the guard's
  own *"NOT printing a RECLAIMED verdict"* and red on CORRECT behaviour).
  V20e records the honest opposite: §921's lock test passed **15 of 15** against the unlocked code,
  so it is labelled a regression pin rather than dressed up as a control. Four of the five shapes
  make a control pass against broken code; the use-vs-mention one makes it fail against a correct
  fix. Both directions mean the same thing — the control was never testing what it claimed.

- **2026-08-19 §831 (_FORMAT.md v1.1.1 → v1.1.2)** — F15's exemption named
  `.claude/docs/reference/*.md` and listed layout.md, env-vars.md and cli-catalog.md under it.
  Measured: that directory holds only `operating-rules.md` and `conventions.md`; the other three
  moved to `docs/reference/` in the 2026-07-10 docs consolidation, so the clause exempted files at
  a path they no longer occupy while the tree that actually holds them was unnamed. The exemption
  now names BOTH archive trees and enumerates them. `tools/tests/test_f15_exemption_paths.py`
  gates it: every bare `X.md` the clause names must exist under one of the directory globs the
  same clause names.

- **2026-08-16 §622 (DEBUG.md v1.1.0 → v1.1.2-eugo stub)** — NEW **D15**: a test named in a
  FAILURE line is not automatically what failed; confirm the runner reported an ASSERTION and
  not a worker/process death (`grep -E "node down|crashed while running|^E "`) before debugging
  it. Sourced from a measured incident: two xdist workers died in one run and pytest reported
  the deaths as failures of the two real-embedding tests they happened to be running — no
  traceback, no `E` line, and the named test printed PASSING numbers in the same output. **D13**
  gains a concurrency clause — self-inflicted breakage includes concurrency YOU started (a
  background suite reads your uncommitted edits; two pytest runs share one Postgres and a
  `finally: DROP TABLE` in one blanks the other's fixture mid-assertion). Both mechanisms were
  observed this session, the second twice. Worked example + the two known crash families live
  in `docs/reference/environment.md` under `docker-test-serial`.

- **2026-08-13 §backport1 (v1.0.1 → v1.1.0)** — org-repo drift backports (survey of 16
  repos; sources cited per rule in the survey record). NEW doc REPORT.md (R1-R6,
  reporting/communication rules) + its routing row. CLAUDE.md irons 13 (widget
  TODOs/questions — Ben 2026-08-03, protomolecule), 14 (plain-English-first — Ben's
  practiced convention, written down here for the first time), 15 (SIMILAR-labeling —
  Ben 2026-08-06); routing contract gained the 2+-rows tie-break. VERIFY V13-V19
  (toggle-proof, RED-on-baseline, test-count line, marker files, UNMEASURABLE,
  subagent-report-is-a-LEAD, positive controls). DEBUG D11-D14 (evidence-class
  rotation + ladder floor, wrong-env noise, self-inflicted check, read-the-deriver).
  PLAN P10-P11 (widget pair row; disproven-premise stop). EFFICIENCY E18 (never Read
  a subagent transcript). _FORMAT F16 (RETIRED pointer-stubs) + 3 new F7 pairs + R
  namespace. **F3 is now exhausted (15/15 iron rules)** — the next iron rule requires
  a demotion in the same edit.
- **2026-08-14 §1.37-A5 (v1.1.0 → v1.1.1)** — F7 kit-hygiene wave: F15 gained the
  MIRROR clause (a kit edit lands in BOTH trees same-commit; gated by the new
  tools/tests/test_guardrails_kit_mirror.py byte-compare); SESSION.md's eugo tailoring
  slot gained the durable-RESULT → donate_fact rider (the §1.37 refuted-set revival);
  and the four pre-§backport1 ledger entries below were rescued from under `## Parked`
  (finding 32 — the §backport1-A edit stranded them there).
- **2026-07-09 §audit1-B (v1.0 → v1.0.1)** — restyle-seam fixes from the panel-confirmed
  audit: this ledger created (F15 previously pointed at a nonexistent root-README
  section); CODE.md C4 + EFFICIENCY.md E17 gained the eugo TodoWrite-first clauses
  (STATE.md only when a task spans a compaction, matching DEBUG.md D6 + iron rule 11);
  EFFICIENCY.md E15's exemption re-anchored to `Verified:` evidence lines (the V1..V12
  echo lines never existed in the eugo VERIFY.md stub); SESSION.md preamble re-aligned
  verbatim to the CLAUDE.md routing row (F11); CLAUDE.md iron rule 2 aligned to CODE.md's
  1-failure re-Read semantics; DEBUG.md D6 dropped the undefined `[L<level>]` token;
  the logging-convention id disambiguated to `§C10` across CLAUDE.md/logging.md/
  env-vars.md/layout.md/eugo-extract (CODE.md checklist C10 keeps the bare form).
- **2026-07-09 §sweep1-C (88a19dda)** — CLAUDE.md Commit-gate + operating-rules.md step 7
  cadence harmonized to §v3-7 (~6 commits, 3 on schema/invariant touches).
- **2026-07-09 §fable-C (02fa1cf0)** — .claude skills + reference-doc headers restyled.
- **2026-07-09 §fable-A+B (d3485d4b)** — kit imported: CLAUDE.md slimmed to the routed
  core; guardrail docs + the .claude/docs/reference/ split created.

## Considered, not adopted (decision ledger — re-litigating needs new evidence)

- **TRIGGER-receipt ceremony** (epstein-drive: a mandatory `TRIGGER: none` line every
  turn): rejected — eugo_ray_dag measured per-turn echo ceremony as noise (its
  session-guardrails rejection ledger); athena keeps TRIGGER-on-match + cached-IDs.
- **kiro-gateway "Systems Over Patches" / extract-hardcoded-values-immediately**:
  conflicts with iron rule 8 (no drive-by edits); upstream third-party doctrine —
  needs an owner ruling before any adoption.
- **Mutation-harness carrier** (eugo_ray_dag mutate_guards/mutate_sorts, 1656 lines):
  doc-rows adopted (V14/V17/V19); the carrier waits for a 2nd consumer (tech-debt-audit
  precedent).

## Parked (deferred pending a doc split — CODE.md and TRAPS.md sit at the F11 word cap)

- CODE.md candidates: write-back-to-leaf routing (record new detail in the leaf
  reference doc, never the hub — protomolecule×3); unrelated-test-red = scope-creep
  signal (ee_math cross-cutting:1007); empty-but-SET env var ≠ unset (rust
  AGENTS:467); foreground-only state-mutating commands (pytorch scrub-issue:57).
- TRAPS.md candidates: ANSI-in-logs pattern-shaped risk (protomolecule, measured
  2026-08-10); NUL-byte grep blindness + `grep -a` retry (ee_math cross-cutting:300);
  rolling-value assertion contract, 4 shapes (ee_files testing:97); same-version
  reinstall no-op + cwd shadowing (ray-meson build-and-test:60).
- ROUNDS-derived: probe-domain class (every probe defines a domain; a result inside
  it looks complete — isrc ROUNDS §14); gate-tested-against-known-bad-first (ROUNDS
  :735).
