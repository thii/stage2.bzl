# API reference

Load supported symbols from the repository entry point. Each example includes
the symbols it needs.

Only the parameters documented here are supported. Targets under `//internal`
and `//examples` are implementation details.

## Build macros

### `stage2_autotools_build`

Runs a conventional `configure`, `make`, and `make install` build.

```starlark
load("@stage2.bzl", "stage2_autotools_build")

stage2_autotools_build(
    name = name,
    srcs = srcs,
    configure = configure,
    configure_args = [],
    stage_cc = True,
    path_trees = [],
    use_default_cc = True,
    install_base = [],
    jobs = 4,
    prefix_subdir = "",
    make_targets = "",
    install_targets = "install",
    userland = "@stage2.bzl//trees:default_userland",
)
```

`name`, `srcs`, and `configure` are required. The output is a directory tree
named `name`.

- The rule supplies `--prefix`; use `%{OUT}` in other configure arguments that
  need the output path.
- The `bin` directories from `path_trees` join `PATH` in list order.
- With `use_default_cc = True`, `@stage2.bzl//trees:cc` is appended to
  `path_trees`.
- With `stage_cc = True`, the selected static `CC` and `CXX` assignments are
  passed to configure. Disable it when supplying another compiler.
- `install_base` is copied into the output tree before configure and build.
- `prefix_subdir` installs below a subdirectory of the output tree.
- `jobs` is the build phase's `make -j` value; installation is not parallelized.
- `make_targets` and `install_targets` are shell words passed to `make`.
- `make` and the other shell tools come from `userland`.

### `stage2_run`

Runs a shell script in the hermetic sandbox.

```starlark
load("@stage2.bzl", "stage2_run")

stage2_run(
    name = name,
    script = script,
    inputs = {},
    extra_inputs = [],
    out = "<name>",
    out_tree = False,
    path_trees = [],
    jobs = 4,
    userland = "@stage2.bzl//trees:default_userland",
)
```

`name` and `script` are required. The script runs under `set -eu` from an empty
scratch build directory and must create its declared output. The preamble
exports the selected `CC_FOR_BUILD` and `CXX_FOR_BUILD` names, but no compiler
tree is added automatically. Add `@stage2.bzl//trees:cc` to `path_trees` to
resolve the default names.

- `inputs` maps a token name to a label that provides exactly one artifact.
- `extra_inputs` declares inputs that do not need tokens.
- The `bin` directories from `path_trees` join `PATH` in list order.
- `out` names a file output. When `out_tree = True`, the output is a directory
  named `name` and `out` is ignored.
- `%{OUT}` expands to the absolute output path and `%{JOBS}` to `jobs`.
- `%{TOKEN}` expands to the absolute path of the artifact mapped by
  `inputs["TOKEN"]`.

Tokens are textual substitutions, not shell expressions. Quote them where the
shell expects one argument. Unknown tokens remain unchanged. Each artifact may
have only one token. Do not use `OUT` or `JOBS` as `inputs` keys: those names
overwrite the built-ins.

### `stage2_tree_merge`

```starlark
load("@stage2.bzl", "stage2_tree_merge")

stage2_tree_merge(
    name = name,
    trees = trees,
    userland = "@stage2.bzl//trees:default_userland",
)
```

Merges directory trees into one output tree named `name`. Later trees overwrite
earlier ones. The userland must provide `cp`.

### `stage2_dist_tarball`

```starlark
load("@stage2.bzl", "stage2_dist_tarball")

stage2_dist_tarball(
    name = name,
    tree = tree,
    out = "<name>.tar.gz",
    userland = "@stage2.bzl//trees:default_userland",
)
```

Creates a timestamp-normalized, name-sorted `.tar.gz` archive from `tree`. The
userland must provide `cp`, `find`, `touch`, `tar`, and `gzip`.

### GCC helpers

`stage2_gcc` builds a Linux-hosted bare-metal GCC/newlib toolchain;
`stage2_gcc_w64` builds its Windows-hosted variant.

```starlark
load("@stage2.bzl", "stage2_gcc", "stage2_gcc_w64")

stage2_gcc(
    name,
    target,
    gcc_args = [],
    gcc_version = "15.2.0",
)

stage2_gcc_w64(
    name,
    target,
    host_toolchain,
    target_toolchain,
    gcc_args = [],
    gcc_version = "15.2.0",
)
```

`stage2_gcc` creates `<name>-binutils`, `<name>`, and `dist`, whose output is
`<name>-<gcc_version>.tar.gz`. `stage2_gcc_w64` also creates
`<name>-pe-check`, a structural x86_64 PE check that does not execute the
Windows programs. Because `dist` has a fixed name, call either helper at most
once per package.

