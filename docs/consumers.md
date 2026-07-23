# Consumer guide

stage2.bzl is a Bazel rules library for building software from source in
an empty Linux sandbox. Actions created through its public API use a
source-built compiler, shell, GNU userland, and build tools. From stage 2
onward, no prebuilt binary is present in an action's declared inputs.

The supported execution hosts are Linux `x86_64` and `aarch64`, with user
namespaces enabled and Bazel 9 or newer. A first build normally spends
about 25–40 minutes bootstrapping the build environment; subsequent builds reuse
ordinary Bazel results. Read [Trust and verification](trust.md) for the
precise boundary of the guarantee.

## Quickstart

stage2.bzl 1.0.0 is not yet published in a public module registry. Declare
the module version and pin this repository with a `git_override` (or use
an equivalent `archive_override` or local registry):

```starlark
# MODULE.bazel
bazel_dep(name = "stage2.bzl", version = "1.0.0")
bazel_dep(name = "platforms", version = "1.1.0")

git_override(
    module_name = "stage2.bzl",
    commit = "<full commit SHA>",
    remote = "https://github.com/thii/stage2.bzl.git",
)

http_archive = use_repo_rule(
    "@bazel_tools//tools/build_defs/repo:http.bzl",
    "http_archive",
)

http_archive(
    name = "hello_src",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(["**"]),
)

exports_files(["configure"])
""",
    sha256 = "8d99142afd92576f30b0cd7cb42a8dc6809998bc5d607d88761f512e26c7db20",
    strip_prefix = "hello-2.12.1",
    urls = ["https://mirrors.kernel.org/gnu/hello/hello-2.12.1.tar.gz"],
)
```

Workspace flags do not propagate from a dependency. Copy the mandatory
sandbox contract into the consumer's `.bazelrc`:

```text
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

Then define and run the build:

```starlark
# BUILD.bazel
load(
    "@stage2.bzl//:defs.bzl",
    "stage2_autotools_build",
    "stage2_run",
)

stage2_autotools_build(
    name = "hello",
    configure = "@hello_src//:configure",
    configure_args = [
        "--disable-nls",
        "CFLAGS=-O2 -std=gnu17",
        "LDFLAGS=--static",
    ],
    srcs = "@hello_src//:srcs",
)

stage2_run(
    name = "hello-output",
    inputs = {"TREE": ":hello"},
    script = "%{TREE}/bin/hello > %{OUT}\n",
)
```

```sh
bazel build //:hello-output
cat bazel-bin/hello-output
```

`stage2_autotools_build` adds the stage-2 compiler to `PATH` and supplies
its static `CC`/`CXX` settings by default. GNU hello must keep dependency
tracking enabled: its non-recursive makefile uses `.deps` files to create
some build-directory subdirectories during this out-of-tree build.

## The `.bazelrc` contract

The four quickstart lines are part of the stable API contract:

- `--enable_platform_specific_config` activates the Linux-specific
  settings.
- `--experimental_use_hermetic_linux_sandbox` asks Bazel for the empty
  sandbox root.
- `--spawn_strategy=linux-sandbox` prevents a silent fallback to a
  non-hermetic strategy.
- `--sandbox_default_allow_network=false` removes action network access.
  The `/bin/sh` tripwire cannot detect this setting, so consumers must
  keep it explicitly.

Keep the sandbox options under `build:linux`. Bazel permits build
options under `common`, but doing so would select `linux-sandbox` for
unrelated builds on non-Linux hosts in a mixed workspace.

Do not add a sandbox mount for `/bin`, `/usr`, a host compiler, or a host
shell. That changes the trust boundary rather than fixing the build.
Remote execution is not supported in v1 because an ordinary worker image
does not provide the same empty-root contract.

### Stage2-only and mixed workspaces

In a workspace whose targets all use stage2.bzl, this optional hygiene
setting avoids probing the host for a C++ toolchain:

```text
build --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
```

Do not set it in a workspace that also builds ordinary `cc_binary`,
`cc_library`, or other targets that need Bazel's host C++ toolchain.
Those mixed workspaces should retain only the four mandatory lines and
allow normal toolchain autodetection for their non-stage2 targets. The
stage2 rules do not select or execute that detected toolchain.

## Caching and resource use

The bootstrap happens in each Bazel output base. Give multiple workspaces
an absolute shared cache path to reuse completed actions:

```sh
bazel build --disk_cache=/absolute/path/to/stage2-cache //:hello-output
```

The cache can make a new workspace's first build nearly instant when the
same stage2.bzl revision and build settings are already present. Treat a
writable shared cache as trusted: later builds may execute binaries
restored from it. Bazel's repository cache separately avoids downloading
pinned source archives again.

Each `stage2_autotools_build` action defaults to `make -j4`. If the host
is memory-constrained or the top-level build exposes several large
targets, limit Bazel scheduling as well:

```sh
bazel build --jobs=1 //:target
```

Build progress is reported per Bazel action rather than per compiler
process. On failure, the rule prints the tail of its configure, build, or
install log.

## More build patterns

### An arbitrary scripted build

`stage2_run` does not add the compiler tree to `PATH`
automatically. State every non-userland tool explicitly:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_run")

stage2_run(
    name = "hello-static",
    inputs = {"SRC": ":hello.c"},
    path_trees = ["@stage2.bzl//trees:cc"],
    script = "$CC_FOR_BUILD %{SRC} -O2 -static -o %{OUT}\n",
)
```

