---
name: eugo-cmake-review
description: >-
  Pre-commit review of CMake / build-config divergence in this fork — loads eugo-cmake-review-base from athena's skill catalog over MCP and applies this fork's marker vocabulary, audit command, frozen count table and non-negotiable build invariants. Use before staging any CMake / build-config change, and after any upstream merge that touched an annotated file. Activates on "review cmake changes", "pre-commit cmake audit", "annotation drift", "check the markers".
---

# eugo-cmake-review — pthreadpool-use-system-libs adapter (thin)

Thin adapter over the shared base `eugo-cmake-review-base` in athena's skill catalog,
served by the `eugo-kb` MCP server. The workflow lives in the base — do
NOT improvise from this file alone.

## 1. Load the base

1. Call `get_skill("eugo-cmake-review-base")` on `eugo-kb` and follow it, substituting
   every `{{param}}` placeholder with the values in §2. Fetch companion
   files it names on demand via `get_skill_file("eugo-cmake-review-base", "<path>")`.
2. Fallback (eugo-kb unavailable): read
   `.claude/skills/_pulled/eugo-cmake-review-base/SKILL.md` — refreshed with
   `eugo-skills pull --from <athena> --cache --name eugo-cmake-review-base`.
3. If neither exists: STOP and tell the user to wire eugo-kb (see
   athena `docs/skills/CONSUMING.md`). Never run the workflow from
   memory.

## 2. Parameters (this repo's values)

