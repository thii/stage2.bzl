# stage2.bzl

Developer tools built from source by Bazel in a hermetic sandbox. The
name marks the trust boundary: from **stage 2** of the bootstrap onward,
no action has any prebuilt binary among its inputs — compiler, libc,
binutils, shell, userland, make and awk are all source-built.

## The tools

Each tool lives in its own package under `//tools`, a from-source
counterpart of the usual prebuilt embedded-toolchain distributions:

| tool | components | notes |
|------|------------|-------|
| `//tools/riscv-none-elf-gcc` | GCC 15.2.0, binutils 2.45, newlib 4.5.0 | default arch `rv32imac/ilp32` |
| `//tools/aarch64-none-elf-gcc` | GCC 15.2.0, binutils 2.45, newlib 4.5.0 | AArch64 bare-metal |
| `//tools/arm-none-eabi-gcc` | GCC 15.2.0, binutils 2.45, newlib 4.5.0 | Arm 32-bit bare-metal |
| `//tools/mingw-w64-gcc` | GCC 15.2.0, binutils 2.45, mingw-w64 v12 (UCRT) | Windows x86_64 cross; `--enable-threads=win32` |
| `//tools/riscv-none-elf-gcc-w64` | same as riscv-none-elf-gcc | **Windows-hosted** (Canadian cross, see below) |
| `//tools/clang` | LLVM/clang + lld 22.1.8 | linux-musl hosted, multi-target; the macOS "leg" |

Each package provides `<name>` (the merged install tree) and `:dist`
(a reproducible `.tar.gz`). The newlib toolchains are three-line
`gcc(...)` macro calls (`toolchain/gcc.bzl`); mingw spells out the
classic headers → C-only gcc → CRT → full gcc sequence on top of the
shared stage-2 config (`toolchain/stage2.bzl`).
Deliberately narrowed relative to full binary distributions, for build
time:
single multilib, C/C++ only (no Fortran), no bundled GDB, and for mingw
no winpthreads (so no `std::thread` in libstdc++).

Every build action runs under **`--experimental_use_hermetic_linux_sandbox`**
(set in `.bazelrc`) with **no `--sandbox_add_mount_pair` at all**: the
sandbox root contains nothing from the host — no `/usr`, no `/lib`, not even
`/bin/sh` — and no network (`--sandbox_default_allow_network=false`).
Everything a `configure && make` build needs is a pinned, checksummed
download declared as an action input. Actions verify this: they refuse to
run if a `/bin/sh` is already visible (i.e. the sandbox is not the empty
hermetic one), rather than silently mixing host and hermetic tools.

## Usage

```sh
bazel build //tools/riscv-none-elf-gcc         # one toolchain install tree
bazel build //tools/riscv-none-elf-gcc:dist    # ...as a .tar.gz
bazel build //tools/... //examples:all         # everything + example firmware
```

On small machines add `--jobs=2`: several toolchains building in
parallel (each action runs `make -j4` internally) can exhaust RAM — a
7 GB host OOM-killed Bazel's own server at the default job count.

The examples cross-compile the same bare-metal sources with each freshly
built toolchain (`hello.elf` RISC-V, `hello-aarch64.elf`,
`hello-arm.elf`, and `hello-w64.exe`, a real PE32+ executable linked
against the UCRT mingw-w64 runtime) — compilers included — inside the
same empty sandbox.

Expect a full build to take a while: `//toolchain:riscv-none-elf-gcc`
transitively builds GCC three times (stage-1 and stage-2 host compilers,
then the cross compiler — see *Trust chain* below); ~25–40 min on a small
machine, ~20 min of which is the staged host toolchain. Progress is not
streamed; on failure the rule prints the tail of the relevant log.

## How an empty sandbox builds GCC

The interesting part is what substitutes for the host system
(`toolchain/build_defs.bzl`):

- **Shell & userland** — the real GNU userland, built from source by the
  stage-1 compiler and merged into one prefix
  (`//toolchain:userland-s2`): bash 5.3, coreutils 9.7, sed, grep,
  findutils, diffutils, tar, gzip and gawk, all static. Stage-2 and
  later actions exec its bash directly (Bazel `genrule`s are never used:
  they require the *host* bash); the prebuilt Alpine `busybox-static`
  package is only the bootstrap shell for stage 0/1 and for building the
  userland packages themselves. GNU tools are used deliberately rather
  than busybox reimplementations: an earlier busybox-based userland
  silently corrupted GCC's generated option tables (GCC's `optc-gen.awk`
  feeds raw language names like `C++` to awk as regexes; busybox awk
  drops the `CL_CXX` bits, yielding a compiler that ignores `-std=` —
  Alpine's busybox only works because Alpine patches it).