The output is a file named `hello-static`. Set `out_tree = True` when a
script produces a directory tree instead.

### A custom embedded GCC

The library owns and pins GCC 15.2.0, binutils 2.45, newlib 4.5.0, and
the sources needed for the combined GCC/newlib tree:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_gcc")

stage2_gcc(
    name = "riscv-none-elf-gcc",
    gcc_args = [
        "--with-arch=rv32imac",
        "--with-abi=ilp32",
    ],
    target = "riscv-none-elf",
)
```

This creates the binutils tree, the merged toolchain tree, and a `:dist`
tarball. Put separate `stage2_gcc` calls in separate Bazel packages
because each macro creates a target named `dist`.

### A Windows-hosted GCC

`stage2_gcc_w64` performs a Canadian cross. It runs on Linux, uses the
supplied Linux-to-Windows compiler for compiler executables, and uses
the supplied Linux-hosted build-to-target tree for target libraries:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_gcc_w64")

stage2_gcc_w64(
    name = "riscv-none-elf-gcc-w64",
    host_toolchain = "//toolchains/mingw:x86_64-w64-mingw32-gcc",
    target = "riscv-none-elf",
    target_toolchain = "//toolchains/riscv:riscv-none-elf-gcc",
)
```

The result contains PE executables but no Windows executable runs during
the build.

### Minimal and custom userlands

`stage2_autotools_build`, `stage2_run`, `stage2_tree_merge`,
and `stage2_dist_tarball` accept `userland`. Compose one from public
component labels and consumer-built trees:

```starlark
load(
    "@stage2.bzl//:defs.bzl",
    "stage2_autotools_build",
    "stage2_run",
    "stage2_tree_merge",
)

stage2_tree_merge(
    name = "minimal-userland",
    trees = [
        "@stage2.bzl//trees:bash",
        "@stage2.bzl//trees:coreutils",
    ],
)

stage2_run(
    name = "minimal-userland-check",
    script = "printf 'ok\\n' > %{OUT}\n",
    userland = ":minimal-userland",
)
```

This Bash-plus-coreutils merge is the minimal userland composed from
the library's public components. Bash supplies `bin/bash`; coreutils
supplies `bin/mkdir`, `bin/ln`, `bin/install`, `bin/cp`, and its other
standard programs. The preamble directly requires only `bin/bash`,
`bin/mkdir`, and `bin/ln`, but individual `mkdir` and `ln` targets are
not part of the public API.

Later trees win if paths conflict. `stage2_autotools_build`
additionally requires `bin/make`, so extend the minimal tree for an
Autotools build:

```starlark
stage2_tree_merge(
    name = "autotools-userland",
    trees = [
        ":minimal-userland",
        "@stage2.bzl//trees:make",
        "@stage2.bzl//trees:sed",
        # Add grep, gawk, or other components when the package needs them.
    ],
)

stage2_autotools_build(
    name = "package",
    configure = "@package_src//:configure",
    srcs = "@package_src//:srcs",
    userland = ":autotools-userland",
)
```

