---
name: eugo-build-and-test
description: >-
  Build and smoke-test this eugo fork the way eugo actually consumes it — loads eugo-build-and-test-base from athena's skill catalog over MCP and applies this repo's build system, commands, invariants, and failure table. Configure gate first, the one canonical build command, then the MUST-PASS smoke + artifact checklist. Activates on "build the fork", "build <package>", "install the wheel", "smoke test", "run the build gate", "diagnose a build failure", or /eugo-build-and-test.
---

# eugo-build-and-test — pthreadpool-use-system-libs adapter (thin)

Thin adapter over the shared base `eugo-build-and-test-base` in athena's skill catalog,
served by the `eugo-kb` MCP server. The workflow lives in the base — do
NOT improvise from this file alone.

## 1. Load the base

1. Call `get_skill("eugo-build-and-test-base")` on `eugo-kb` and follow it, substituting
   every `{{param}}` placeholder with the values in §2. Fetch companion
   files it names on demand via `get_skill_file("eugo-build-and-test-base", "<path>")`.
2. Fallback (eugo-kb unavailable): read
   `.claude/skills/_pulled/eugo-build-and-test-base/SKILL.md` — refreshed with
   `eugo-skills pull --from <athena> --cache --name eugo-build-and-test-base`.
3. If neither exists: STOP and tell the user to wire eugo-kb (see
   athena `docs/skills/CONSUMING.md`). Never run the workflow from
   memory.

## 2. Parameters (this repo's values)