- **`/bin/sh`** — source trees hardcode `#!/bin/sh` in helper scripts
  (gcc's `move-if-change`, `install-sh`, …), and the hermetic sandbox has
  no `/bin`. The sandbox root is writable, so each action creates
  `/bin/sh` *inside the ephemeral sandbox*, pointing at its shell (the
  userland bash, or the seed busybox during bootstrap). Nothing is
  mounted from the host; the link dies with the sandbox.
- **Host compiler** — built from source. The fully static
  [musl.cc](https://musl.cc) native GCC 11.2.1 is only a *stage-0 seed*:
  it compiles a stage-1 host toolchain (binutils 2.45 + musl 1.2.5 +
  GCC 15.2.0, `<arch>-unknown-linux-musl`, fully static) from the pinned
  sources; stage-1 then rebuilds the same three components as stage-2
  with the seed absent from the sandbox; and the shipped riscv-none-elf
  toolchain is compiled exclusively by stage-2. **No prebuilt compiler
  binary is in the input set of any action that produces shipped
  artifacts.** Static binaries need no ELF interpreter or shared
  libraries, so they run in an empty root as plain action inputs. Every
  compiler spelling (`CC`, `CXX`, `CC_FOR_BUILD`, `CXX_FOR_BUILD`) pins
  `-static`, so configure run-tests and build-time generators also work —
  and the resulting riscv-none-elf toolchain is itself fully static.
  (`LDFLAGS=--static` rather than `-static`, because libtool swallows the
  latter.)
- **GNU make** — bootstrapped from source (`//toolchain:make`) using
  make's own `build.sh`, which exists precisely to build make when you
  don't have make.
- **autoconf quirks** — `MKDIR_P`/`INSTALL` are pinned to busybox applets
  in the *environment* (autoconf 2.69's "race-free mkdir -p" probe only
  whitelists GNU coreutils and would otherwise fall back to the
  shebang-executed `install-sh`; the GCC/binutils top-level configure
  does not forward `VAR=VALUE` args to sub-configures, but environment
  variables pass through). `MAKEINFO=true` is forced on the make command
  line so stale-timestamp `.texi` files in release tarballs don't trigger
  a texinfo dependency.

### Build stages

0. `//toolchain:make` — GNU make 4.4.1, bootstrapped with busybox `sh` +
   the seed gcc.
1. **Stage 1** (`host-binutils-s1`, `musl-s1`, `host-gcc-s1`) — a native
   `<arch>-unknown-linux-musl` host toolchain compiled by the prebuilt
   seed. This is the only place the seed compiler is ever used.
1b. **Tooling** (`make-s2` and the userland packages `bash-s2`,
   `coreutils-s2`, `sed-s2`, `grep-s2`, `findutils-s2`, `diffutils-s2`,
   `tar-s2`, `gzip-s2`, `gawk-s2`, merged into `userland-s2`) — rebuilt
   from source by stage 1, still under the seed shell.
2. **Stage 2** (`host-binutils-s2`, `musl-s2`, `host-gcc-s2`) — the same
   toolchain rebuilt by stage 1, running on the from-source GNU
   userland. From here on, `bazel aquery` shows **zero prebuilt files**
   in any action's input set — compiler, shell, userland, make and awk
   are all source-built.
3. `//tools/*` — the shipped toolchains, compiled by stage 2. The GCC
   targets build from a classic *combined tree*: newlib/libgloss, the
   newlib top-level headers, and gmp/mpfr/mpc/isl (the exact versions
   from `contrib/download_prerequisites`) are assembled into the GCC
   source tree at fetch time by a repository rule (`@gcc_combined_src`),
   so one configure/make builds the compiler and the target C library in
   the right order. Each action seeds its install prefix with its
   binutils tree, producing one merged toolchain prefix; `:dist` targets
   produce GNU-tar'd, timestamp-normalized, name-sorted tarballs.
4. `//examples:all` — end-to-end proof: each freshly built toolchain
   cross-compiles the example sources in the same hermetic sandbox.

The staged builds put the previous stage's `bin/` and plain-named
`<triplet>/bin/` tools on `PATH`: the GCC/binutils top-level configure
resolves plain `ar`/`ranlib` (build == host at top level) and exports
them to sub-configures that are cross-compiling, so plain names must
resolve to real binutils — neither busybox nor the GNU userland provides
an `ar`.

### Windows-hosted toolchains: the Canadian cross

`//tools/riscv-none-elf-gcc-w64` is the same RISC-V toolchain with
`--host=x86_64-w64-mingw32`: a **Canadian cross** (build ≠ host ≠ target).
No build action ever runs on Windows — everything still executes in the
empty Linux sandbox — and the three toolchains the build needs are all
stage-2 artifacts from this repository:

- `CC`/`CXX` = `//tools/mingw-w64-gcc` (build→host) compiles GCC's own
  sources into static PE executables;
- `CC_FOR_BUILD` = stage 2 compiles the build-time generators;
- `//tools/riscv-none-elf-gcc` (build→target, same GCC version, on
  `PATH`) builds libgcc/newlib/libstdc++, because the freshly built
  `xgcc` is a Windows binary and cannot run here.

The trust chain is unchanged: zero prebuilt binaries in any producing
action. `-Wl,--no-insert-timestamp` zeroes the PE header timestamps so
`:dist` stays byte-reproducible. Windows binaries cannot execute in the
sandbox, so the PE checks verify the `MZ` and `PE\0\0` signatures and the
COFF machine field `0x8664` for x86_64 (AMD64).
`//tools/riscv-none-elf-gcc-w64:dist` produces
`riscv-none-elf-gcc-w64-15.2.0.tar.gz`. Real smoke tests belong on a Windows
machine or Wine, outside the trust boundary. Windows ARM64 is deferred
because xPack does not currently publish that host distribution.

### macOS: cross from Linux against the pinned Apple SDK

macOS has no equivalent of the hermetic sandbox (Seatbelt cannot present
an empty root, and every darwin process must load Apple's dyld and
libSystem), so macOS support goes the other direction: **build for
darwin from inside the Linux sandbox**. Two pieces:

- **The SDK** (`//toolchain:macos-sdk`): Apple's Command Line Tools SDK
  package, pinned by SHA-256 from Apple's own softwareupdate CDN and
  extracted from source-built tools only — bsdtar/libarchive reads the
  outer xar and the inner cpio, and `toolchain/pbzx.c` (~90 lines,
  compiled in-action) decodes the pbzx layer between them.
  `toolchain/sdkprune.c` then deletes, by file magic, the couple dozen
  legacy Mach-O leftovers each SDK release carries (pre-10.8 CRT
  objects, Tcl/Tk stub archives). What remains is **text**: headers and
  `.tbd` linker stubs. Apple contributes no executable code to any
  action; libSystem links at runtime on the user's Mac, exactly like
  kernel32/UCRT in the mingw story.
- **The compiler** (`//tools/clang`): clang + lld 22.1.8, built from the
  pinned LLVM source by stage 2 (with `cmake-s2` bootstrapped from
  source and `python-s2` as LLVM's build interpreter). clang is
  inherently multi-target and `ld64.lld` is a production Mach-O linker
  that ad-hoc code-signs arm64 output — required on Apple Silicon.

`//examples:hello-darwin` links a real arm64 Mach-O executable against
the SDK inside the same empty sandbox; copy it to any Apple-Silicon Mac
and it runs. Licensing note: the SDK downloads unauthenticated from
Apple's CDN, but Apple's license ties SDK *use* to Apple-branded
hardware — running this build in a Linux VM on a Mac satisfies that
reading; other setups are your call. The pinned catalog URL can rot when
Apple rotates product generations (like the Alpine apks); refresh it
from `swscan.apple.com/content/catalogs/others/*.sucatalog`.

`//tools/clang:clang-darwin-arm64` and
`//tools/clang:clang-darwin-x86_64` complete the Canadian crosses for
darwin-hosted toolchains on both Apple Silicon and Intel Macs. CMake and
Python drive each cross-build; Linux-native `llvm-tblgen` and
`clang-tblgen` from `//tools/clang:clang` generate build-time tables while
its Linux clang and lld cross-build the matching arm64 or x86_64 Mach-O
tools against the pruned SDK. A magic check verifies the installed
executables are Mach-O. `//tools/clang:clang-darwin-arm64-dist` produces
`clang-darwin-arm64.tar.gz`; the new
`//tools/clang:clang-darwin-x86_64-dist` produces
`clang-darwin-x86_64.tar.gz`.

### Native-host distributions

Five host distributions are built from the Linux sandbox:

| delivered host | CPU | build label | archive | GitHub Actions runner |
|----------------|-----|-------------|---------|-----------------------|
| Linux | x86_64 | `//tools/riscv-none-elf-gcc:dist` | `riscv-none-elf-gcc-15.2.0.tar.gz` | GitHub-hosted Ubuntu x64 |
| Linux | arm64 | `//tools/riscv-none-elf-gcc:dist` | `riscv-none-elf-gcc-15.2.0.tar.gz` | GitHub-hosted Ubuntu arm64 |
| Windows | x86_64 | `//tools/riscv-none-elf-gcc-w64:dist` | `riscv-none-elf-gcc-w64-15.2.0.tar.gz` | GitHub-hosted Ubuntu x64 |
| Darwin | x86_64 | `//tools/clang:clang-darwin-x86_64-dist` | `clang-darwin-x86_64.tar.gz` | GitHub-hosted Ubuntu x64 |
| Darwin | arm64 | `//tools/clang:clang-darwin-arm64-dist` | `clang-darwin-arm64.tar.gz` | GitHub-hosted Ubuntu arm64 |

All five release-matrix jobs use `--jobs=1`: individual build actions already run
parallel makes, and serial Bazel scheduling keeps hosted-runner memory use
bounded. Every job runs on GitHub-hosted Ubuntu runners — the Darwin ones
included, since Darwin toolchains are Canadian crosses that never execute a
build action on macOS. A cold Darwin chain (stage 2, a native LLVM, then a
Canadian LLVM) exceeds one 6-hour hosted job, so those jobs carry a Bazel
disk cache in the Actions cache and resume where the previous run stopped:
re-run the workflow until it goes green. Note that building on GitHub's
infrastructure rather than Apple hardware is one of the "your call" setups
under the SDK-license note above.

### Trust chain

Shipped artifacts are produced by actions whose input sets contain no
prebuilt binaries at all (verifiable with `bazel aquery`): compiler,
libc, binutils, shell, userland, make and awk are all built from pinned,
auditable source. Two binary seeds remain, strictly bootstrap-only —
they appear exclusively in stage-0/1 and tooling actions:

- the musl.cc toolchain (compiles stage 1 and the stage-0 make);
- the Alpine busybox (the bootstrap shell: building a shell from source
  needs a shell, so some shell seed is irreducible).

A literal zero-compiler-seed bootstrap (the stage0/live-bootstrap chain:
a ~357-byte `hex0` seed → M2-Planet → GNU Mes → TinyCC → old GCC → …)
exists today only for x86: every GCC that can target aarch64 (≥ 4.8) is
written in C++, and every C-written GCC (≤ 4.7) cannot target aarch64,
so TinyCC has no bridge to a modern compiler on this architecture. Two
staged rebuilds are the strongest form available natively on
aarch64/x86_64 alike — and note that no finite number of stages defeats
a Thompson-style trusting-trust attack; only the hex0 route or diverse
double-compilation does.

In-tree gmp is configured by GCC's top level in generic-C mode, which
also removes gmp's usual build-time `m4` requirement (busybox has no m4).

## Fidelity

Reproduced: the component versions, target triplets, and the RISC-V
default architecture (`rv32imac/ilp32`), with relocatable,
self-contained install trees of static host binaries (typical binary
distributions ship dynamic binaries with bundled shared libraries;
static is what makes an empty-root build possible).

Deliberately narrowed, for build time — each is a switch in the
`//tools` packages:

- single multilib (e.g. `--disable-multilib --with-arch=rv32imac
  --with-abi=ilp32` for RISC-V) instead of the full multilib lists;
- `--enable-languages=c,c++` (no Fortran);
- no GDB (a separate source package that would roughly double the
  build).

## Using the rules from your own module

The rules layer is general: `stage2_autotools_build` runs any
configure/make tree — and `stage2_hermetic_run` any script — on the
zero-prebuilt stage-2 platform. The from-source userland shell, the
static musl GCC, and GNU make arrive as ordinary Bazel inputs from this
module, so artifacts you build inherit the same "no prebuilt binary
among action inputs" property. In your `MODULE.bazel`:

```starlark
bazel_dep(name = "stage2.bzl", version = "0.1.0")
bazel_dep(name = "platforms", version = "1.1.0")
```

Copy the sandbox flags into your `.bazelrc` — the hermetic sandbox is a
per-workspace setting that does not propagate from dependencies. Every
action's preamble refuses to run outside the empty sandbox (the
`/bin/sh` tripwire), so forgetting this fails loudly instead of quietly
building against your host:

```
common --enable_platform_specific_config
build --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

Then a package builds like this (GNU hello, static, from source):

```starlark
load(
    "@stage2.bzl//toolchain:stage2.bzl",
    "STAGE_CC",
    "stage2_autotools_build",
    "stage2_hermetic_run",
)

stage2_autotools_build(
    name = "hello",
    configure = "@hello_src//:configure",
    configure_args = [
        "--disable-nls",
        "CFLAGS=-O2 -std=gnu17",
        "LDFLAGS=--static",
    ] + STAGE_CC,
    path_trees = ["@stage2.bzl//toolchain:host-gcc-s2"],
    srcs = "@hello_src//:srcs",
)

# The built artifact runs inside the same empty sandbox: static
# binaries need nothing from a host.
stage2_hermetic_run(
    name = "hello-output",
    files = {":hello": "TREE"},
    script = "%{TREE}/bin/hello > %{OUT}\n",
)
```

`STAGE_CC` pins the stage-2 compiler (static) as configure's `CC`/`CXX`
and `path_trees` puts its `bin/` on `PATH`. The first build bootstraps
the platform once (~40 min on a small machine); afterwards it is an
ordinary cached Bazel dependency. (Unlike this repo's own packages,
hello keeps dependency tracking enabled: its non-recursive Makefile
relies on the `.deps` machinery to create build-directory
subdirectories in out-of-tree builds, and generated-header rules fail
without them.)

## Host requirements

- Linux with user namespaces available (the hermetic sandbox is
  Linux-only). On Ubuntu 24.04+ with AppArmor userns restriction
  (`kernel.apparmor_restrict_unprivileged_userns=1`), Bazel's
  `linux-sandbox` cannot create its namespaces; either disable that
  sysctl or install an AppArmor profile granting `userns` to
  `linux-sandbox`.
- `x86_64` or `aarch64` host (both are wired up in `MODULE.bazel`; the
  unused architecture's downloads are never fetched). Only `aarch64` has
  been exercised end-to-end so far; the `x86_64` path is wired identically
  but untested.
- Network access on first build to fetch the pinned archives (GNU ftp,
  sourceware, musl.cc, Alpine CDN).

## Pinned inputs

Sources: gcc 15.2.0, binutils 2.45, newlib 4.5.0.20241231, make 4.4.1,
musl 1.2.5, gmp 6.2.1, mpfr 4.1.0, mpc 1.2.1, isl 0.24 — all by SHA-256
in `MODULE.bazel` / `toolchain/gcc_combined_repo.bzl`.

Userland and tool sources: bash 5.3, coreutils 9.7, sed 4.9, grep 3.11,
findutils 4.10.0, diffutils 3.12, tar 1.35, gzip 1.14, gawk 5.3.2 — by
SHA-256 in `MODULE.bazel`.

macOS-support sources: zlib 1.3.2, xz 5.8.3, libarchive 3.8.7, cmake
3.31.7, Python 3.12.8, LLVM 22.1.8, and the Apple Command Line Tools
SDK package (MacOSX26.5.sdk; headers + `.tbd` text stubs after pruning)
— by SHA-256 in `MODULE.bazel`.

Bootstrap seeds (stage 0/1 only): musl.cc native toolchains (pinned
`more.musl.cc` 11.2.1 archives) and Alpine `busybox-static` 1.37.0-r20
apks, also by SHA-256. (Alpine's CDN only serves the current revision of an active
branch, so the apk URLs can rot when the package is bumped — see the note
in `MODULE.bazel`.)
