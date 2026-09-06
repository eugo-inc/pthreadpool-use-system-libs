<!-- guardrails-kit: v1.2.2-eugo stub (§1996 iron-rule back-pointers say athena's) | full playbook: the superpowers skills. Editing? Read .claude/docs/guardrails/_FORMAT.md first. -->
You are here because you realized — at start or mid-task — the task needs >2 file edits or edits in >1 top-level directory, you are about to Edit a 3rd file with no TASK block posted, or no other routing row matched.

Full playbook: invoke `superpowers:brainstorming` (before any creative/design work) then `superpowers:writing-plans` (multi-step spec) via the Skill tool — they own the fuller planning surface. Not loaded this session? Follow the anchors below.

- P4. TASK block — post it in the transcript before your first Edit:
      GOAL: <one sentence, your own words — not the user's if the code contradicts them>
      FILES: <exact paths you will change>
      EST: ~<n> changed lines across <n> files
      DONE-WHEN: <a command or observable check>
      CONSTRAINTS: <verbatim every "don't / only / keep / stop" the user stated>
      Cannot fill FILES yet? Investigate more, then post it. A later edit to a file not in FILES appends it first with a one-line reason.
- P5. Baseline: run the narrowest check covering FILES once — a single `pytest <path>::<test>` where one exists, else the smallest gate THIS repo's `CLAUDE.md` declares; record `BASELINE: <pass | N failures>` (already red -> report before starting).
- P6. FILES exceeds 3 files or EST exceeds ~150 lines? Split into numbered steps in dependency order, each ending with a named check; run and show each check BEFORE the next step — never carry more than one failing step. (Referenced by .claude/docs/guardrails/SESSION.md S4.)
- P9. Task spans a compaction and no .claude/docs/guardrails/STATE.md exists? Create it per .claude/docs/guardrails/SESSION.md S2. eugo: the LIVE running/done/next list is the TodoWrite tool (athena's CLAUDE.md ## Project), not a file.
- P10. Every TODO list goes to the user BEFORE the first Edit: TodoWrite one task per item, flipped to completed as each lands. Anything needing the user's ACTION, INPUT or ATTENTION goes through AskUserQuestion the moment it arises — before the work, during it, or in the final answer — never prose, never only a row in a doc. Sole exception: an `INVOLVEMENT: unattended` run FILEs instead of blocking and asks at its close. (Compressed as athena's CLAUDE.md iron rule 13.)
- P11. Verification disproves a step's premise: STOP the plan and surface the pivot via AskUserQuestion — never execute a step whose premise you have disproven (momentum ships the wrong plan).
