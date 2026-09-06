<!-- guardrails-kit: v1.2.2-eugo stub (§1996 iron-rule back-pointers say athena's) | full playbook: superpowers:verification-before-completion. Editing? Read .claude/docs/guardrails/_FORMAT.md first. -->
You are here because you are about to write "done", "fixed", "works", "passing", "complete", "resolved", or "ready", or to run git commit / gh pr create.

Full playbook: invoke `superpowers:verification-before-completion` via the Skill tool — it owns the fuller evidence-before-assertion protocol. Not loaded this session? Follow the anchors below.

- The two legal forms replace every hedge (athena's CLAUDE.md iron rule 6 is the compressed form): (a) `Verified: <command> -> <result line>`  (b) `UNVERIFIED — to confirm, run: <command>`. There is no third. Forbidden phrases: "should work", "should fix", "likely resolves", "ought to now". Canonical status vocabulary for every reported item: VERIFIED / UNVERIFIED / EDITED-UNVERIFIED / NOT-DONE / CANNOT-REPRODUCE.
- Fresh evidence only: every claim quotes a command's output line that appears verbatim in a tool result THIS turn, run AFTER the last edit. A quoted line with no matching tool result above it is fabrication — re-run the command now. "It compiles" is gate 0, never completion evidence.
- Failure-token scan on any verification output over ~30 lines: grep it for `error|fail|warn|skip|traceback|exception`; disposition each hit benign/real, or state "0 hits".
- Commit gate: run the gate set THIS repo's `CLAUDE.md` declares and quote its passing test-summary line. Never write "done" or run git commit while any gate reads FAIL.
  - Gates are PER-REPO and this doc ships to every one of them: a `make` target remembered from a sibling repo answers `No rule to make target`, which reads as a broken gate rather than the wrong one.
  - Read the CADENCE from that same block, never from memory: athena's per-commit set is NARROW and its full-suite run is a ~6-commit checkpoint (conflating the two overstated three findings' trigger frequency by ~6×, §746).
- Multi-part request: quote the original ask (or the plan's Goal) and mark every deliverable VERIFIED / EDITED-UNVERIFIED / NOT-DONE. Reporting NOT-DONE is fine; silently dropping it is not.
- V13. Measuring an A/B or flag effect: print the value the code RESOLVED at runtime, never the value you passed (a silently-overridden toggle proves the opposite claim).
- V14. A new regression test is evidence only beside a pasted RED run on the un-fixed baseline — revert the fix, watch it fail, restore (a test that never failed guards nothing).
- V15. Read the test-COUNT line, never rc or the output tail — no count line means the suite never ran (`0 collected` exits 0).
- V16. Background or piped job: completion is a marker file or artifact you check, never `$?` (a pipe's status is the last command's).
- V17. An instrument or probe that cannot run reports `UNMEASURABLE: <why>` — never a verdict (UNMEASURABLE is not UNOBSERVED, and neither is absence).
- V18. A subagent's report is a LEAD, not evidence — re-verify its file:line claims yourself before claiming or planning on them (3-of-3 plan-time characterizations measured wrong).
- V19. A zero/empty result from a probe or sweep is a claim about the PROBE until a positive control shows it CAN see a known-present case.
- V20. Before trusting V14's RED baseline run: the control must FAIL there, not error — five shapes make it pass against broken code.
  - V20a. Slicing a region out of a file: end the slice at the region's own terminator (`exit 1`), never a character count — `[:2000]` runs past it into unrelated code that satisfies the assertion.
  - V20b. Test doubles: implement the PRE-cure interface too, or the baseline raises `AttributeError` and a counting assertion reads 0 for the wrong reason.
  - V20c. Round-trip assertions: broken output often satisfies them (a Python dict repr IS valid YAML) — assert the encoding the cure guarantees, e.g. `json.loads`.
  - V20d. Asserting a token is ABSENT: the guard's own message may contain it — anchor to the emitted form (`>>> RECLAIMED`), never the bare word.
  - V20e. Control unbuildable without contriving the production path (a GIL race)? Write `regression pin, not a control` and record the both-sides run count.