```yaml
# adapter-params v1
base: eugo-build-and-test-base
params:
  artifacts_note: "install-tree checklist under the prefix (libdir may be lib or lib64): `lib*/libpthreadpool.so`; `include/pthreadpool.h`; `lib*/cmake/pthreadpool/pthreadpool-config.cmake` AND `pthreadpoolTargets.cmake` (the config is generated from `cmake/pthreadpool-config.cmake.in`, which must keep its `find_dependency(FXdiv)` line)"
  build_cmd: "`cmake --build build && cmake --install build` after the configure above (the whole build takes seconds — never skip it). protomolecule flow (`dependencies/native/pthreadpool/{meta.json,setup}`): (1) curl `https://github.com/eugo-inc/pthreadpool-use-system-libs/archive/<commit>.tar.gz` for meta.json's version.commit (unpushed commits 404 — push before bumping); (2) four `eugo_patch_or_die` regexes rewrite the \"Language options\" block — `SET(CMAKE_C_STANDARD 11)` -> `${EUGO_C_STANDARD}`, extensions NO -> YES, same for CXX (NORMAL variables that would otherwise shadow the -DCMAKE_*_STANDARD cache entries from EUGO_CMAKE_COMMON_OPTIONS); (3) `PTHREADPOOL_ENABLE_FASTPATH=ON` on x86_64, OFF on aarch64; (4) `cmake .. ${EUGO_CMAKE_COMMON_OPTIONS}` + the canonical flags (`-DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_SYNC_PRIMITIVE=futex -DPTHREADPOOL_ALLOW_DEPRECATED_API=ON -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF`), then `ninja && ninja install`"
  build_system: "cmake + ninja — the fork exists for ONE reason: upstream cannot use a system FXdiv and does not install a CMake package config; our CMakeLists.txt adds `USE_SYSTEM_*` options and export/install machinery so consumers can `find_package(pthreadpool CONFIG REQUIRED)` (pytorch does, via `USE_SYSTEM_PTHREADPOOL=ON`). A build that does not produce `lib/cmake/pthreadpool/pthreadpool-config.cmake` is a FAILED build even if libpthreadpool.so compiled"
  configure_cmd: "`cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=\"$PWD/out\" -DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_SYNC_PRIMITIVE=futex -DPTHREADPOOL_ALLOW_DEPRECATED_API=ON -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF` in the eugo container (it has the system FXdiv package — protomolecule native/fxdiv, from the ConnorBaker/FXdiv fork that adds an installable CMake config; outside the container `FIND_PACKAGE(FXdiv REQUIRED)` fails — install FXdiv the same way, or drop USE_SYSTEM_FXDIV to let CMake download it: network required and it bypasses the system-libs path, fine for compile checks only)"
  fork_name: "eugo-inc/pthreadpool-use-system-libs, branch eugo-main (fork of google/pthreadpool, upstream main; originally Maratyszcza/pthreadpool — Google took over and GitHub re-parented this fork)"
  invariants: ["the four protomolecule patch anchors `SET(CMAKE_C_STANDARD 11)`, `SET(CMAKE_C_EXTENSIONS NO)`, `SET(CMAKE_CXX_STANDARD 11)`, `SET(CMAKE_CXX_EXTENSIONS NO)` must match `eugo_patch_or_die` exactly — a reworked Language-options block fails the downstream build loudly at patch time; update the setup regexes in the same adoption PR.", "the canonical flag set must keep working: PTHREADPOOL_LIBRARY_TYPE=shared, PTHREADPOOL_SYNC_PRIMITIVE=futex (Linux), PTHREADPOOL_ALLOW_DEPRECATED_API=ON, USE_SYSTEM_LIBS=ON + USE_SYSTEM_FXDIV=ON, tests/benchmarks OFF, PTHREADPOOL_ENABLE_FASTPATH overridable per arch (ON x86_64 / OFF aarch64).", "`cmake/pthreadpool-config.cmake.in` keeps `find_dependency(FXdiv)` — removing it breaks pytorch's `find_package(pthreadpool CONFIG REQUIRED)` at pytorch-configure time, not here."]
  pins: ["protomolecule/dependencies/native/pthreadpool/meta.json `version.commit` (kind git_commit, branch eugo-main) — the setup curls the archive tarball for the pinned commit, so push to GitHub eugo-main BEFORE bumping; merging here changes nothing downstream until the pin moves.", "version coupling (pytorch `.eugo/system_dependencies.md` §3): XNNPACK <-> cpuinfo <-> pthreadpool <-> FP16 — a pthreadpool bump may force XNNPACK and friends to move together; rebuild the coupled set in order cpuinfo, FP16, XNNPACK, then pytorch (USE_SYSTEM_PTHREADPOOL=ON, @EUGO_CHANGE in pytorch cmake/Dependencies.cmake)."]
  test_cmd: "unit tests: add `-DPTHREADPOOL_BUILD_TESTS=ON -DUSE_SYSTEM_GOOGLETEST=ON` and run `ctest --test-dir build` (two suites: `pthreadpool`, `pthreadpool-cxx`). Consumer smoke — proves the export resolves, which is the fork's job: in /tmp/ptp-smoke write a CMakeLists.txt (`cmake_minimum_required(VERSION 3.5)`, `project(s C)`, `find_package(pthreadpool CONFIG REQUIRED)`, `add_executable(s s.c)`, `target_link_libraries(s pthreadpool)`) and `s.c` (`#include <pthreadpool.h>` / `int main(void){pthreadpool_t p=pthreadpool_create(2);pthreadpool_destroy(p);return 0;}`), then `cmake -B b -G Ninja -DCMAKE_PREFIX_PATH=<install-prefix> && cmake --build b && ./b/s`"
```

<!-- eugo:keep:start -->
## 3. Repo-specific lessons (beat the base on conflict)

- A build that does not produce `lib/cmake/pthreadpool/pthreadpool-config.cmake` is a FAILED build even if `libpthreadpool.so` compiled fine — the config is the fork's whole product (pytorch's `find_package(pthreadpool CONFIG REQUIRED)` only resolves because of it).
- Outside the eugo container `FIND_PACKAGE(FXdiv REQUIRED)` fails: install FXdiv the protomolecule way (native/fxdiv, from the ConnorBaker/FXdiv fork that adds an installable CMake config — upstream FXdiv has none) or drop `USE_SYSTEM_FXDIV` for a compile-only check (network required; bypasses the system-libs path this fork exists to provide).

<!-- migrated verbatim from .claude/skills/eugo-build-and-test/SKILL.md @ f119580 (athena wave 2, 2026-08-29) -->
### Related

- eugo-rebuild - what a given diff actually requires
- eugo-cmake-review - pre-commit checklist for CMakeLists.txt changes
- eugo-upstream-merge - divergence inventory + the protomolecule pin-bump flow
<!-- eugo:keep:end -->
