# Consumer guide

Complete the module and sandbox setup in the
[README quickstart](../README.md#quickstart) first. The
[API reference](api.md) defines the full rule contract.

## Sandbox contract

Every consuming workspace must contain:

```text
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

These settings select the empty Linux sandbox, forbid fallback to a
weaker spawn strategy, and remove action network access. Keep them under
`build:linux`; do not mount host `/bin`, `/usr`, compilers, or shells into
the sandbox. Repository rules may still fetch before actions run; pin
those inputs.

## Build an Autotools package

Use Bazel's repository rules for source archives. For example:

```starlark
# MODULE.bazel
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

Then define the build:

```starlark
# BUILD.bazel
load("@stage2.bzl//:defs.bzl", "stage2_autotools_build")

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
```

```sh
bazel build //:hello
```

`stage2_autotools_build` supplies `@stage2.bzl//trees:cc`, static
`CC`/`CXX` assignments, and
`@stage2.bzl//trees:default_userland`. The output is an install tree.

## Scripted builds

`stage2_run` supplies the default userland but not a compiler:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_run")

stage2_run(
    name = "hello-static",
    inputs = {"SRC": ":hello.c"},
    path_trees = ["@stage2.bzl//trees:cc"],
    script = "$CC_FOR_BUILD %{SRC} -O2 -static -o %{OUT}\n",
)
```

Use `inputs` for tokenized paths, `extra_inputs` for other declared
dependencies, and `out_tree = True` for a directory result.

## Custom userlands and tools

The default userland contains Bash, coreutils, sed, grep, findutils,
diffutils, tar, gzip, gawk, and GNU make. The supported minimal
composition is Bash plus coreutils:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_tree_merge")

stage2_tree_merge(
    name = "minimal-userland",
    trees = [
        "@stage2.bzl//trees:bash",
        "@stage2.bzl//trees:coreutils",
    ],
)
```

Pass the result as `userland = ":minimal-userland"`. Add every command
the selected rule and build script need:

| use | required commands |
|---|---|
| sandbox preamble | `bash`, `mkdir`, `ln` |
| `stage2_autotools_build` | `make`, `tail`, package-specific commands, usually `install`, and `cp` with `install_base` |
| `stage2_tree_merge` | `cp` |
| `stage2_dist_tarball` | `cp`, `find`, `touch`, `tar`, `gzip` |
| `stage2_run` | commands used by its script |

Later trees win on path conflicts. For one action, add tools such as
`@stage2.bzl//trees:clang` to `path_trees`, or merge them when a single
combined userland label is useful. The Clang tree contains tools and
resource headers, not a target sysroot or runtime.

Public components preserve the library's provenance claim. A custom tree
does so only when its complete executable provenance is audited; a Bazel
label alone is not proof.

## Caching and resources

A cold output base bootstraps the build environment. Share completed
actions across workspaces with an absolute cache path:

```sh
bazel build --disk_cache=/absolute/path/to/stage2-cache //:target
```

A writable shared cache is trusted because later builds may execute
binaries restored from it. The separate Bazel repository cache avoids
re-downloading source archives.

Autotools builds default to `make -j4`. On memory-constrained hosts,
also limit Bazel's outer scheduling:

```sh
bazel build --jobs=1 //:target
```

## Troubleshooting

### `/bin/sh` already exists

The action is not using the empty sandbox. Check the four required
`.bazelrc` lines and command-line overrides. Do not suppress the
tripwire.

### `linux-sandbox` cannot create namespaces

Enable unprivileged user namespaces. On Ubuntu with AppArmor's
restriction enabled, this host-wide command is useful as a diagnostic:

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

On shared systems, prefer an administrator-managed AppArmor profile for
Bazel's `linux-sandbox`.