```yaml
# adapter-params v1
base: eugo-cmake-review-base
params:
  audit_cmd: ""
  catalog_doc: "the divergence inventory in this repo's `eugo-upstream-merge` adapter (§2 invariants) — this fork has no CLAUDE.md catalog, no markers, no audit script and no snapshot; keep that inventory current in the same commit as any divergence change"
  divergence_block_close: "NOT USED (no marker vocabulary in this fork); a future block form would be `# @EUGO_CHANGE: @end`"
  divergence_block_open: "NOT USED (no marker vocabulary in this fork — see divergence_inline); a future block form would be `# @EUGO_CHANGE: @begin <why>`"
  divergence_inline: "NOT USED — this fork carries NO `@EUGO_CHANGE` annotations at all; every divergence lives in `CMakeLists.txt` + `cmake/pthreadpool-config.cmake.in` and is tracked ONLY by the inventory in the eugo-upstream-merge adapter (a diff that adds, removes or moves a divergence updates that inventory in the same commit). If a marker is ever introduced, use `# @EUGO_CHANGE: <why>`."
  failure_modes: "| Signature | Cause / fix |\n|---|---|\n| `REGRESSION` from the install-tree test (no `pthreadpool-config.cmake`) | The `CONFIGURE_PACKAGE_CONFIG_FILE` / `INSTALL(EXPORT ...)` machinery was lost — restore it; this is the fork's whole purpose. |\n| `FIND_PACKAGE(FXdiv REQUIRED)` fails at configure | Outside the eugo container (no system FXdiv) — build in the container, install FXdiv the protomolecule way, or drop `USE_SYSTEM_FXDIV` for a compile-only check. |\n| pytorch configure: `find_package(pthreadpool CONFIG REQUIRED)` fails on FXdiv | `find_dependency(FXdiv)` missing from `cmake/pthreadpool-config.cmake.in`. |\n| protomolecule build dies at patch time on pthreadpool | One of the four `SET(CMAKE_*_STANDARD 11)` / `SET(CMAKE_*_EXTENSIONS NO)` anchors was reworked — update the setup regexes in the adoption PR. |\n| a dep vendored in system mode | An `ADD_SUBDIRECTORY` fallback lost its `NOT TARGET x AND NOT USE_SYSTEM_*` guard. |\n"
  legacy_marker_forms: ""
  non_negotiables: "1. **USE_SYSTEM_* options intact.** `USE_SYSTEM_LIBS` (default OFF, upstream-friendly) plus `USE_SYSTEM_FXDIV` / `USE_SYSTEM_GOOGLETEST` / `USE_SYSTEM_GOOGLEBENCHMARK`, each defaulting to `${USE_SYSTEM_LIBS}`. Do not flip defaults to ON — the fork must still build standalone like upstream does.\n2. **Both branches of every dep guarded.** Each dependency has `FIND_PACKAGE(... REQUIRED)` under `USE_SYSTEM_*`, and the download path (`CONFIGURE_FILE(cmake/Download*.cmake ...)` + `EXECUTE_PROCESS`) only in the ELSE branch. The `ADD_SUBDIRECTORY` fallbacks further down must keep their `NOT TARGET x AND NOT USE_SYSTEM_*` guards — dropping one silently vendors a dep even in system mode.\n3. **Export/install machinery must not regress** (why the fork exists): `pthreadpool_interface` keeps `$<BUILD_INTERFACE:...>` / `$<INSTALL_INTERFACE:include>` includes and is installed into `${CMAKE_PROJECT_NAME}Targets`; `CONFIGURE_PACKAGE_CONFIG_FILE` + `INSTALL(EXPORT ...)` emit `${CMAKE_INSTALL_LIBDIR}/cmake/pthreadpool/pthreadpool-config.cmake`; `cmake/pthreadpool-config.cmake.in` keeps `find_dependency(FXdiv)` — removing it breaks pytorch's `find_package(pthreadpool CONFIG REQUIRED)` at pytorch-configure time, not here.\n4. **Consumer regex coupling.** protomolecule's `setup` patches these EXACT lines with `eugo_patch_or_die`: `SET(CMAKE_C_STANDARD 11)`, `SET(CMAKE_C_EXTENSIONS NO)`, `SET(CMAKE_CXX_STANDARD 11)`, `SET(CMAKE_CXX_EXTENSIONS NO)`. If a diff (or an upstream merge) reworks the \"Language options\" block, the downstream build fails loudly at patch time — update the setup regexes in the same adoption PR that bumps the pin.\n5. **Flags that must keep working** (the canonical protomolecule invocation uses them): `PTHREADPOOL_LIBRARY_TYPE=shared`, `PTHREADPOOL_SYNC_PRIMITIVE=futex`, `PTHREADPOOL_ALLOW_DEPRECATED_API=ON`, `PTHREADPOOL_ENABLE_FASTPATH` overridable per-arch (ON x86_64 / OFF aarch64).\n6. **Stay close to upstream.** Every divergent line is merge-conflict debt for the next `git merge upstream/main`. Prefer the smallest diff that works; adopt upstream shapes where possible.\n"
  preflight_checks: "```bash\n# System mode (eugo container; needs system FXdiv)\ncmake -B build-sys -G Ninja -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF -DCMAKE_INSTALL_PREFIX=\"$PWD/out\"\ncmake --build build-sys && cmake --install build-sys\ntest -f out/lib*/cmake/pthreadpool/pthreadpool-config.cmake || echo \"REGRESSION\"\n# Upstream-default mode (network; proves we did not break standalone builds)\ncmake -B build-def -G Ninja\ngrep -n 'SET(CMAKE_C_STANDARD 11)\\|SET(CMAKE_C_EXTENSIONS NO)\\|SET(CMAKE_CXX_STANDARD 11)\\|SET(CMAKE_CXX_EXTENSIONS NO)' CMakeLists.txt   # all four anchors present\n```\nIf both configures pass and the config file lands in the install tree, the change is safe to commit. Anything touching the divergence inventory finishes with the eugo-upstream-merge adapter's sanity notes.\n"
  preserved_upstream_marker: "none — upstream's shapes are adopted wherever possible (every divergent line is merge-conflict debt); upstream's download paths are kept live under the ELSE branch of each `USE_SYSTEM_*` guard rather than commented out, so the fork still builds standalone like upstream does"
  related_skills: "- `eugo-build-and-test` — canonical flags, the artifact checklist, the consumer smoke test.\n- `eugo-rebuild` — whether a change forces a downstream pin bump and the coupled-set rebuild order.\n- `eugo-upstream-merge` — the divergence inventory (keep it current) and the merge-commit-only recipe.\n- protomolecule `dependencies/native/pthreadpool/setup` — the four patch regexes this checklist protects.\n"
  snapshot_cmd: ""
  snapshot_path: ""
```

<!-- eugo:keep:start -->
## 3. Repo-specific lessons (beat the base on conflict)

- This fork has NO `@EUGO_CHANGE` annotations; the divergence is tracked only by the inventory in the eugo-upstream-merge adapter. If a change adds, removes or moves a divergence, update that inventory in the same commit — there is no marker grep that would catch the omission.
- Verify in BOTH modes: system mode (eugo container, `USE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON`, install-tree test) AND the upstream-default configure (`cmake -B build-def -G Ninja`, network) — the fork must still build standalone like upstream does.
<!-- eugo:keep:end -->
