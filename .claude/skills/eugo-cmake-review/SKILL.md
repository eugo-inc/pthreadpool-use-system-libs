---
name: eugo-cmake-review
description: Pre-commit review checklist for CMake changes in the Eugo pthreadpool fork - the USE_SYSTEM_* option discipline, the export/install machinery that must not regress, the consumer-setup regex coupling, and the two-mode configure verification. Activates on "review pthreadpool cmake", "check CMakeLists change", "pre-commit cmake audit", "validate pthreadpool build files", "USE_SYSTEM regression".
---

# Eugo CMake review (pthreadpool, pre-commit)

`CMakeLists.txt` here IS the fork - every eugo divergence from google/pthreadpool
lives in it plus `cmake/pthreadpool-config.cmake.in`. Unlike the pytorch fork,
there are NO `@EUGO_CHANGE` annotations in this repo; the divergence is tracked
only by the inventory in the eugo-upstream-merge skill. If your change adds,
removes, or moves a divergence, update that inventory in the same commit.

## Checklist

1. **USE_SYSTEM_* options intact.** `USE_SYSTEM_LIBS` (default OFF, upstream-
   friendly) plus `USE_SYSTEM_FXDIV` / `USE_SYSTEM_GOOGLETEST` /
   `USE_SYSTEM_GOOGLEBENCHMARK`, each defaulting to `${USE_SYSTEM_LIBS}`.
   Do not flip defaults to ON - the fork must still build standalone like
   upstream does.
2. **Both branches of every dep guarded.** Each dependency has
   `FIND_PACKAGE(... REQUIRED)` under `USE_SYSTEM_*`, and the download path
   (`CONFIGURE_FILE(cmake/Download*.cmake ...)` + `EXECUTE_PROCESS`) only in the
   ELSE branch. The `ADD_SUBDIRECTORY` fallbacks further down must keep their
   `NOT TARGET x AND NOT USE_SYSTEM_*` guards - dropping one silently vendors a
   dep even in system mode.
3. **Export/install machinery must not regress.** This is why the fork exists:
   - `pthreadpool_interface` keeps `$<BUILD_INTERFACE:...>` /
     `$<INSTALL_INTERFACE:include>` includes and is installed into
     `${CMAKE_PROJECT_NAME}Targets`.
   - `CONFIGURE_PACKAGE_CONFIG_FILE` + `INSTALL(EXPORT ...)` emit
     `${CMAKE_INSTALL_LIBDIR}/cmake/pthreadpool/pthreadpool-config.cmake`.
   - `cmake/pthreadpool-config.cmake.in` keeps `find_dependency(FXdiv)` -
     removing it breaks pytorch's `find_package(pthreadpool CONFIG REQUIRED)`
     at pytorch-configure time, not here.
4. **Consumer regex coupling.** protomolecule's `setup` patches these EXACT
   lines with `eugo_patch_or_die`:
   `SET(CMAKE_C_STANDARD 11)`, `SET(CMAKE_C_EXTENSIONS NO)`,
   `SET(CMAKE_CXX_STANDARD 11)`, `SET(CMAKE_CXX_EXTENSIONS NO)`.
   If your diff (or an upstream merge) reworks the "Language options" block,
   the downstream build fails loudly at patch time - update the setup regexes
   in the same adoption PR that bumps the pin.
5. **Flags that must keep working** (the canonical protomolecule invocation
   uses them): `PTHREADPOOL_LIBRARY_TYPE=shared`,
   `PTHREADPOOL_SYNC_PRIMITIVE=futex`, `PTHREADPOOL_ALLOW_DEPRECATED_API=ON`,
   `PTHREADPOOL_ENABLE_FASTPATH` overridable per-arch (ON x86_64 / OFF aarch64).
6. **Stay close to upstream.** Every divergent line is merge-conflict debt for
   the next `git merge upstream/main` (see eugo-upstream-merge). Prefer the
   smallest diff that works; adopt upstream shapes where possible.

## Verify (both modes, then the install tree)

```bash
# System mode (eugo container; needs system FXdiv)
cmake -B build-sys -G Ninja -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON \
  -DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_BUILD_TESTS=OFF \
  -DPTHREADPOOL_BUILD_BENCHMARKS=OFF -DCMAKE_INSTALL_PREFIX="$PWD/out"
cmake --build build-sys && cmake --install build-sys
test -f out/lib*/cmake/pthreadpool/pthreadpool-config.cmake || echo "REGRESSION"

# Upstream-default mode (network; proves we did not break standalone builds)
cmake -B build-def -G Ninja
```

If both configures pass and the config file lands in the install tree, the
change is safe to commit. For anything touching the divergence inventory,
finish with the eugo-upstream-merge skill's sanity notes.

## Related

- eugo-build-and-test - canonical flags + consumer smoke test
- eugo-rebuild - whether this change forces a downstream pin bump
- eugo-upstream-merge - divergence inventory (keep it current)
