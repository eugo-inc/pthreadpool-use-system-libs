# Watch advice — RESOLVED ledger

<!-- drained-through: (none) -->
<!-- armed-at: 02847a7bc63e8eb5064340d1ebbff51145ffa436 -->

The drain ledger for the TRACKED watch advice (`advice.jsonl` / `advice.md`, appended by
`codex_watch.py` on every reviewed commit): one row per NEEDS_REVISION / ERROR entry that
has been handled, keyed `ts · ref`. `python3 .claude/scripts/watch_drain.py status` counts
what is owed; `list --unresolved` prints the entries that still need a row; `rotate
--through <ts>` archives what is rowed and advances the marker above. The `armed-at`
marker is the review's starting line: commits at or before it are never selected.

| status | meaning |
|---|---|
| `FIXED §<id>` | cured in that commit |
| `REFUTED` | the finding is wrong; the row says why |
| `RETRY — <when>` | an ERROR entry re-reviewed later |
| `CLAIMED <session> <YYYY-MM-DDTHH:MM:SSZ>` | somebody is working on it (`watch_drain.py claim`); it closes nothing and lapses after 24 h, and `resolve` writes the real status over it |
| `OPEN → <backlog id>` | a real defect, filed in the backlog; the row records a look, not a closure, so the entry stays owed |
| `UNTRACED` | acknowledged but not traced: nothing was learned from it |

| ts | kind | ref | model | verdict | status | evidence |
|---|---|---|---|---|---|---|
