# CLAUDE.md

Eugo fork of google/pthreadpool, branch `eugo-main`.
Reason to exist: `USE_SYSTEM_*` CMake options + an
installed package config (`lib*/cmake/pthreadpool/pthreadpool-config.cmake`,
written by `INSTALL(EXPORT ...)` at CMakeLists.txt:223-226; the file
configured from `cmake/pthreadpool-config.cmake.in` stays in the build dir,
uninstalled) so PyTorch can `find_package(pthreadpool CONFIG REQUIRED)`. No `@EUGO_CHANGE` markers here;
the divergence inventory is `.claude/skills/eugo-upstream-merge/SKILL.md` --
update it in the same commit that changes a divergence.

Route by what you are about to do (skills in `.claude/skills/`):

- Building or smoke-testing -> eugo-build-and-test (flags, install checklist, consumer smoke).
- Touching `CMakeLists.txt` or `cmake/` -> eugo-cmake-review checklist before
  commit; after build+install, `test -f out/lib*/cmake/pthreadpool/pthreadpool-config.cmake`
  must exit 0 (missing config = failed build even if the .so linked).
- Asking "rebuild? downstream pin bump?" -> eugo-rebuild decision table.
- About to merge upstream -> eugo-upstream-merge. NEVER rebase or squash a
  sync -> land a merge commit (prior syncs: `be3c5e9`, `8c5da84`).
- `FIND_PACKAGE(FXdiv REQUIRED)` fails -> you are outside the eugo container
  (`.devcontainer/`); build there, or drop `-DUSE_SYSTEM_FXDIV=ON` for a
  compile-only check (downloads FXdiv instead).
- Editing `SET(CMAKE_C_STANDARD 11)` / `SET(CMAKE_*_EXTENSIONS NO)` ->
  protomolecule's setup patches those exact strings; update its regexes in
  the same adoption PR that bumps the pin.

## Routing — the moment X happens, your next tool call is that Read

The bullets above are this fork's own material and stay more specific; these rows are the
org-wide working discipline, installed from athena's `eugo-guardrails-kit` into
`.claude/docs/guardrails/` and recorded in `.claude/eugo-installs.json`.

| The moment you... | Read |
|---|---|
| realize the task needs >2 file edits or edits in >1 top-level directory, or are about to Edit a 3rd file with no TASK block posted | `.claude/docs/guardrails/PLAN.md` |
| are about to create or modify a repo file — Edit, Write, or a shell command that writes files — for the first time since session start or the last compaction | `.claude/docs/guardrails/CODE.md` |
| touch a dates / epochs / mutation-vs-copy / async / floats / sort / division-modulo / regex / familiar-API / closures / boolean-logic category | `.claude/docs/guardrails/TRAPS.md` |
| see a test you expected to pass fail, a build/test/run command exit non-zero, a traceback, output contradicting your prediction, or an unreproduced bug | `.claude/docs/guardrails/DEBUG.md` |
| are about to write "done" / "fixed" / "works" / "passing" / "complete" / "resolved" / "ready", or run git commit / gh pr create | `.claude/docs/guardrails/VERIFY.md` |
| are about to write a verdict, finding, recommendation, or the turn's final answer to the user | `.claude/docs/guardrails/REPORT.md` |
| are about to Read a 3rd file over 300 lines, or a search returned >50 hits | `.claude/docs/guardrails/EFFICIENCY.md` |
| return from compaction or /resume, the user pauses ("stop", "later"), or a task spanning a compaction has no `.claude/docs/guardrails/STATE.md` | `.claude/docs/guardrails/SESSION.md` |

Row matched: your next tool call is that Read, before any acting tool call. 2+ rows match →
do each, in table order. Refresh with
`eugo-skills install eugo-guardrails-kit --from <athena> --into .` — never hand-edit those
files, a refresh overwrites them; propose defects back to athena instead.
