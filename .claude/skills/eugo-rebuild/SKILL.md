---
name: eugo-rebuild
description: Decide what level of rebuild a change to the Eugo pthreadpool fork actually requires, and when the downstream protomolecule package must be rebuilt or pin-bumped. Activates on "rebuild pthreadpool", "do I need to rebuild", "pthreadpool pin bump", "does this change reach downstream", "pthreadpool configure check".
---

# eugo-rebuild (pthreadpool)

The local build takes seconds, so the cheap/expensive split here is not compile
time - it is whether the change must propagate downstream (push + protomolecule
pin bump + rebuilding consumers).

## Decision table (first matching row wins)

| Files changed | Action |
|---------------|--------|
| Docs, `.devcontainer/`, `.mcp.json`, `.claude/`, `.github/` | Nothing. Not part of the built artifact. |
| `CMakeLists.txt`, `cmake/*.cmake`, `cmake/pthreadpool-config.cmake.in` | Configure check with the canonical flags (see eugo-build-and-test), then full build + install-tree check. Also run eugo-cmake-review. |
| `src/**`, `include/**` | Full build; build with `-DPTHREADPOOL_BUILD_TESTS=ON -DUSE_SYSTEM_GOOGLETEST=ON` and run `ctest --test-dir build`. |
| `test/**`, `bench/**`, `examples/**` only | Build with tests/benchmarks ON and run them. Does not affect the shipped library. |
| `BUILD.bazel`, `MODULE.bazel`, `WORKSPACE`, `confu.yaml`, `configure.py` | Nothing for eugo (we only consume the CMake flow). Keep in sync with upstream on merges. |

## When downstream must move

Nothing reaches any eugo build until BOTH happen:

1. The commit is pushed to GitHub `master` (the protomolecule `setup` curls the
   archive tarball for the pinned commit - unpushed SHAs 404).
2. `protomolecule/dependencies/native/pthreadpool/meta.json` `version.commit`
   is bumped to that SHA.

So: merging or committing here is always safe for downstream; the pin decouples
adoption. Conversely, a local rebuild here proves nothing about downstream until
the pin moves.

After a pin bump, rebuild the coupled set if their pinned versions moved
together (see pytorch `.eugo/system_dependencies.md`): cpuinfo, FP16, XNNPACK,
then pytorch. If you touched the `SET(CMAKE_C_STANDARD 11)` /
`SET(CMAKE_*_EXTENSIONS NO)` lines, verify the four `eugo_patch_or_die` regexes
in the protomolecule `setup` still match BEFORE bumping the pin.

## Related

- eugo-build-and-test - canonical flags, artifact checklist, consumer smoke
- eugo-cmake-review - pre-commit checklist for build-file changes
- eugo-upstream-merge - merge recipe + full pin-bump/adoption flow
