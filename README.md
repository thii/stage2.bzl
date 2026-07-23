# stage2.bzl

stage2.bzl is a Bazel rules library for building software from source in
an empty Linux sandbox. It provides a source-built compiler, shell,
userland, and common build tools.

From stage 2 onward, library-owned actions use no downloaded executable
as build machinery. The full bootstrap is not seedless: a musl.cc GCC
and Alpine BusyBox are used below that boundary. See
[Trust and verification](docs/trust.md) for the precise claim.

## Requirements

- Linux `x86_64` or `aarch64`
- Bazel 9 or newer
- Linux user namespaces
- Network access while Bazel fetches pinned inputs

With the required sandbox settings, build actions have no network and
cannot see host `/usr`, `/lib`, or `/bin/sh`. Remote execution is not
supported.

## Quickstart

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

Dependency settings do not propagate. Add the required sandbox contract
to the consuming workspace:

```text
# .bazelrc
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

Given a local `hello.c`:

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

`stage2_run` supplies the default GNU userland but adds no compiler
automatically. `stage2_autotools_build` adds the compiler as well. See
the [consumer guide](docs/consumers.md) for an Autotools example,
custom userlands, caching, and troubleshooting.

## Public API

Load supported symbols from `@stage2.bzl//:defs.bzl`. Its build macros
are:

| export | purpose |
|---|---|
| `stage2_autotools_build` | Run `configure`, `make`, and `make install`. |
| `stage2_run` | Run an arbitrary Bash build script. |
| `stage2_tree_merge` | Merge directory trees; later trees win. |
| `stage2_dist_tarball` | Create a timestamp-normalized, name-sorted `.tar.gz`. |
| `stage2_gcc` | Build a Linux-hosted GCC/newlib cross toolchain. |
| `stage2_gcc_w64` | Build a Windows-hosted GCC Canadian cross. |

Reusable filesystem trees are public under `@stage2.bzl//trees`:

- `:cc` and `:default_userland`
- `:bash`, `:coreutils`, `:sed`, `:grep`, `:findutils`, `:diffutils`,
  `:tar`, `:gzip`, `:gawk`, and `:make`
- `:bsdtar`, `:cmake`, `:python`, `:clang`, and `:macos-sdk`

The supported minimal userland is Bash plus coreutils. Public components
and audited trees can be combined with `stage2_tree_merge`; adding a
foreign prebuilt executable changes the provenance claim.

The [API reference](docs/api.md) also documents the exported build
constants. Everything under `//internal` is private.

## Examples

The `//examples` packages demonstrate the public API; they are not
supported toolchain distributions.

| package | result |
|---|---|
| `//examples/riscv-none-elf-gcc` | RISC-V bare-metal GCC/newlib |
| `//examples/aarch64-none-elf-gcc` | AArch64 bare-metal GCC/newlib |
| `//examples/arm-none-eabi-gcc` | Arm bare-metal GCC/newlib |
| `//examples/mingw-w64-gcc` | Linux-to-Windows GCC |
| `//examples/riscv-none-elf-gcc-w64` | Windows-hosted RISC-V GCC |
| `//examples/clang:clang-darwin-arm64` and `//examples/clang:clang-darwin-x86_64` | Darwin-hosted Clang/LLD |

```sh
bazel build //examples/riscv-none-elf-gcc:dist
bazel build //examples/...
```

The macOS SDK tree begins with a pinned Apple package. Source-built tools
extract it and remove compiled Mach-O/archive payloads; the public tree
retains headers, text `.tbd` stubs, and non-executable SDK metadata. SDK
use remains subject to Apple's license.

## Documentation

- [Consumer guide](docs/consumers.md)
- [API reference](docs/api.md)
- [Trust and verification](docs/trust.md)
