---
name: eugo-upstream-merge
description: >-
  Merge upstream into this eugo fork — loads eugo-upstream-merge-base from athena's skill catalog over MCP and applies this repo's divergence inventory, per-file conflict recipes, and pin-bump targets. Dated sync branch, merge-not-rebase, ownership-class resolution, @EUGO_CHANGE marker discipline, the dropped-fix + scope gates, merge-commit-only landing, push-before-pin adoption. Activates on "merge upstream", "upstream sync", "catch up to upstream", "sync the fork", "resolve EUGO_CHANGE conflicts", "bump the pin after the merge", or /eugo-upstream-merge.
---

# eugo-upstream-merge — pthreadpool-use-system-libs adapter (thin)

Thin adapter over the shared base `eugo-upstream-merge-base` in athena's skill catalog,
served by the `eugo-kb` MCP server. The workflow lives in the base — do
NOT improvise from this file alone.

## 1. Load the base

1. Call `get_skill("eugo-upstream-merge-base")` on `eugo-kb` and follow it, substituting
   every `{{param}}` placeholder with the values in §2. Fetch companion
   files it names on demand via `get_skill_file("eugo-upstream-merge-base", "<path>")`.
2. Fallback (eugo-kb unavailable): read
   `.claude/skills/_pulled/eugo-upstream-merge-base/SKILL.md` — refreshed with
   `eugo-skills pull --from <athena> --cache --name eugo-upstream-merge-base`.
3. If neither exists: STOP and tell the user to wire eugo-kb (see
   athena `docs/skills/CONSUMING.md`). Never run the workflow from
   memory.

## 2. Parameters (this repo's values)

```yaml
# adapter-params v1
base: eugo-upstream-merge-base
params:
  build_cmd: "configure with `-DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_LIBRARY_TYPE=shared` (the canonical flags from eugo-build-and-test) and build + install"
  fork_name: "eugo-inc/pthreadpool-use-system-libs, branch eugo-main (fork of google/pthreadpool — prior syncs are merge commits from google:main, e.g. be3c5e9, 8c5da84)"
  invariants: ["divergence inventory (protect in conflicts): (1) `CMakeLists.txt` — the reason the fork exists (from Maratyszcza PR #27 / ConnorBaker's use-system-libs work, adapted): `OPTION(USE_SYSTEM_LIBS / USE_SYSTEM_FXDIV / USE_SYSTEM_GOOGLETEST / USE_SYSTEM_GOOGLEBENCHMARK ...)` near the top; `FIND_PACKAGE(FXdiv REQUIRED)` / `FIND_PACKAGE(GTest)` / `FIND_PACKAGE(benchmark)` branches guarding each Download*.cmake path plus `AND NOT USE_SYSTEM_*` guards on the ADD_SUBDIRECTORY fallbacks; the export/install machinery — `pthreadpool_interface` gets BUILD_INTERFACE/INSTALL_INTERFACE includes and is installed into `${CMAKE_PROJECT_NAME}Targets`, `CONFIGURE_PACKAGE_CONFIG_FILE` + `INSTALL(EXPORT ...)` emit `lib/cmake/pthreadpool/pthreadpool-config.cmake`; (2) `cmake/pthreadpool-config.cmake.in` — eugo-added: `find_dependency(FXdiv)` then includes pthreadpoolTargets.cmake; (3) `.devcontainer/` (Dockerfile, devcontainer.json, post-create.sh), `.mcp.json`, `.claude/`, `.eugo.toml` — eugo infra, no upstream counterpart, keep ours; (4) NO `@EUGO_CHANGE` annotations exist in this repo — the divergence is only discoverable via `git log` and this inventory.", "fragile coupling with the consumer: protomolecule's `setup` runs `eugo_patch_or_die` regexes against `SET(CMAKE_C_STANDARD 11)`, `SET(CMAKE_C_EXTENSIONS NO)`, `SET(CMAKE_CXX_STANDARD 11)`, `SET(CMAKE_CXX_EXTENSIONS NO)` in CMakeLists.txt; if upstream reworks those lines the downstream build fails loudly at patch time — update the setup regexes in the same adoption PR.", "pytorch consumes the installed package via `USE_SYSTEM_PTHREADPOOL=ON` -> `find_package(pthreadpool CONFIG REQUIRED)` (@EUGO_CHANGE in pytorch cmake/Dependencies.cmake); that CONFIG file only exists because of this fork."]
  merge_notes: ["`git remote add upstream https://github.com/google/pthreadpool.git && git fetch upstream && git checkout -b <user>/feat/MM-DD-YY-merge-upstream eugo-main && git merge upstream/main` — merge, never rebase; conflicts concentrate in CMakeLists.txt: re-apply the USE_SYSTEM_* and export/install blocks around whatever upstream restructured; adopt upstream's side everywhere else (src/, include/, BUILD.bazel, tests).", "PR to eugo-main, landed with the MERGE-COMMIT method only — squash destroys the upstream ancestry that future `git merge upstream/main` relies on."]
  pins: ["protomolecule/dependencies/native/pthreadpool/meta.json `version.commit` (kind git_commit, branch eugo-main) — push the merged eugo-main to GitHub FIRST (the setup curls the archive tarball; an unpushed commit 404s), then bump to the new merge-commit SHA, verify the four eugo_patch_or_die regexes still match, and rebuild the coupled set if versions moved: cpuinfo, FP16, XNNPACK, then pytorch (XNNPACK <-> cpuinfo <-> pthreadpool <-> FP16 coupling, pytorch .eugo/system_dependencies.md §3 — check XNNPACK's pinned commit expectations)."]
  test_cmd: "confirm the install tree contains `lib*/cmake/pthreadpool/pthreadpool-config.cmake`; the /tmp/ptp-smoke consumer build; `ctest --test-dir build` with tests ON for src/include conflicts"
  upstream_ref: "upstream/main"
  upstream_remote: "https://github.com/google/pthreadpool.git (remote name `upstream`)"
```

<!-- eugo:keep:start -->
## 3. Repo-specific lessons (beat the base on conflict)

- Conflicts concentrate in `CMakeLists.txt`: re-apply the `USE_SYSTEM_*` and export/install blocks around whatever upstream restructured; adopt upstream's side everywhere else (`src/`, `include/`, `BUILD.bazel`, tests). With no markers, the inventory in §2 is the only map of what is ours.
- Sanity check after resolving: configure with `-DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_LIBRARY_TYPE=shared` and confirm the install tree contains `lib/cmake/pthreadpool/pthreadpool-config.cmake`.
- Version coupling XNNPACK <-> cpuinfo <-> pthreadpool <-> FP16: check XNNPACK's pinned commit expectations before adopting a bump.
<!-- eugo:keep:end -->
