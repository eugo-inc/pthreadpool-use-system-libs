---
name: eugo-rebuild
description: >-
  Decide what level of rebuild a change to this eugo fork actually requires and pick the cheapest correct action — loads eugo-rebuild-base from athena's skill catalog over MCP and applies this repo's decision table, cache gotchas, and pin-bump rules. Walk-the-diff table, the fresh-interpreter/stale-cache rule, lockstep pin bumps, push-before-pin. Activates on "rebuild <package>", "do I need to rebuild", "which build does this diff affect", "stale cache", "bump the pin", "is this a docs-only change", or /eugo-rebuild.
---

# eugo-rebuild — pthreadpool-use-system-libs adapter (thin)

Thin adapter over the shared base `eugo-rebuild-base` in athena's skill catalog,
served by the `eugo-kb` MCP server. The workflow lives in the base — do
NOT improvise from this file alone.

## 1. Load the base

1. Call `get_skill("eugo-rebuild-base")` on `eugo-kb` and follow it, substituting
   every `{{param}}` placeholder with the values in §2. Fetch companion
   files it names on demand via `get_skill_file("eugo-rebuild-base", "<path>")`.
2. Fallback (eugo-kb unavailable): read
   `.claude/skills/_pulled/eugo-rebuild-base/SKILL.md` — refreshed with
   `eugo-skills pull --from <athena> --cache --name eugo-rebuild-base`.
3. If neither exists: STOP and tell the user to wire eugo-kb (see
   athena `docs/skills/CONSUMING.md`). Never run the workflow from
   memory.

## 2. Parameters (this repo's values)

```yaml
# adapter-params v1
base: eugo-rebuild-base
params:
  build_cmd: "`cmake --build build && cmake --install build`, then the install-tree check (`test -f out/lib*/cmake/pthreadpool/pthreadpool-config.cmake`)"
  build_system: "cmake + ninja; the local build takes seconds, so the cheap/expensive split is not compile time — it is whether the change must propagate downstream (push + protomolecule pin bump + rebuilding the coupled consumers)"
  configure_cmd: "the canonical-flag configure from eugo-build-and-test (`cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=\"$PWD/out\" -DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_SYNC_PRIMITIVE=futex -DPTHREADPOOL_ALLOW_DEPRECATED_API=ON -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF`)"
  fork_name: "eugo-inc/pthreadpool-use-system-libs, branch eugo-main (fork of google/pthreadpool)"
  invariants: ["decision table (first matching row wins): docs, .devcontainer/, .mcp.json, .claude/, .github/ -> nothing (not part of the built artifact); `CMakeLists.txt`, `cmake/*.cmake`, `cmake/pthreadpool-config.cmake.in` -> configure check with the canonical flags, then full build + install-tree check, and run eugo-cmake-review; `src/**`, `include/**` -> full build with tests ON + `ctest --test-dir build`; `test/**`, `bench/**`, `examples/**` only -> build with tests/benchmarks ON and run them (does not affect the shipped library); `BUILD.bazel`, `MODULE.bazel`, `WORKSPACE`, `confu.yaml`, `configure.py` -> nothing for eugo (we only consume the CMake flow; keep in sync with upstream on merges)."]
  pins: ["protomolecule/dependencies/native/pthreadpool/meta.json `version.commit` — nothing reaches any eugo build until BOTH the commit is pushed to GitHub eugo-main (the setup curls the archive tarball; unpushed SHAs 404) AND the pin is bumped; a local rebuild proves nothing downstream until the pin moves. If the `SET(CMAKE_C_STANDARD 11)` / `SET(CMAKE_*_EXTENSIONS NO)` lines were touched, verify the four `eugo_patch_or_die` regexes in the protomolecule setup still match BEFORE bumping.", "after a pin bump, rebuild the coupled set if their pinned versions moved together (pytorch `.eugo/system_dependencies.md`): cpuinfo, FP16, XNNPACK, then pytorch."]
  test_cmd: "`ctest --test-dir build` with `-DPTHREADPOOL_BUILD_TESTS=ON -DUSE_SYSTEM_GOOGLETEST=ON` for src/include changes; the /tmp/ptp-smoke consumer `find_package(pthreadpool CONFIG REQUIRED)` build from eugo-build-and-test for the export"
```

<!-- eugo:keep:start -->
## 3. Repo-specific lessons (beat the base on conflict)

- Merging or committing here is always safe for downstream; the pin decouples adoption. Conversely, a local rebuild proves nothing about downstream until the pin moves.
- The bazel/confu/configure.py files are upstream's build flows we never consume — keep them in sync with upstream on merges, never build with them.

<!-- migrated verbatim from .claude/skills/eugo-rebuild/SKILL.md @ f119580 (athena wave 2, 2026-08-29) -->
### Related

- eugo-build-and-test - canonical flags, artifact checklist, consumer smoke
- eugo-cmake-review - pre-commit checklist for build-file changes
- eugo-upstream-merge - merge recipe + full pin-bump/adoption flow
<!-- eugo:keep:end -->
