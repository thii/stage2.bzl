# stage2.bzl

stage2.bzl is primarily for bootstrapping compilers and build tools from source
in an empty Linux sandbox. It provides a source-built compiler, shell,
userland, and common build tools; it can also drive conventional package
builds.

From stage 2 onward, library-owned actions use no prebuilt executable as build
machinery. Below that boundary, configurable compiler and shell seeds bootstrap
the source-built tools. The defaults are musl.cc GCC and Alpine BusyBox.

## Requirements and setup

- Linux `x86_64` or `aarch64`
- Bazel 9 or newer
- Linux user namespaces

In your MODULE.bazel:

```starlark
bazel_dep(name = "stage2.bzl", version = "0.0.1")
```

In your .bazelrc:

```text
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

These settings select the empty sandbox, reject weaker spawn strategies, and
disable action network access. Do not mount anything into the sandbox. A
valid root starts without `/usr`, `/lib`, or `/bin/sh`; the preamble rejects
an existing `/bin/sh`, then creates an ephemeral link to its declared shell.
Remote execution is not supported.

## Quickstart

The intended workload is a compiler or build tool; GNU Hello is a compact
example of the same `configure`, `make`, and `make install` flow. Add its
pinned source archive to `MODULE.bazel`:

```starlark
http_archive = use_repo_rule(
    "@bazel_tools//tools/build_defs/repo:http.bzl",
    "http_archive",
)

http_archive(
    name = "hello_src",
    build_file_content = """filegroup(
    name = "srcs",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
exports_files(["configure"])
""",
    sha256 = "8d99142afd92576f30b0cd7cb42a8dc6809998bc5d607d88761f512e26c7db20",
    strip_prefix = "hello-2.12.1",
    urls = ["https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"],
)
```

Then build the install tree:

```starlark
# BUILD.bazel
load("@stage2.bzl", "stage2_autotools_build")

stage2_autotools_build(
    name = "hello",
    srcs = "@hello_src//:srcs",
    configure = "@hello_src//:configure",
    configure_args = [
        "--disable-nls",
        "CFLAGS=-O2 -std=gnu17",
        "LDFLAGS=--static",
    ],
)
```

```sh
bazel build //:hello
./bazel-bin/hello/bin/hello
```

`stage2_autotools_build` supplies the default compiler and userland, runs all
three build phases, and returns the installed directory tree.

## Custom builds

Use `stage2_run` when a build does not fit the Autotools lifecycle. Given an
`input.txt`, this example builds a SHA-256 manifest:

```starlark
load("@stage2.bzl", "stage2_run")

stage2_run(
    name = "manifest",
    inputs = {"INPUT": ":input.txt"},
    out = "manifest.sha256",
    script = "sha256sum %{INPUT} > %{OUT}\n",
)
```

```sh
bazel build //:manifest
cat bazel-bin/manifest.sha256
```

The script may run any build commands supplied by the userland or
`path_trees`. Declare tokenized inputs with `inputs`, other inputs with
`extra_inputs`, and create `%{OUT}`. Add
`@stage2.bzl//trees:cc` to `path_trees` when the script needs the default
compiler; use `out_tree = True` for a directory output.

## Rules and trees

Load supported symbols from `@stage2.bzl`. Other macros merge trees, create
distribution archives, and build GCC/newlib cross toolchains. Reusable
filesystem trees are public under `@stage2.bzl//trees`.

## Compiler seeds

The default compiler seed is musl.cc GCC 11.2.1. The root module may select a
different complete, static C/C++ compiler seed for either supported
architecture. Fetch the bundle with `http_archive`, then describe its files and
commands in a BUILD file:

```starlark
load("@stage2.bzl", "stage2_compiler_seed")

stage2_compiler_seed(
    name = "my_seed",
    inputs = ["@my_muslcc//:all"],
    roots = {
        "SEED": ("@my_muslcc//:bin/gcc", "bin/gcc"),
    },
    path = ["%{SEED}/bin"],
    env = {
        "CC": "%{SEED}/bin/gcc -static",
        "CXX": "%{SEED}/bin/g++ -static",
    },
    symlinks = {"%{SEED}/usr": "."},
)
```

Then select it in `MODULE.bazel`:

```starlark
compiler_seeds = use_extension(
    "@stage2.bzl//:extensions.bzl",
    "compiler_seeds",
)
compiler_seeds.seed(
    arch = "x86_64",
    target = "//:my_seed",
)
```

An unspecified architecture keeps the default seed. The selected bundle must
be self-contained: its commands cannot rely on host executables or libraries,
and they must compile and link static C and C++ programs. A seed may combine
several input trees and named roots.

For example, the
[Hermetic LLVM minimal release](https://github.com/hermeticbuild/hermetic-llvm/releases/tag/llvm-23.1.0-rc1-1)
provides static Clang and LLD executables, but no libc, CRT objects, compiler
runtime, or C++ runtime. “Static” describes the LLVM executables themselves,
not a complete target environment. The archive cannot serve as a seed by
itself; combine it with a complete static sysroot/runtime and describe both
roots. Exact Clang target, sysroot, linker, and runtime flags depend on that
companion bundle.

## Shell seeds

The default bootstrap shell is Alpine BusyBox. A root module may select another
self-contained static shell:

```starlark
load("@stage2.bzl", "stage2_shell_seed")

stage2_shell_seed(
    name = "my_shell",
    executable = "@my_shell_archive//:shell",
    args = ["sh"],
)
```

Select it for either architecture in `MODULE.bazel`:

```starlark
shell_seeds = use_extension(
    "@stage2.bzl//:extensions.bzl",
    "shell_seeds",
)
shell_seeds.seed(
    arch = "x86_64",
    target = "//:my_shell",
)
```

`args` precede `-c` for the top-level action; use `["sh"]` for a multicall
binary such as BusyBox and `[]` for Bash. The executable must also act as a
shell when invoked through a symlink named `sh`, without those arguments,
because nested build scripts use `/bin/sh`. BusyBox remains on `PATH` as the
utility fallback; the selected shell may also provide builtins or multicall
applets.

## Userlands

The default userland contains Bash, coreutils, sed, grep, findutils, diffutils,
tar, gzip, gawk, and GNU make. The supported minimal composition is Bash plus
coreutils:

```starlark
load("@stage2.bzl", "stage2_tree_merge")

stage2_tree_merge(
    name = "minimal-userland",
    trees = [
        "@stage2.bzl//trees:bash",
        "@stage2.bzl//trees:coreutils",
    ],
)
```

Pass it as `userland = ":minimal-userland"`. The sandbox preamble requires
`bin/bash`, `bin/mkdir`, and `bin/ln`; each rule or script may require more.
Use `path_trees` for optional tools such as `@stage2.bzl//trees:clang`, or
merge trees when one combined userland is useful.

Public components preserve the library's provenance claim. A custom tree does
so only when its complete executable provenance is audited; a Bazel label alone
is not proof.

## Trust boundary

- Stage 0: the compiler and shell seeds, with BusyBox fallback utilities, build
  GNU Make.
- Stage 1: those seeds and Make build the first compiler and source userland.
- Stage 2: the stage-1 compiler and userland rebuild both; a closing compiler
  pass links against the rebuilt runtime.

CI varies the compiler seed between musl.cc and Zig and the shell seed between
BusyBox and Bash; the closing compiler, userland, and GNU Hello outputs are
byte-identical on `x86_64` and `aarch64`.

## Caveats

This project is mostly for bootstrapping compilers and build tools. Prefer
Bazel-native rules for ordinary application builds that need fine-grained
incrementality and language integration. stage2.bzl wraps each upstream build
in a coarse shell action, favoring auditable tool provenance, hermetic
correctness, and compatibility with conventional source builds:

- Changing any input reruns the whole action. Bazel cannot cache or schedule
  individual compilations; `make` or the script controls internal parallelism.
- Compilers and tools are filesystem trees rather than Bazel-resolved
  platforms and toolchains. Language providers, dependency analysis, per-file
  diagnostics, test sharding, and similar integrations are unavailable inside
  the action.
- Remote execution is unsupported.

## Compared with Docker

- No Docker or other container daemon is required. Bazel creates each action
  sandbox directly from declared files and trees, which remain visible in the
  action graph.
- From stage 2 onward, library-owned actions use only executable build tools
  compiled from source.