Clang is an optional tool tree rather than part of the default
userland. Merge it after the default tree when scripts should find
`clang`, `clang++`, LLD, and the installed LLVM utilities directly on
`PATH`:

```starlark
stage2_tree_merge(
    name = "clang-userland",
    trees = [
        "@stage2.bzl//trees:default_userland",
        "@stage2.bzl//trees:clang",
    ],
)
```

For one action, putting `@stage2.bzl//trees:clang` in `path_trees`
avoids creating a merged target. Either form only makes the Clang tools
available; it does not supply a target sysroot/runtime or select Clang
for Autotools. A `stage2_autotools_build` that selects Clang must set
`stage_cc = False`, pass `CC=clang` and `CXX=clang++` explicitly, and
provide a suitable target runtime. It will normally also set
`use_default_cc = False`; alternatively, keep or merge
`@stage2.bzl//trees:cc` when its musl/GCC runtime is intentionally
part of the setup.

Packages whose install rules use `$INSTALL` require `bin/install`,
which the minimal coreutils component already supplies.
`stage2_run` needs only the additional commands its script
invokes. `stage2_tree_merge` needs `bin/cp`, as does an Autotools build
with a non-empty `install_base`. Individual configure and build flows
may require more programs. `stage2_dist_tarball` additionally requires
`cp`, `find`, `touch`, `tar`, and `gzip`.

Both `stage2_autotools_build` and `stage2_run` use
`@stage2.bzl//trees:default_userland` by default and accept the same
`userland` override shown above. The default merges Bash, coreutils,
sed, grep, findutils, diffutils, tar, gzip, gawk, and GNU make; it does
not include the compiler or additional build ecosystems.
`:minimal-userland` is suitable only when the selected rule and script
need no commands beyond Bash and coreutils; add the other public
components they invoke.

Packages such as m4, bison, flex, patch, and pkg-config can themselves be
built with `stage2_autotools_build`, merged after
`@stage2.bzl//trees:default_userland`, and passed to another wrapper. Composing
only library components and stage2-built trees preserves the guarantee.
Adding a foreign prebuilt tree does not.

See the [API reference](api.md) for all exports, attributes, tokens, and
public tree labels.

## Troubleshooting

### The action says `/bin/sh` already exists

The action is not in the empty hermetic sandbox. Confirm that the four
mandatory `.bazelrc` lines are in the consumer workspace, not only in a
dependency, and that no command-line option overrides the spawn
strategy. Do not suppress the check.

### `linux-sandbox` cannot create namespaces on Ubuntu

Linux user namespaces must be available. Ubuntu hosts with AppArmor's
unprivileged-user-namespace restriction enabled can deny Bazel's
namespace creation. A temporary host-wide diagnostic is:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

Changing that sysctl affects the whole host. On a shared machine, prefer
an administrator-managed AppArmor profile granting `userns` to Bazel's
`linux-sandbox`.

### An out-of-tree Autotools build fails under `.deps`

All builds use a separate build directory (VPATH). Some non-recursive
makefiles rely on dependency tracking to create directories used by
generated headers. Do not copy this repository's internal
`--disable-dependency-tracking` choices into an arbitrary package.
Remove that option first; if the package cannot build out of tree, use
`stage2_run` to express its package-specific build sequence.

### A source archive loops while globbing

Some archives contain a directory symlink back to their own root.
Exclude that path in the `glob` inside the archive's
`build_file_content`:

```starlark
filegroup(
    name = "srcs",
    srcs = glob(
        ["**"],
        exclude = ["usr", "usr/**"],
    ),
)
```

Replace `usr` with the archive's self-referential path. For source trees
where a bare recursive glob still expands the link, list the required
top-level paths explicitly instead of using `["**"]`. The musl.cc
toolchain's `usr -> .` link is the motivating example.

### Downloads fail although actions have no network

Repository rules fetch pinned sources before build actions run.
`--sandbox_default_allow_network=false` applies to actions, not
repository fetching. Populate a Bazel repository cache or add a
byte-identical mirror URL while retaining the expected SHA-256.

### The host CPU is rejected

Only Linux `x86_64` and `aarch64` execution hosts have platform
compiler and seed selections. Cross-compiled outputs may target other
systems, but the build actions themselves must execute on one of those
two Linux host architectures.
