---
name: eugo-upstream-merge
description: Merge upstream google/pthreadpool into the Eugo fork eugo-inc/pthreadpool-use-system-libs (branch eugo-main). Covers the fork's divergence inventory, the merge-commit-only recipe, and the protomolecule commit-pin bump. Activates on "merge upstream", "upstream sync", "pthreadpool sync", "update pthreadpool fork", "bump pthreadpool".
---

# Merging upstream pthreadpool into eugo-inc/pthreadpool-use-system-libs

## What this fork is / who consumes it

- Upstream is https://github.com/google/pthreadpool (`main`). It was originally
  Maratyszcza/pthreadpool; Google took over and GitHub support re-parented this fork.
- Canonical branch here is `eugo-main`. Prior syncs are merge commits
  from `google:main` (e.g. `be3c5e9`, `8c5da84`).
- Consumer: `protomolecule/dependencies/native/pthreadpool` (meta.json pins
  `kind: git_commit`, `branch: eugo-main`, currently `8c5da84`). The pin decouples
  merge from adoption: merging/pushing here changes nothing downstream until the
  meta.json commit is bumped. Its `setup` downloads the GitHub archive tarball for
  the pinned commit, so the commit MUST be pushed to GitHub before it is pinned.
- PyTorch consumes the installed package via `USE_SYSTEM_PTHREADPOOL=ON` ->
  `find_package(pthreadpool CONFIG REQUIRED)` (@EUGO_CHANGE in
  `cmake/Dependencies.cmake`). That CONFIG file only exists because of this fork.
- Version coupling: XNNPACK <-> cpuinfo <-> pthreadpool <-> FP16 (see pytorch
  `.eugo/system_dependencies.md` section 3). A pthreadpool bump may force XNNPACK
  and friends to move together; check XNNPACK's pinned commit expectations.

## Eugo divergence inventory (protect these in conflicts)

1. `CMakeLists.txt` -- the reason the fork exists (from Maratyszcza PR #27,
   ConnorBaker's use-system-libs work, adapted):
   - `OPTION(USE_SYSTEM_LIBS / USE_SYSTEM_FXDIV / USE_SYSTEM_GOOGLETEST /
     USE_SYSTEM_GOOGLEBENCHMARK ...)` near the top.
   - `FIND_PACKAGE(FXdiv REQUIRED)` / `FIND_PACKAGE(GTest)` / `FIND_PACKAGE(benchmark)`
     branches guarding each Download*.cmake path, plus `AND NOT USE_SYSTEM_*`
     guards on the `ADD_SUBDIRECTORY` fallbacks.
   - Export/install machinery: `pthreadpool_interface` gets
     BUILD_INTERFACE/INSTALL_INTERFACE includes and is installed into
     `${CMAKE_PROJECT_NAME}Targets`; `CONFIGURE_PACKAGE_CONFIG_FILE` +
     `INSTALL(EXPORT ...)` emit `lib/cmake/pthreadpool/pthreadpool-config.cmake`.
2. `cmake/pthreadpool-config.cmake.in` -- Eugo-added file: `find_dependency(FXdiv)`
   then includes `pthreadpoolTargets.cmake`.
3. `.devcontainer/` (Dockerfile, devcontainer.json, post-create.sh) and `.mcp.json`
   -- Eugo devcontainer infra (PR #2). No upstream counterpart; keep ours.
4. No `@EUGO_CHANGE` annotations exist in this repo; the divergence is only
   discoverable via `git log` and this inventory.

Fragile coupling with the consumer's setup script: protomolecule's `setup` runs
`eugo_patch_or_die` regexes against `SET(CMAKE_C_STANDARD 11)`,
`SET(CMAKE_C_EXTENSIONS NO)`, `SET(CMAKE_CXX_STANDARD 11)`,
`SET(CMAKE_CXX_EXTENSIONS NO)` in CMakeLists.txt. If upstream reworks those lines,
the downstream build fails loudly at patch time -- update the setup regexes in the
same adoption PR.

## Merge recipe (merge, never rebase; merge commit, never squash)

```bash
git clone git@github.com:eugo-inc/pthreadpool-use-system-libs.git && cd pthreadpool-use-system-libs
git remote add upstream https://github.com/google/pthreadpool.git
git fetch upstream
git checkout -b <user>/feat/MM-DD-YY-merge-upstream eugo-main
git merge upstream/main        # resolve conflicts per inventory above
```

- Conflicts will concentrate in `CMakeLists.txt`. Re-apply the USE_SYSTEM_* and
  export/install blocks around whatever upstream restructured; adopt upstream's
  side everywhere else (src/, include/, BUILD.bazel, tests).
- Sanity check: configure with `-DUSE_SYSTEM_FXDIV=ON -DPTHREADPOOL_LIBRARY_TYPE=shared`
  and confirm the install tree contains `lib/cmake/pthreadpool/pthreadpool-config.cmake`.
- Open a PR to `eugo-main` and land it with the MERGE-COMMIT method only. Squash
  destroys the upstream ancestry that future `git merge upstream/main` relies on.

## Post-merge adoption (protomolecule)

1. Push the merged `eugo-main` to GitHub FIRST -- the setup script curls
   `https://github.com/eugo-inc/pthreadpool-use-system-libs/archive/<commit>.tar.gz`;
   an unpushed commit 404s the build.
2. Bump `protomolecule/dependencies/native/pthreadpool/meta.json` -> `version.commit`
   to the new merge-commit SHA on `eugo-main`.
3. Verify the four `eugo_patch_or_die` regexes in `setup` still match, and rebuild
   the coupled set if versions moved: cpuinfo, FP16, XNNPACK, then pytorch.
