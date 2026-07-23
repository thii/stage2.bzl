# Trust and verification

## The guarantee

From stage 2 of the bootstrap onward, stage2.bzl build actions have no
prebuilt binary among their declared inputs. GCC, Clang, libc, binutils,
the shell, GNU userland, make, awk, CMake, Python, and other tools used
by a stage2 action are outputs of earlier from-source actions.

This is a per-action property. It is stronger than putting a compiler in
a container image, because the build toolchain remains visible in
Bazel's action graph, and narrower than a seedless bootstrap, because
stages 0 and 1 still use two documented binary seeds.

Consumers inherit the property when they use the public API with source
inputs and with the default public trees or other stage2-built trees.
A consumer can deliberately break the property by placing a foreign
binary in `srcs`, `inputs`, or `extra_inputs`, adding a prebuilt
`path_trees` entry, or supplying a prebuilt custom `userland`. Bazel
cannot infer provenance from a directory tree, so those
consumer-controlled inputs remain part of the consumer's audit.

## Why the sandbox matters

Every action runs with Bazel's hermetic Linux sandbox and no host mount
pairs. The sandbox root starts empty: there is no `/usr`, `/lib`, or
`/bin/sh`. Declared static binaries execute without a host ELF
interpreter or shared library.

The action preamble:

1. puts its declared userland and tool trees on `PATH`;
2. creates a scratch directory and temporary home;
3. refuses to continue if `/bin/sh` already exists;
4. creates an ephemeral `/bin/sh` pointing to its declared shell;
5. exports pinned build-compiler and Autoconf helper settings.

The `/bin/sh` check is a tripwire for the empty-root property. It turns a
missing sandbox setting into a hard failure instead of silently using
host tools. It does not prove that action networking is disabled, so the
following complete consumer contract is mandatory:

```text
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

Repository rules download pinned sources before actions execute. Fetching
therefore has network access; build actions do not. SHA-256 verification
means a fallback mirror must serve the same bytes.

Remote execution is not supported in v1. The tripwire intentionally
rejects a normal worker image whose root contains `/bin/sh`, and no
remote worker-image contract currently reproduces the empty local
sandbox.

## Bootstrap stages

### Stage 0: irreducible binary seeds

Two architecture-specific, checksummed binary inputs begin the bootstrap:

- a fully static musl.cc GCC 11.2.1 toolchain;
- Alpine's static BusyBox, used as the bootstrap shell and userland.

The seed compiler builds GNU make and the stage-1 compiler. BusyBox
provides the shell needed to build a source shell. Neither seed is a
direct input to a stage-2-or-later action.

### Stage 1: source-built native toolchain

The seed compiler builds binutils 2.45, musl 1.2.5, and GCC 15.2.0 as a
fully static native `<arch>-unknown-linux-musl` toolchain. That toolchain
then builds the GNU userland, including Bash, coreutils, sed, grep,
findutils, diffutils, tar, gzip, gawk, and make.

The actions producing these stage-1 and tooling outputs still lie below
the guarantee boundary: their direct or transitive bootstrap includes a
binary seed.

### Stage 2: rebuild without a prebuilt input

Stage 1 rebuilds binutils, musl, and GCC. The action inputs at this stage
are source archives, the source-built stage-1 toolchain, and the
source-built userland; the downloaded seed compiler and BusyBox are
absent. Stage 2 is the native compiler tree exposed as
`@stage2.bzl//trees:cc`.

All public build macros run above this boundary. The optional native
Clang tree and the embedded GCC and Darwin-Clang examples are demanding
in-repository consumers of the same public API.

## Special cross-platform inputs

The Windows-hosted toolchains are Canadian crosses. Their PE binaries
are produced by a stage2-built Linux-to-Windows compiler and are never
executed during the Linux build.

The macOS SDK begins as an Apple package, but extraction and pruning use
source-built tools. Legacy Mach-O objects and archives are removed by
file magic; the public SDK tree retains headers and text `.tbd` linker
stubs. Apple runtime code is supplied later by the destination Mac, not
to a producing sandbox action.

## Auditing an action

Start with the target-specific recipe from the library design:

```sh
bazel aquery 'inputs(".*", //your:target)' --output=text \
  > /tmp/stage2-action-inputs.txt
grep -E "^(action |  Inputs:)" /tmp/stage2-action-inputs.txt
```

For each action that produces the requested target, classify every
declared input as one of:

1. a file from a source repository pinned by SHA-256;
2. an output of a stage-2 target or another audited stage2 action;
3. the consumer target's own source.

Paths beneath `external/` identify repositories; correlate them with the
root and consumer `MODULE.bazel` files. Paths beneath `bazel-out/` are
generated artifacts. Follow their producers through the full action
graph:

```sh
bazel aquery 'deps(//your:target)' --output=text \
  > /tmp/stage2-action-graph.txt
```

Tree artifacts appear as one declared input rather than as every file
inside the tree. Audit the action that produced the tree, then continue
recursively until each branch reaches pinned source or an explicitly
accepted consumer source. In particular, do not assume that an arbitrary
custom userland or tool tree is trusted merely because it has one Bazel
label.

Also inspect the effective invocation or workspace `.bazelrc` for all
four sandbox-contract flags. The action graph proves declared
provenance; the flags ensure the host filesystem and action network
cannot add undeclared inputs at execution time.

## What is not claimed

- The Linux kernel and Bazel's sandbox implementation are ambient
  trusted computing base. Kernel behaviour is not built from source by
  this repository.
- The complete bootstrap graph is not seedless. The musl.cc compiler and
  Alpine BusyBox are used below the stage-2 boundary.
- The guarantee does not establish that source code is benign, reviewed,
  or free of a trusting-trust attack. Diverse double compilation and a
  hex-seed bootstrap are separate techniques.
- The guarantee is not a general reproducible-build claim. Some supplied
  distribution rules normalize timestamps and ordering, but arbitrary
  builds may observe time, scheduling, random values, or other
  nondeterminism inside an action.
- Timing and other side channels are out of scope.
- A SHA-256 pin establishes byte identity, not the authorship or quality
  of the pinned source.
- A consumer's own sources and custom tool trees are not automatically
  provenance-checked.

The practical claim is deliberately inspectable: for each action above
stage 2, all executable build machinery is declared to Bazel and was
built from pinned source, while the empty sandbox prevents undeclared
host binaries from entering the action.
