# stage2.bzl

stage2.bzl is a Bazel ruleset for bootstrapping software from source in an
empty Linux sandbox. It provides a source-built compiler, shell, userland, and
common build tools.

From stage 2 onward, library-owned actions use no prebuilt executables as build
machinery. Below that boundary, configurable compiler and shell seeds bootstrap
the source-built tools. The default seeds are musl.cc GCC and Alpine BusyBox.

The CI-verified SHA-256 digests of the closing compiler and userland archives
for this revision are below. Please file a bug if a verified seed combination
produces different digests at the same revision.

**x86_64**

```text
2c7c4b97fce87400ff1123fbb9c40f038d4b0e3810eebf9f4290917908438fdc  cc.tar.gz
e672e708cf7b2f39ea6e7623e690ea3236bfaf1a46597e3fce8f94c3343417a9  userland.tar.gz
```

**aarch64**

```text
97aed4efb440bc37d1e9e98320aba5eca02078222a53eb858c9402fd2275ce41  cc.tar.gz
721184e67a15b32fee4e34eb70960564e5b7ffc258d8222776c2c87ac2d077b6  userland.tar.gz
```

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
disable action network access. Do not mount anything into the sandbox.

## Quickstart

A compact example of the same `configure`, `make`, and `make install` flow.

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

## Compiler seeds

The default compiler seed is musl.cc GCC 11.2.1. The root module may select a
different complete, static C/C++ compiler seed for either supported
architecture:

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

stage2.bzl wraps each upstream build in a coarse shell action. This favors
auditable tool provenance, hermetic correctness, and compatibility with
conventional source builds, but gives up much of Bazel's native integration:

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