The helpers build GCC 15.2.0, binutils 2.45, and newlib 4.5.0. Changing
`gcc_version` changes the distribution archive filename; it does not change the
pinned source target. `gcc_args` adds GCC configure arguments. For
`stage2_gcc_w64`, `host_toolchain` is a Linux-to-x86_64-w64-mingw32 compiler
and `target_toolchain` is a Linux-to-`target` compiler built from the same GCC
version.

## Userland

The userland is a directory tree prepended to `PATH`. The supported minimal
userland is Bash plus coreutils. The sandbox preamble specifically requires:

```text
bin/bash
bin/mkdir
bin/ln
```

Rules may need more tools:

| Rule | Additional userland tools |
| --- | --- |
| `stage2_autotools_build` | `make`, `tail`, package-specific tools, usually `install`, and `cp` with `install_base` |
| `stage2_tree_merge` | `cp` |
| `stage2_dist_tarball` | `cp`, `find`, `touch`, `tar`, `gzip` |
| `stage2_run` | Whatever its script invokes |

The default userland contains:

- Bash 5.3
- coreutils 9.7, including `hostname`
- sed 4.9
- grep 3.11
- findutils 4.10.0
- diffutils 3.12
- tar 1.35
- gzip 1.14
- gawk 5.3.2
- GNU make 4.4.1

It does not contain a compiler, binutils, CMake, or Python. Add those through
`path_trees`, or merge them into a custom userland with `stage2_tree_merge`.
Audit custom trees: using a stage2 label or wrapper alone does not establish
their provenance.

## Exported constants

These constants are string lists intended for composing GCC-family builds.
`STAGE_CC` and `BUILD_TRIPLE_ARG` are `select()` values that choose such a list
for the configured CPU.

```starlark
load(
    "@stage2.bzl",
    "BINUTILS_ARGS",
    "BUILD_TRIPLE_ARG",
    "GCC_NEWLIB_ARGS",
    "MINGW_HOST_CC",
    "OPT_FLAGS",
    "STAGE_CC",
    "W64_OPT_FLAGS",
)
```

### `STAGE_CC`

Selected by the configured CPU:

| CPU | Values |
| --- | --- |
| `x86_64` | `CC=x86_64-unknown-linux-musl-gcc -static`, `CXX=x86_64-unknown-linux-musl-g++ -static` |
| `aarch64` | `CC=aarch64-unknown-linux-musl-gcc -static`, `CXX=aarch64-unknown-linux-musl-g++ -static` |

### `BUILD_TRIPLE_ARG`

Selected by the configured CPU:

| CPU | Value |
| --- | --- |
| `x86_64` | `--build=x86_64-unknown-linux-musl` |
| `aarch64` | `--build=aarch64-unknown-linux-musl` |

### `OPT_FLAGS`

```text
CFLAGS=-O2
CXXFLAGS=-O2
LDFLAGS=--static
```

### `BINUTILS_ARGS`

```text
--disable-nls
--disable-werror
--disable-gdb
--disable-gdbserver
--disable-sim
--disable-gprofng
--disable-shared
--enable-static
--disable-dependency-tracking
```

### `MINGW_HOST_CC`

```text
CC=x86_64-w64-mingw32-gcc -static
CXX=x86_64-w64-mingw32-g++ -static
```

### `W64_OPT_FLAGS`

```text
CFLAGS=-O2
CXXFLAGS=-O2
LDFLAGS=--static -Wl,--no-insert-timestamp
```

### `GCC_NEWLIB_ARGS`

```text
--enable-languages=c,c++
--with-newlib
--disable-shared
--disable-threads
--disable-tls
--disable-nls
--disable-libssp
--disable-libquadmath
--disable-libgomp
--disable-multilib
--enable-checking=release
--disable-dependency-tracking
--disable-libstdcxx-pch
```

The explicit `--static` spellings are intentional: some libtool-generated
scripts do not preserve plain `-static`.

## Public trees

The `@stage2.bzl//trees` package provides:

| Label | Contents |
| --- | --- |
| `:cc` | Static GCC 15.2.0, musl 1.2.5, and binutils 2.45 toolchain |
| `:default_userland` | The default userland listed above |
| `:bash`, `:coreutils`, `:sed`, `:grep`, `:findutils`, `:diffutils`, `:tar`, `:gzip`, `:gawk`, `:make` | Individual default-userland components |
| `:bsdtar` | libarchive/bsdtar tree |
| `:cmake` | CMake 3.31.7 |
| `:python` | Python 3.12.8 |
| `:clang` | Clang 22.1.8 compiler, tools, and resource headers; no sysroot or runtime |
| `:macos-sdk` | Pruned macOS headers, text `.tbd` stubs, and non-executable SDK metadata |

The documented exports of `stage2.bzl`, the parameters above, and these tree
labels are the public API. Other repository targets, scripts, logs, and example
implementation details may change without notice.

stage2.bzl requires Bazel 9 or later and supports selected `x86_64` and
`aarch64` Linux builds.
