# Public API reference

The supported Starlark entry point is:

```starlark
load("@stage2.bzl//:defs.bzl", ...)
```

The `@stage2.bzl//internal` package is internal. Its rules,
labels, scripts, and log formats may change without notice. Public
tree inputs are exposed through `@stage2.bzl//trees:*`.

## Build macros

### `stage2_autotools_build`

Runs `configure`, `make`, and `make install` in the empty sandbox and
returns an install-tree artifact named after the target.

Unless overridden, this macro and `stage2_run` both use
`@stage2.bzl//trees:default_userland`; custom trees must satisfy the
[userland contract](#userland-contract).

```starlark
stage2_autotools_build(
    name = "hello",
    configure = "@hello_src//:configure",
    configure_args = ["--disable-nls"],
    srcs = "@hello_src//:srcs",
)
```

| parameter | default | meaning |
|---|---:|---|
| `name` | required | Bazel target name and output-tree name. |
| `srcs` | required | Label for the complete source tree. |
| `configure` | required | Label resolving to one configure script. |
| `configure_args` | `[]` | Individual configure arguments. `%{OUT}` is supported; see [Token substitution](#token-substitution). |
| `stage_cc` | `True` | Append `STAGE_CC` to `configure_args`. Set `False` when configure must select host-prefixed tools or when supplying a different `CC`/`CXX`. |
| `path_trees` | `[]` | Install trees whose `bin/` directories join `PATH`, in list order. |
| `use_default_cc` | `True` | Append `@stage2.bzl//trees:cc` after caller `path_trees`. Caller trees therefore retain precedence. |
| `install_base` | `[]` | Trees copied into the output prefix before the build, in list order. This is useful for installing GCC over binutils. |
| `jobs` | `4` | Value passed to the action's `make -j`. |
| `prefix_subdir` | `""` | Install below `<output>/<prefix_subdir>` instead of at the output root. Do not pass a second `--prefix` manually. |
| `make_targets` | `""` | Space-separated build targets; empty means make's default target. |
| `install_targets` | `"install"` | Space-separated targets used by the install step. |
| `userland` | `@stage2.bzl//trees:default_userland` | Shell and command tree shared by default with `stage2_run`. Override it with a tree satisfying the [userland contract](#userland-contract). |

The macro supplies architecture-selected internal values for
`CC_FOR_BUILD`, `CXX_FOR_BUILD`, and the stage-2 tool subdirectory. They
are not separate public configuration knobs.

`stage_cc = False` is important for more than Canadian crosses. An
Autoconf invocation such as `--host=x86_64-w64-mingw32` may deliberately
search `PATH` for `x86_64-w64-mingw32-gcc`; adding an explicit stage-2
`CC` would suppress that search.

### `stage2_run`

Runs an arbitrary Bash body in the empty sandbox. Unlike the Autotools
macro, it does not add the default compiler tree to `PATH`; scripts must
state tool trees explicitly. Its default
`@stage2.bzl//trees:default_userland` is the same tree used by
`stage2_autotools_build`; an override must satisfy the
[userland contract](#userland-contract).

```starlark
stage2_run(
    name = "hello-static",
    inputs = {"SRC": ":hello.c"},
    path_trees = ["@stage2.bzl//trees:cc"],
    script = "$CC_FOR_BUILD %{SRC} -static -o %{OUT}\n",
)
```

| parameter | default | meaning |
|---|---:|---|
| `name` | required | Bazel target name. Also the default output name. |
| `script` | required | Bash body run with `set -eu` from an empty scratch build directory after the sandbox preamble. |
| `inputs` | `{}` | Token-to-label map. Every label must resolve to exactly one file or tree and becomes available as `%{TOKEN}`. |
| `extra_inputs` | `[]` | Additional declared inputs that receive no token substitution. Prefer `inputs` when the script needs a path. |
| `out` | `name` | Output file name. |
| `out_tree` | `False` | If true, declare the target output as a directory tree rather than a file. |
| `path_trees` | `[]` | Trees whose `bin/` directories join `PATH`. Add `@stage2.bzl//trees:cc` explicitly when needed. |
| `jobs` | `4` | Integer exposed to the script as `%{JOBS}`. |
| `userland` | `@stage2.bzl//trees:default_userland` | Shell and command tree shared by default with `stage2_autotools_build`. Override it with a tree satisfying the [userland contract](#userland-contract). |

The preamble exports architecture-selected `CC_FOR_BUILD` and
`CXX_FOR_BUILD`. Those commands only resolve when the corresponding
compiler tree is present on `PATH`.

### `stage2_tree_merge`

Copies install trees into one output tree. Entries are processed in list
order; later trees win on path conflicts.

```starlark
stage2_tree_merge(
    name = "extended-userland",
    trees = [
        "@stage2.bzl//trees:default_userland",
        ":m4",
    ],
)
```

| parameter | default | meaning |
|---|---:|---|
| `name` | required | Bazel target name and output-tree name. |
| `trees` | required | Ordered list of directory trees to merge. |
| `userland` | `@stage2.bzl//trees:default_userland` | Userland used to perform the copy operation. |

### `stage2_dist_tarball`

Packages an install tree as a reproducible gzip-compressed tar archive.
It copies the input, sets entry timestamps to the Unix epoch, and sorts
archive entries by name.

```starlark
stage2_dist_tarball(
    name = "dist",
    out = "hello.tar.gz",
    tree = ":hello",
)
```

| parameter | default | meaning |
|---|---:|---|
| `name` | required | Bazel target name. |
| `tree` | required | One input install tree. |
| `out` | `<name>.tar.gz` | Output archive name. |
| `userland` | `@stage2.bzl//trees:default_userland` | Userland used to normalize and archive the tree. It must meet the extra requirements below. |

### `stage2_gcc`

Builds a Linux-hosted bare-metal GCC/newlib cross toolchain.

```starlark
stage2_gcc(
    name,
    target,
    gcc_args = [],
    gcc_version = "15.2.0",
)
```

The macro creates:

- `<name>-binutils`, a binutils 2.45 install tree for `target`;
- `<name>`, a GCC 15.2.0 and newlib 4.5.0 tree installed over binutils;
- `dist`, the archive `<name>-<gcc_version>.tar.gz`.

`gcc_args` are additional GCC top-level configure arguments.
`gcc_version` controls the archive file name; changing it does not select
a different source archive. Only one call may appear in a Bazel package
because the generated `dist` target has a fixed name.

### `stage2_gcc_w64`

Builds the Windows-hosted Canadian-cross variant of `stage2_gcc`.

```starlark
stage2_gcc_w64(
    name,
    target,
    host_toolchain,
    target_toolchain,
    gcc_args = [],
    gcc_version = "15.2.0",
)
```

`host_toolchain` is a Linux-hosted build-to-x86_64-w64-mingw32 compiler
tree. `target_toolchain` is a Linux-hosted build-to-target GCC tree of
the same GCC version. It builds target libraries because the newly
produced Windows `xgcc` cannot execute on the Linux build host.

The macro creates `<name>-binutils`, `<name>`, `<name>-pe-check`, and
`dist`. The check validates the installed executables as x86_64 PE
images without executing them.

## Token substitution

Tokens are textual placeholders with the exact spelling `%{TOKEN}`.

### Autotools configure arguments

Within each `stage2_autotools_build.configure_args` string:

- `%{OUT}` expands to the absolute path of that target's output tree.

It is useful for flags whose paths are embedded in a result that a later
action will execute, such as `--with-sysroot=%{OUT}/sysroot`.

### `stage2_run` scripts

Within `stage2_run.script`:

- `%{OUT}` expands to the absolute output file or tree path.
- `%{JOBS}` expands to the decimal `jobs` value.
- `%{NAME}` expands to the absolute path of the single artifact mapped
  from `"NAME"` by `inputs`.

`OUT` and `JOBS` are reserved token names. File-token names should be
unique, uppercase identifiers. Substitution is textual, not a shell
template language; unknown tokens remain unchanged. The built-in path
expansions are emitted as shell-safe words rooted at the sandbox
execroot. Quote surrounding shell syntax normally, and do not use `eval`
to reinterpret a substituted value.

## Userland contract

A custom `userland` is one directory tree placed ahead of tool trees on
`PATH`. The minimal userland composed from this library's public
components is Bash plus coreutils:

```starlark
stage2_tree_merge(
    name = "minimal-userland",
    trees = [
        "@stage2.bzl//trees:bash",
        "@stage2.bzl//trees:coreutils",
    ],
)
```

Bash supplies the shell; coreutils supplies the remaining baseline
commands, including `mkdir`, `ln`, `install`, and `cp`. The sandbox
preamble itself requires only:

- `bin/bash`, which is executed directly;
- `bin/mkdir` and `bin/ln`, which create the scratch directories and
  ephemeral `sh` links.

Do not interpret that file-level contract as a recommendation to
extract individual executables into separate userland targets. Bash
plus coreutils is the supported minimal composition. Beyond it,
contents follow the selected rule and the consumer's build flow.
`stage2_autotools_build` requires `bin/make` and exports
`bin/install -c` through `INSTALL`; the configured package needs
`bin/install` when its install rules invoke that variable.
`stage2_run` needs only the additional commands its script
invokes. `stage2_tree_merge` needs `cp`; `stage2_autotools_build` also
needs it when `install_base` is non-empty; and `stage2_dist_tarball`
needs `cp`, `find`, `touch`, `tar`, and `gzip`.

The default userland contains Bash 5.3, coreutils 9.7 (including
`hostname`), sed 4.9, grep 3.11, findutils 4.10.0, diffutils 3.12, tar
1.35, gzip 1.14, gawk 5.3.2, and GNU make 4.4.1. It supplies those
packages' normally installed programs; compilers, binutils, CMake,
Python, m4, bison, flex, patch, pkg-config, and Perl are separate tools.

The library cannot verify a custom tree's provenance. Merging public
userland components and trees produced by stage2 actions preserves the
zero-prebuilt-input property. Supplying a foreign prebuilt tool is a
consumer-controlled breach of it.

## Constants

The following values are exported from `defs.bzl`. Architecture-selected
values support Linux `x86_64` and `aarch64`; analysis fails with an
actionable message on other execution CPUs.

### `STAGE_CC`

Configure assignments for the stage-2 compiler:

| execution CPU | value |
|---|---|
| `x86_64` | `CC=x86_64-unknown-linux-musl-gcc -static`, `CXX=x86_64-unknown-linux-musl-g++ -static` |
| `aarch64` | `CC=aarch64-unknown-linux-musl-gcc -static`, `CXX=aarch64-unknown-linux-musl-g++ -static` |

### `OPT_FLAGS`

```text
CFLAGS=-O2
CXXFLAGS=-O2
LDFLAGS=--static
```

`--static` is intentional: libtool can swallow a plain `-static` before
it reaches the compiler driver.

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

### `BUILD_TRIPLE_ARG`

One architecture-selected argument:

| execution CPU | value |
|---|---|
| `x86_64` | `--build=x86_64-unknown-linux-musl` |
| `aarch64` | `--build=aarch64-unknown-linux-musl` |

This prevents `config.guess` from reporting a glibc-flavoured build
triple during a Canadian cross.

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

The linker option keeps PE header timestamps reproducible.

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

## Public tree labels

| label | contents |
|---|---|
| `@stage2.bzl//trees:cc` | Stage-2 native static GCC tree. |
| `@stage2.bzl//trees:default_userland` | Default merged GNU userland, including make. |
| `@stage2.bzl//trees:bsdtar` | libarchive/bsdtar extraction stack. |
| `@stage2.bzl//trees:cmake` | Source-built CMake. |
| `@stage2.bzl//trees:python` | Source-built build-interpreter CPython. |
| `@stage2.bzl//trees:clang` | Source-built Linux-native Clang/LLD tree; usable as a path tree or custom-userland component. |
| `@stage2.bzl//trees:macos-sdk` | Pruned Apple SDK containing headers and text linker stubs. |

Individual default-userland components are public at:

```text
@stage2.bzl//trees:bash
@stage2.bzl//trees:coreutils
@stage2.bzl//trees:sed
@stage2.bzl//trees:grep
@stage2.bzl//trees:findutils
@stage2.bzl//trees:diffutils
@stage2.bzl//trees:tar
@stage2.bzl//trees:gzip
@stage2.bzl//trees:gawk
@stage2.bzl//trees:make
```

The first two components, Bash and coreutils, form the minimal
library-composed userland.

Other public trees can be composed the same way. For example,
this makes the source-built Clang tools available on `PATH`:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_tree_merge")

stage2_tree_merge(
    name = "clang-userland",
    trees = [
        "@stage2.bzl//trees:default_userland",
        "@stage2.bzl//trees:clang",
    ],
)
```

The Clang tree contains compiler tools and resource headers, not a
target sysroot or runtime. Merging it does not change
`stage2_autotools_build`'s default compiler selection: selecting Clang
requires `stage_cc = False`, explicit `CC=clang` and `CXX=clang++`
configure arguments, and an appropriate target sysroot/runtime.
Normally such a target also sets `use_default_cc = False`; retain or
merge `@stage2.bzl//trees:cc` only when its musl/GCC runtime is
intentionally part of the compiler setup.

## Stability and versioning

Stable in the 1.x API:

- exports from `defs.bzl`;
- labels in `//trees`;
- the guarantee and mandatory `.bazelrc` contract documented here.

Internal action scripts, exact log text, targets under `//internal`,
targets under `//examples`, and implementation-only rule attributes are
unstable. Pinned component versions used by public macros and public tree
targets are documented and controlled by the library; their bumps are
minor releases because they can change consumer outputs.

Patch releases contain internal fixes or mirror changes that retain
identical source hashes. New exports and component-version changes are
minor releases. Changes to the guarantee, the `.bazelrc` contract, or
existing exports are major releases. Removed names retain an actionable
failure stub for one major cycle.

The module requires Bazel 9.0.0 or newer and intentionally does not set
`compatibility_level`. CI analyzes the API on both supported host
architectures with Bazel 9.0.0 and the latest Bazel release.
