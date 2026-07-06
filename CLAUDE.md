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
