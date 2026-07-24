# stage2.bzl

stage2.bzl is a Bazel rules library for building software from source in an
empty Linux sandbox. It provides a source-built compiler, shell, userland, and
common build tools.

From stage 2 onward, library-owned actions use no downloaded executable as
build machinery. The complete bootstrap is not seedless: a musl.cc GCC and
Alpine BusyBox are used below that boundary.

## Requirements and setup

- Linux `x86_64` or `aarch64`
- Bazel 9 or newer
- Linux user namespaces
- Network access while Bazel fetches pinned inputs

The module is not yet in a public registry, so pin the repository:

```starlark
# MODULE.bazel
bazel_dep(name = "stage2.bzl", version = "1.0.0")
bazel_dep(name = "platforms", version = "1.1.0")

git_override(
    module_name = "stage2.bzl",
    commit = "<full commit SHA>",
    remote = "https://github.com/thii/stage2.bzl.git",
)
```

Dependency settings do not propagate. Every consumer needs:

```text
# .bazelrc
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

These settings select the empty sandbox, reject weaker spawn strategies, and
disable action network access. Repository rules may fetch before actions run;
pin those inputs. Do not mount host tools or directories into the sandbox.
A valid root starts without `/usr`, `/lib`, or `/bin/sh`; the preamble rejects
an existing `/bin/sh`, then creates an ephemeral link to its declared shell.
Remote execution is not supported.

## Quickstart

Given `hello.c`:

```c
#include <stdio.h>

int main(void) {
    puts("hello");
    return 0;
}
```

build it with the public compiler tree:

```starlark
# BUILD.bazel
load("@stage2.bzl//:defs.bzl", "stage2_run")

stage2_run(
    name = "hello",
    inputs = {"SRC": ":hello.c"},
    path_trees = ["@stage2.bzl//trees:cc"],
    script = "$CC_FOR_BUILD -O2 -static %{SRC} -o %{OUT}\n",
)
```

```sh
bazel build //:hello
./bazel-bin/hello
```

`stage2_run` supplies the default userland but no compiler.
`stage2_autotools_build` supplies both.

## Rules and trees

Load supported symbols from `@stage2.bzl//:defs.bzl`. For an Autotools
package, expose a pinned source tree and its configure script:

```starlark
load("@stage2.bzl//:defs.bzl", "stage2_autotools_build")

stage2_autotools_build(
    name = "package",
    configure = "@package_src//:configure",
    srcs = "@package_src//:srcs",
)
```

The action uses the default compiler and userland and returns an install tree.
Other macros run scripts, merge trees, create distribution archives, and build
GCC/newlib cross toolchains. Reusable filesystem trees are public under
`@stage2.bzl//trees`; everything under `//internal` is private.

The [API reference](docs/api.md) lists every macro, supported parameter, token,
constant, public tree, and command requirement. A complete `http_archive`
consumer lives in [`e2e/consumer`](e2e/consumer/).

## Userlands

The default userland contains Bash, coreutils, sed, grep, findutils, diffutils,
tar, gzip, gawk, and GNU make. The supported minimal composition is Bash plus
coreutils:

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

Pass it as `userland = ":minimal-userland"`. The sandbox preamble requires
`bin/bash`, `bin/mkdir`, and `bin/ln`; each rule or script may require more.
Use `path_trees` for optional tools such as `@stage2.bzl//trees:clang`, or
merge trees when one combined userland is useful.

Public components preserve the library's provenance claim. A custom tree does
so only when its complete executable provenance is audited; a Bazel label alone
is not proof.

## Caching and troubleshooting

A cold output base bootstraps the build environment. Reuse completed actions
and limit outer parallelism on smaller machines with:

```sh
bazel build --jobs=1 --disk_cache=/absolute/path/to/stage2-cache //:target
```

A writable cache is trusted because later builds may execute binaries restored
from it. Bazel's separate repository cache avoids re-downloading source inputs.

- If `/bin/sh` already exists, the empty sandbox is not active. Check all four
  `.bazelrc` lines and command-line overrides; do not suppress the tripwire.
- If `linux-sandbox` cannot create namespaces, enable unprivileged user
  namespaces. On Ubuntu,
  `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` is a
  host-wide diagnostic; prefer an administrator-managed AppArmor policy on
  shared systems.
- Download failures occur before build actions. Use a repository cache or a
  byte-identical mirror with the same SHA-256.

## Examples

The `//examples` packages demonstrate bare-metal GCC/newlib for RISC-V,
AArch64, and Arm; Linux- and Windows-hosted cross toolchains; and
Darwin-hosted Clang/LLD. They are examples, not supported distributions.

```sh
bazel build //examples/riscv-none-elf-gcc:dist
```

The macOS SDK tree begins with a pinned Apple package. Source-built tools
extract it without executing its compiled payloads and remove Mach-O files and
archives. The public tree retains headers, text `.tbd` stubs, and non-executable
SDK metadata. SDK use remains subject to Apple's license.

## Trust boundary

| stage | inputs and result |
|---|---|
| 0 | Downloaded static musl.cc GCC and Alpine BusyBox are the compiler and shell seeds. |
| 1 and tooling | The seeds build static binutils, musl, GCC, GNU make, Bash, and the GNU userland. |
| 2 and later | Stage 1 rebuilds the native toolchain with the source-built userland. Seed executables are absent from these actions' direct inputs; the result is `@stage2.bzl//trees:cc`. |

The full transitive graph still reaches both seeds. The claim is per-action
tool provenance, not a claim that every input byte is source text. Consumer
inputs and custom trees may contain anything; consumers inherit the claim only
when their executable tools have audited source-built provenance. Cross-built
PE and Mach-O programs are outputs, not tools executed during the Linux build.

Inspect a target's action graph with:

```sh
bazel aquery 'deps(//your:target)' --output=text \
  > /tmp/stage2-action-graph.txt
```

Trace executable tools and generated trees to their producers, match external
inputs to accepted pins, audit every consumer-supplied input, and verify the
four `.bazelrc` lines. The kernel, Bazel, repository fetching, and writable
caches remain trusted. SHA-256 establishes byte identity rather than authorship,
and stage2.bzl does not claim general build reproducibility.
