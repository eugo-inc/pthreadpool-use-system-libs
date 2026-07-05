---
name: eugo-build-and-test
description: Build and smoke-test the Eugo pthreadpool fork (eugo-inc/pthreadpool-use-system-libs) the way protomolecule actually builds it - the setup-script flow (tarball fetch, C-standard patching, platform fastpath flags, the canonical cmake invocation), the local in-container build, and the artifact checklist that proves the install tree is healthy. Activates on "build pthreadpool", "test pthreadpool", "pthreadpool cmake configure", "smoke test pthreadpool", "pthreadpool install tree", "verify pthreadpool-config.cmake".
---

# Build & test eugo pthreadpool

This fork exists for ONE reason: upstream google/pthreadpool cannot use a system
FXdiv and does not install a CMake package config. Our CMakeLists.txt adds
`USE_SYSTEM_*` options and export/install machinery so consumers can
`find_package(pthreadpool CONFIG REQUIRED)`. PyTorch does exactly that via
`USE_SYSTEM_PTHREADPOOL=ON` (see `@EUGO_CHANGE` in pytorch `cmake/Dependencies.cmake`).
A build that does not produce `lib/cmake/pthreadpool/pthreadpool-config.cmake`
is a failed build, even if `libpthreadpool.so` compiled fine.

## How eugo actually builds it (protomolecule flow, distilled)

Ground truth: `protomolecule/dependencies/native/pthreadpool/{meta.json,setup}`.

1. **Fetch**: curls `https://github.com/eugo-inc/pthreadpool-use-system-libs/archive/<commit>.tar.gz`
   for the commit pinned in `meta.json` (`version.commit`, branch `master`).
   Unpushed commits 404 - always push before bumping the pin.
2. **Patch**: four `eugo_patch_or_die` regexes rewrite the "Language options"
   block: `SET(CMAKE_C_STANDARD 11)` -> `${EUGO_C_STANDARD}`, extensions NO -> YES,
   same for CXX. These are NORMAL variables that would otherwise shadow the
   `-DCMAKE_*_STANDARD` cache entries from `EUGO_CMAKE_COMMON_OPTIONS`.
3. **Platform flags**: `PTHREADPOOL_ENABLE_FASTPATH=ON` on x86_64, `OFF` on aarch64.
4. **Configure + build**: `cmake .. ${EUGO_CMAKE_COMMON_OPTIONS}` plus the flags
   below, then `ninja` and `ninja install`.

Canonical flag set (the load-bearing ones):

```
-DPTHREADPOOL_LIBRARY_TYPE=shared
-DPTHREADPOOL_SYNC_PRIMITIVE=futex        # Linux
-DPTHREADPOOL_ALLOW_DEPRECATED_API=ON
-DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON
-DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF
```

## Local build (in the eugo container)

The container has the system FXdiv package (protomolecule `native/fxdiv`, built
from the ConnorBaker/FXdiv fork which adds an installable CMake config - upstream
FXdiv has none). Outside the container `FIND_PACKAGE(FXdiv REQUIRED)` fails;
either install FXdiv the same way or drop `USE_SYSTEM_FXDIV` to let CMake
download it (network required, and it bypasses the system-libs path this fork
exists to provide - fine for compile checks only).

```bash
cmake -B build -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PWD/out" \
  -DPTHREADPOOL_LIBRARY_TYPE=shared -DPTHREADPOOL_SYNC_PRIMITIVE=futex \
  -DPTHREADPOOL_ALLOW_DEPRECATED_API=ON \
  -DUSE_SYSTEM_LIBS=ON -DUSE_SYSTEM_FXDIV=ON \
  -DPTHREADPOOL_BUILD_TESTS=OFF -DPTHREADPOOL_BUILD_BENCHMARKS=OFF
cmake --build build && cmake --install build
```

To run the unit tests, add `-DPTHREADPOOL_BUILD_TESTS=ON -DUSE_SYSTEM_GOOGLETEST=ON`
and run `ctest --test-dir build` (two suites: `pthreadpool`, `pthreadpool-cxx`).
The whole build takes seconds - there is no reason to skip it.

## What healthy looks like

Install-tree checklist (under the prefix; libdir may be `lib` or `lib64`):

- `lib*/libpthreadpool.so`
- `include/pthreadpool.h`
- `lib*/cmake/pthreadpool/pthreadpool-config.cmake` AND `pthreadpoolTargets.cmake`
  (the config is generated from `cmake/pthreadpool-config.cmake.in`, which must
  keep its `find_dependency(FXdiv)` line)

Consumer smoke (proves the export actually resolves, which is the fork's job):

```bash
mkdir -p /tmp/ptp-smoke && cd /tmp/ptp-smoke
printf 'cmake_minimum_required(VERSION 3.5)\nproject(s C)\nfind_package(pthreadpool CONFIG REQUIRED)\nadd_executable(s s.c)\ntarget_link_libraries(s pthreadpool)\n' > CMakeLists.txt
printf '#include <pthreadpool.h>\nint main(void){pthreadpool_t p=pthreadpool_create(2);pthreadpool_destroy(p);return 0;}\n' > s.c
cmake -B b -G Ninja -DCMAKE_PREFIX_PATH=<install-prefix> && cmake --build b && ./b/s
```

## Related

- eugo-rebuild - what a given diff actually requires
- eugo-cmake-review - pre-commit checklist for CMakeLists.txt changes
- eugo-upstream-merge - divergence inventory + the protomolecule pin-bump flow
