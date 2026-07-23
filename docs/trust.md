# Trust and verification

## Claim and boundary

From stage 2 onward, library-owned actions use no downloaded executable
as build machinery. Compilers, binutils, the shell, GNU userland, and
other tools—as well as libc—are built from pinned source before or
within the action.

This is a per-action tool-provenance claim. It does not mean the full
bootstrap is seedless or that every input byte is source text. Consumer
sources and custom trees may contain anything; consumers inherit the
claim only when their executable tools are public source-built tool
trees or other audited source-built outputs.

## Sandbox enforcement

With the required consumer settings, rule-created actions run in Bazel's
hermetic Linux sandbox with no host mounts. The root starts without
`/usr`, `/lib`, or `/bin/sh`. Each action puts declared trees on `PATH`,
refuses to run if `/bin/sh` already exists, then creates an ephemeral
link to its declared shell.

The tripwire detects a missing empty-root sandbox, but it cannot detect
network policy. Consumers must keep the complete
[`.bazelrc` contract](consumers.md#sandbox-contract). Repository rules
may fetch SHA-pinned inputs before actions run; build actions have no
network.

Remote execution is unsupported because a normal worker image does not
provide this empty-root contract.

## Bootstrap

| stage | inputs and result |
|---|---|
| 0 | Downloaded static musl.cc GCC and Alpine BusyBox are the compiler and shell seeds. |
| 1 and tooling | The seeds build static binutils, musl, GCC, GNU make, Bash, and the GNU userland. These actions remain below the boundary. |
| 2 and later | Stage 1 rebuilds the native toolchain using the source-built userland. The seed executables are absent from these actions' direct inputs; the result is `@stage2.bzl//trees:cc`. |

The complete transitive graph still reaches the two seeds. Stage 2 is
the documented point after which producing actions no longer receive a
seed executable directly.

## Data inputs and cross-built outputs

Cross-built PE and Mach-O programs are outputs, not tools executed during
the Linux build.

`@stage2.bzl//trees:macos-sdk` begins with a SHA-pinned Apple package as
a data input. That package may contain compiled payloads. Source-built
tools extract it without executing them and remove Mach-O files and
archives. The result retains headers, text `.tbd` stubs, and
non-executable SDK metadata. This is why the claim concerns executable
build machinery rather than every byte inside every declared input.

## Audit

Inspect the complete action graph:

```sh
bazel aquery 'deps(//your:target)' --output=text \
  > /tmp/stage2-action-graph.txt
```

For each producing action:

1. Identify its executable shell and tools; trace generated tree
   artifacts to their producing actions.
2. Match external inputs to SHA-pinned repositories or explicitly
   accepted consumer data.
3. At the stage-2 boundary, confirm the documented compiler and userland
   outputs are used instead of the downloaded seeds.
4. Audit every consumer-supplied input attribute, including `srcs`,
   `configure`, `userland`, `path_trees`, `inputs`, and merged trees; a
   Bazel label alone does not establish provenance.
5. Check that all four `.bazelrc` contract lines are effective.

The action graph describes declared provenance. The kernel, Bazel,
repository fetching, and any writable action cache remain trusted. A
cache hit may execute bytes produced elsewhere, so share writable caches
only across trusted builders.

## Not claimed

- SHA-256 proves byte identity, not authorship, review quality, or
  absence of a trusting-trust attack.
- This is not a general reproducible-build guarantee. Builds may observe
  time, scheduling, randomness, or other nondeterminism.

For library-owned actions and conforming consumer actions, executable
build machinery above the stage-2 boundary is declared to Bazel, built
from pinned source, and isolated from undeclared host tools.
