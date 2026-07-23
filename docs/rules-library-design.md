# Design: stage2.bzl as a published rules library

Status: draft for implementation
Audience: implementing agent (Codex) and maintainers
Scope: pivot this repository from "a from-source toolchain distribution
with reusable internals" to "a published Bazel rules library other
modules depend on to build their things hermetically", while keeping
the toolchain products as the flagship consumers of that library.

## 1. Summary

stage2.bzl's differentiator is a guarantee, not a mechanism: **from
stage 2 of the bootstrap onward, no action has any prebuilt binary
among its inputs**, enforced per-action by Bazel's empty hermetic
Linux sandbox. The pivot makes that guarantee consumable as a product:
a dependent module writes `bazel_dep(name = "stage2.bzl", ...)`, loads
a small stable API, and everything it builds through that API inherits
the property.

External consumability has already been proven end to end: a separate
module bootstrapped the platform in its own output base and built and
ran GNU hello inside the empty sandbox, after two enabling fixes
(`Label()` for all cross-package references in macros; documented
`.bazelrc` sandbox flags). The pivot is therefore mostly API
formalization, restructuring, and documentation — not new build
machinery. (Registry publication is deferred; §8.2.)

### Goals

- A deliberate, versioned, documented public API (rules, macros,
  constants, labels) with everything else private.
- Ergonomics: the common case (build one autotools package
  hermetically) should be one repository stanza plus one build stanza.
- The toolchain packages (`//tools/*`) remain in-repo, rebased onto
  the public API as dogfood and as the flagship examples.
- A consumer-facing statement of the guarantee and how to verify it.
- Registry publication is **deferred** (decision pending, §8.2);
  everything here leaves the repo one release-engineering milestone
  away from it, and consumers can depend on the module today via
  `git_override`/`archive_override` or a local registry.

### Non-goals (v1)

- No project rename (decided: the name is the claim).
- No repo split (`//tools` stays; revisit if release cadences diverge).
- No macOS/Windows *host* execution: the sandbox is Linux-only and the
  library says so loudly. Consumers on other OSes build in a Linux VM
  or CI.
- No remote-execution support: the `/bin/sh` tripwire intentionally
  refuses environments that are not the empty local sandbox. Revisit
  only with a worker-image story that preserves the guarantee.
- No non-C/C++ language ecosystems. `stage2_run` is general
  (it already drives CMake and LLVM), but Rust/Go/JVM bootstrap
  stories are out of scope.
- No glibc runtime: the opt-in dynamic runtime (§3.6) is musl-only in
  v1.

## 2. Current state (inventory)

| layer | file | contents |
|---|---|---|
| rules | `toolchain/build_defs.bzl` | `autotools_build`, `hermetic_run`, `tree_merge`, `dist_tarball`, `make_bootstrap`, the sandbox preamble and `/bin/sh` tripwire |
| config | `toolchain/stage2.bzl` | `STAGE_CC`, `OPT_FLAGS`, `BINUTILS_ARGS`, `BUILD_TRIPLE_ARG`, `MINGW_HOST_CC`, `W64_OPT_FLAGS`, `STAGE2_KWARGS`, `stage2_autotools_build`, `stage2_run` |
| platform | `toolchain/BUILD.bazel` | seeds, stages 0–2, userland, extraction stack (zlib/xz/libmd/expat/libarchive), `macos-sdk`, `cmake-s2`, `python-s2` |
| products | `tools/*` | GCC cross toolchains (incl. Windows-hosted Canadian cross), clang (native + darwin-hosted) |
| macros | `toolchain/gcc.bzl` | `gcc`, `gcc_w64` |
| CI | `.github/workflows/build-host-toolchains.yml` | five-platform release matrix, GitHub-hosted runners only |

Already verified: cross-repo label resolution (all macro-supplied
labels are `Label()`), consumer `.bazelrc` requirements, first-build
bootstrap cost (~40 min, then cached), the VPATH/`.deps` interaction
documented in the README's worked example.

## 3. Public API specification

### 3.1 Entry point

One public load point at the repository root:

```starlark
load("@stage2.bzl//:defs.bzl", ...)
```

`defs.bzl` re-exports the public names and nothing else. Loading
anything under `//toolchain/...` from outside the module becomes
unsupported (and, where Bazel allows, invisible — see §6.1).

Exported names (the `stage2_` prefix is the brand):

```starlark
# rules/macros
stage2_autotools_build   # configure && make && make install
stage2_run               # arbitrary script on the platform
stage2_tree_merge        # NEW wrapper: tree_merge, userland preset only (§3.4)
stage2_dist_tarball      # NEW wrapper: dist_tarball, userland preset only (§3.4)
stage2_gcc               # re-export of gcc(): 3-line embedded GCC toolchains
stage2_gcc_w64           # re-export of gcc_w64(): Windows-hosted Canadian cross

# constants (stable values are part of the API contract)
STAGE_CC                 # CC/CXX configure args for the stage-2 compiler
OPT_FLAGS                # CFLAGS/CXXFLAGS/LDFLAGS=--static convention
BINUTILS_ARGS
BUILD_TRIPLE_ARG
MINGW_HOST_CC
W64_OPT_FLAGS
GCC_NEWLIB_ARGS
```

`stage2_gcc`/`stage2_gcc_w64` are exported as thin aliases of the
existing `gcc`/`gcc_w64` macros; the component versions they pin
(GCC 15.2.0, binutils 2.45, newlib 4.5.0, mingw-w64 v12) are
library-owned and documented, and bumping them is a minor-version
event (§8.1).

The raw rules (`autotools_build`, `hermetic_run`, `tree_merge`,
`dist_tarball`, `make_bootstrap`) are **not** exported and stay
internal. The rule/wrapper split is not accidental API duplication:
Starlark rule-attribute defaults cannot be `select()` values, and the
platform preset is `select()`-heavy (per-arch `build_cc`/`build_cxx`/
`tool_subdir`), so a macro must supply it at instantiation — the
standard Bazel pattern. The raw rules additionally serve the
stage-0/1 busybox tier inside this module (seed shell, no userland).
Today zero call sites use `hermetic_run` directly — everything goes
through `stage2_run` — which is exactly why only the wrapper
is public.

### 3.2 Public label surface: `//platform`

A new `platform/BUILD.bazel` package holds `alias` targets — the only
labels consumers may reference. Internals keep their current names and
can be reorganized freely behind the aliases.

| public label | aliases to | purpose |
|---|---|---|
| `//platform:cc` | `//toolchain:host-gcc-s2` | the stage-2 compiler tree (goes in `path_trees`) |
| `//platform:userland` | `//toolchain:userland-s2` | the default merged GNU userland |
| `//platform/userland:bash` … `:make` | `//toolchain:<pkg>-s2` | individual userland component trees, one alias per package (bash, coreutils, sed, grep, findutils, diffutils, tar, gzip, gawk, make), for composing custom userlands (§3.4) |
| `//platform:make` | `//toolchain:make-s2` | GNU make as a standalone tree (also folded into the default userland, §3.3(c)) |
| `//platform:bsdtar` | `//toolchain:libarchive-s2` | archive extraction stack |
| `//platform:cmake` | `//toolchain:cmake-s2` | CMake |
| `//platform:python` | `//toolchain:python-s2` | build-interpreter CPython |
| `//platform:clang` | `//tools/clang:clang` | multi-target clang/lld (the darwin leg) |
| `//platform:mingw-gcc` | `//tools/mingw-w64-gcc` | the build→Windows cross (Canadian-cross leg) |
| `//platform:macos-sdk` | `//toolchain:macos-sdk` | pruned Apple SDK (text only) |

### 3.3 Ergonomics changes

**(a) Default platform compiler on PATH —
`stage2_autotools_build` only.** The `//platform:cc` tree is
*appended* after any caller-supplied `path_trees` (so call sites with
their own toolchains keep PATH precedence) unless
`use_platform_cc = False`. This is deliberately **not** applied to
`stage2_run`: several of its call sites intentionally
exclude the platform compiler (`clang-darwin-*` builds, the PE check,
`hello-darwin`, run-only scripts), and scripts should state their
tools explicitly. Note the default is not behavior-preserving for
autotools call sites that lacked `host-gcc-s2` — the M2 migration
must check each (the mingw `headers`/`crt` steps are the known
cases and are harmless, since their configures use host-prefixed
tools, but this is verified, not assumed).

**(b) `stage_cc` parameter.** `stage2_autotools_build(stage_cc = True)`
(default) appends `STAGE_CC` to `configure_args`. The migration rule
is by intent, not syntax: `stage_cc = False` must be passed by every
call site whose configure must **not** receive the stage-2 `CC`/`CXX`
— both those that set a different compiler explicitly (the Canadian
cross uses `MINGW_HOST_CC`) and the compiler-less `--host=<triplet>`
cross configures that rely on autoconf's host-prefixed tool search,
where an explicit `CC` would suppress it (known sites:
`tools/mingw-w64-gcc:mingw-headers` and `:mingw-crt`, whose CRT must
be compiled by the `x86_64-w64-mingw32-gcc` found on `PATH`). The M2
checklist enumerates these. After (a)–(b) the minimal consumer build
stanza is:

```starlark
stage2_autotools_build(
    name = "hello",
    configure = "@hello_src//:configure",
    configure_args = ["--disable-nls", "CFLAGS=-O2", "LDFLAGS=--static"],
    srcs = "@hello_src//:srcs",
)
```

**(c) `make` folds into the userland.** The separate `make` parameter
is a bootstrap-tier artifact: in stages 0–1, make exists before any
userland does (it is the first thing the seed compiles), so the
internal rules must inject it independently of the shell. At the
stage-2 tier that distinction is meaningless — so `make-s2` joins the
`userland-s2` `tree_merge`, plain `make` resolves from the userland's
`bin/` on `PATH`, and the public wrappers stop exposing or threading
a `make` parameter at all. Consequences: a custom userland (§3.4)
that runs make-driven builds must include a make (compose
`//platform/userland:make` in, or bring your own — which also makes
"use a different make" a userland choice rather than a special
case); the internal `make` attribute remains on the raw rules for the
stage-0/1 tiers only.

**(d) `stage2_run` input naming.** `stage2_run` exposes
`inputs = {"TOKEN": "//label"}` for inputs referenced by `%{TOKEN}` and
`extra_inputs = [...]` for additional declared dependencies. The
wrapper translates the token-first public mapping to the internal
label-keyed rule attribute Bazel needs for dependency tracking. These
names replace the ambiguous public `files` and `srcs` parameters;
Autotools `srcs` remains unchanged because it denotes a source tree.

Note: (a)–(d) change action keys for existing targets — a one-time
cache invalidation, acceptable at the pivot.

### 3.4 Composable userlands

Consumers can build a custom userland — smaller or larger than the
default — and thread it through any stage2 rule. This is a
first-class, documented capability:

- **Compose**: `stage2_tree_merge` over any mix of
  `//platform/userland:*` component aliases and consumer-built trees
  (later trees win on path conflicts, as today).
- **Extend**: new userland-grade packages (m4, bison, flex, patch,
  pkg-config, perl, …) are ordinary `stage2_autotools_build` targets —
  built on the default userland with the stage-2 compiler, they carry
  the zero-prebuilt property themselves, so merging them in preserves
  the guarantee. The stage-1/busybox path that builds the *base*
  packages (a shell cannot build itself) stays internal; consumers
  never need it.
- **Use**: every wrapper accepts `userland = ":my-userland"` with
  caller values taking precedence. For `stage2_autotools_build` and
  `stage2_run` this is the existing `STAGE2_KWARGS | kwargs`
  union; `stage2_tree_merge`/`stage2_dist_tarball` cannot splat the
  full preset (the underlying rules have no `build_cc`-family attrs)
  and instead take a userland-only preset, e.g.
  `USERLAND_KWARGS = {"userland": Label(...)}` with the same
  `| kwargs` override semantics.
- **Contract** (documented in `docs/api.md`): a userland tree must
  provide `bin/bash` (the preamble execs it directly) plus the
  coreutils the preamble itself uses (`mkdir`, `ln`). The minimal
  library-composed userland is therefore the merge of
  `//platform/userland:bash` and `//platform/userland:coreutils`, not
  separately packaged `mkdir` and `ln` executables. A make-driven build
  additionally needs `bin/make` (the default userland includes GNU make
  per §3.3(c)), and an Autotools install flow needs `bin/install` when
  its generated rules invoke the exported `INSTALL`; beyond that,
  contents are dictated by what the consumer's own configure/make flows
  invoke (`stage2_dist_tarball` additionally needs `find`, `touch`,
  `tar`, `gzip`). The tripwire cannot police a consumer-supplied
  userland's provenance: composing from `//platform/userland:*` and
  stage2-built trees preserves the guarantee; merging in a foreign
  prebuilt tree is possible and is the consumer's own breach — stated
  plainly in `docs/trust.md`.

### 3.5 Stability policy

- Stable: `defs.bzl` exports, `//platform` labels, the guarantee itself,
  the documented `.bazelrc` requirement.
- Unstable/internal: everything under `//toolchain/...`, action
  scripts, the preamble, log formats, exact component versions
  (documented but bumpable per §8.1).

### 3.6 Opt-in dynamic runtime: libc and loader

Today every program that executes inside an action must be static,
because the empty root has no ELF interpreter — which is why
`LDFLAGS=--static`/`--disable-shared` conventions run through the whole
tree and get forced onto consumers. That constraint is fundamental only
for the *bootstrap* (the seeds must run before anything exists to load
them); beyond stage 2 it is a choice, because the loader itself can be
a stage-2 artifact. The library therefore offers an opt-in dynamic
runtime:

- **Mechanism — the `/bin/sh` precedent generalizes.** The sandbox
  root is writable, and musl unifies loader and libc in one
  from-source file (`ld-musl-<arch>.so.1` is a name for `libc.so`).
  With `dynamic_runtime = True`, the preamble creates
  `/lib/ld-musl-<arch>.so.1 -> $ROOT/<libc tree>/lib/libc.so` inside
  the ephemeral sandbox — with the same refuse-if-it-already-exists
  check as `/bin/sh` — and exports `LD_LIBRARY_PATH` over the declared
  runtime trees' `lib/` directories. Nothing is mounted from the host;
  the link dies with the sandbox; the runtime is a declared, from-source
  input, so the guarantee is untouched. This is the same trust class as
  the `/bin/sh` symlink.
- **Platform component.** The stage-2 musl build re-enables its shared
  library (musl builds static and shared together; `--disable-shared`
  was a narrowing), exposed as `//platform:libc`. In-repo build
  conventions stay `--static` everywhere; nothing changes for existing
  targets.
- **API.** `dynamic_runtime = False` default on `stage2_run` and
  `stage2_autotools_build`; static-first remains the ethos. When
  enabled, the platform libc tree is threaded automatically;
  additional shared-library trees ride along via the existing
  `path_trees`-style list (their `lib/` joins `LD_LIBRARY_PATH`).
- **What consumers get.** A program built by the stage-2 toolchain
  *without* `-static` is a standard musl dynamic binary whose baked
  `PT_INTERP` is exactly the path the opt-in provides — it runs
  in-sandbox for configure run-tests, plugin/dlopen scenarios, and
  run-the-artifact checks, and it runs unchanged on any musl system
  (Alpine) afterwards. This also opens the path to a future dynamic
  `//platform:python` with working extension modules.
- **Limits.** musl-only and matching-arch; glibc programs are out of
  scope for v1 (a from-source glibc platform component is possible but
  a sizable separate effort). Foreign prebuilt dynamic binaries become
  mechanically runnable once a loader exists — same policy line as
  custom userlands: the runtime the library provides is from-source;
  imported provenance is the consumer's own breach.

## 4. Consumer experience

`MODULE.bazel`:

```starlark
bazel_dep(name = "stage2.bzl", version = "1.0.0")
bazel_dep(name = "platforms", version = "1.1.0")   # for the select() keys

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

`.bazelrc`, two tiers (workspace flags do not propagate from
dependencies). Tier 1 is mandatory and is the stable contract; the
first three lines are what the tripwire enforces (§5.1 — forgetting
them fails loudly); the network line is equally required for the
guarantee but is *not* tripwire-detectable, so it is contract, not
enforcement:

```
common --enable_platform_specific_config
build:linux --experimental_use_hermetic_linux_sandbox
build:linux --spawn_strategy=linux-sandbox
build:linux --sandbox_default_allow_network=false
```

Tier 2 is recommended hygiene for stage2-only workspaces and must be
**omitted** in mixed repos (see the toolchain-autodetection bullet
below):

```
build --repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1
```

Documented costs and constraints:

- Linux x86_64/aarch64 only; user namespaces required (AppArmor note).
- First build bootstraps the platform (~40 min small machine) in the
  consumer's output base; afterwards fully cached. A shared
  `--disk_cache` makes it near-instant across workspaces.
- `BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1` disables host C++ toolchain
  autodetection workspace-wide; consumers mixing stage2 targets with
  ordinary `cc_binary` targets must not set it, and instead accept
  autodetection for their non-stage2 targets (document both modes).

Worked examples shipped in docs (§9): autotools package (hello),
arbitrary-script build (`stage2_run`), custom embedded GCC
(`stage2_gcc(name, target)`), Windows-hosted variant
(`stage2_gcc_w64`).

## 5. The guarantee as a product feature

### 5.1 Enforcement (exists; improve messaging)

The preamble's `/bin/sh` tripwire is the cross-repo enforcement point:
actions refuse to run outside the empty hermetic sandbox. Improve the
error to be consumer-facing — print the exact `.bazelrc` block to copy
(the current text references this repo's own `.bazelrc`).

### 5.2 Verification (new)

Ship a documented audit recipe: for any target built through the API,

```
bazel aquery 'inputs(".*", //your:target)' --output=text
```

filtered to show that every input is (a) a file from a pinned source
repository, (b) an output of a stage-2 platform target, or (c) the
target's own sources. Provide this as a small script
(`tools/audit/` or docs snippet) rather than an aspect in v1; an
aspect-based `stage2_provenance` check is a stretch goal. Document
honestly what is *not* claimed: the Linux kernel is ambient; stage 0/1
use the two documented binary seeds; timing/nondeterminism inside
actions is out of scope.

## 6. Repository restructuring

### 6.1 Visibility lockdown

- Add `package(default_visibility = ...)` restrictions: `//toolchain`
  targets become visible only to `//platform`, `//tools/...`,
  `//examples/...`. The `//platform` aliases are `//visibility:public`.
- Load-visibility (`visibility()` in .bzl files) for
  `toolchain/build_defs.bzl` and `toolchain/stage2.bzl` restricted to
  this module, once `defs.bzl` re-exports exist. `defs.bzl` is public.
- **Repoint the .bzl-internal `Label()` references at the public
  aliases** — without this, the lockdown breaks every exported macro
  when expanded in a consumer package: `STAGE2_KWARGS`
  (`userland`, and `make` until §3.3(c) removes it) and the
  `gcc()`/`gcc_w64()` macros (`host-gcc-s2` path_trees,
  `userland-s2` for dist, the mingw tree) must reference
  `//platform:*` labels, whose aliases are public and whose
  alias→actual edge is visibility-checked from `//platform` (which
  is allowlisted).
- Caveat: existing `//toolchain` public targets referenced in the
  README examples move to `//platform` names in the same change.

### 6.2 Dogfooding

`tools/*/BUILD.bazel` and `examples/BUILD.bazel` migrate to
`load("//:defs.bzl", ...)` and `//platform:*` labels only. CI building
`//tools/...` then continuously proves the public API is sufficient
for the hardest known consumers (Canadian GCC, LLVM, SDK extraction).

### 6.3 Committed consumer e2e module

Commit the verified external test module as `e2e/consumer/` (own
`MODULE.bazel` with `local_path_override(path = "../..")`, own
`.bazelrc`, hello build + in-sandbox run). It is excluded from the
parent build (`.bazelignore`: `e2e/consumer`) and driven by CI (§7).

## 7. Testing and CI

1. **Lint**: buildifier check job (new, fast).
2. **Analysis**: `bazel build --nobuild //...` on x86_64 and arm64
   (fast; catches Starlark/API regressions).
3. **e2e consumer**: `cd e2e/consumer && bazel build //:hello-output`
   with a `--disk_cache` carried in the Actions cache (same
   resumable-cache pattern as the darwin release jobs; steady-state
   runtime is minutes, cold runs bootstrap once per cache lineage).
4. **Release matrix**: the existing five-platform workflow, unchanged,
   now doubling as the dogfood proof.
5. **Starlark unit tests** (optional, later): factor `_subst` and the
   preamble assembly into pure functions and cover with
   bazel_skylib's `unittest`.

## 8. Versioning and BCR publication

### 8.1 Versioning policy

- Semver on the API of §3.5 — as a communication convention only.
  bzlmod gives it no enforcement: `compatibility_level` is a
  deprecated no-op since Bazel 8.6/9.1 (do not specify it), and MVS
  can silently upgrade a consumer across a major whenever another
  module in its graph requests one.
- Patch: internal fixes, URL/mirror bumps with identical sha256.
- Minor: new exports; pinned component version bumps (GCC 15.2.0 →
  next, LLVM, SDK generation) — these change consumer *outputs*, so
  they are never silent patches.
- Major: changes to the guarantee, the `.bazelrc` contract, or
  removed/renamed exports. Because levels are unenforced, the
  mechanism for breaking changes is the upstream-recommended one:
  removed/renamed exports leave `fail()` stubs for one major cycle
  with an actionable message pointing at the CHANGELOG migration
  section.
- `module(...)` gains `bazel_compatibility = [">=9.0.0"]`: the
  declared floor must equal what CI actually exercises (today
  `.bazelversion` 9.2.0 plus latest). If a lower floor is ever
  declared, a CI job pinning that floor version must land with it.

### 8.2 Publication: deferred

Whether/where to publish (BCR, a self-hosted registry, or
overrides-only) is a later decision and **not part of this
implementation**. For when it is made, the constraints already
identified, recorded so they are not rediscovered: (a) validate the
dotted module name `stage2.bzl` against the registry's tooling as a
go/no-go gate (fallback: `stage2`); (b) registry presubmit must be
loading/analysis-phase only — presubmit runs are uncached, cold, and
would mean a multi-hour bootstrap with full source fetching, and
whether the registry's containerized Linux workers can create the
user/mount namespaces the hermetic sandbox needs is unverified
(note: the AppArmor userns restriction is an Ubuntu 23.10+/24.04
host issue relevant to GitHub runners, not an established property
of registry CI); (c) a release workflow producing a tagged source archive plus
its integrity hash is the only new automation required. Nothing in
M1–M3 blocks on any of this.

## 9. Documentation plan

- `README.md`: reframe top section library-first (what you can build
  with it, the guarantee, the 20-line quickstart), then the toolchain
  showcase, then the existing deep narrative (unchanged — it is the
  trust argument).
- `docs/consumers.md`: quickstart, `.bazelrc` contract, costs,
  platform constraints, disk-cache advice, troubleshooting (tripwire
  message, AppArmor, VPATH/`.deps` gotcha).
- `docs/api.md`: every export of `defs.bzl`, attributes,
  `%{token}` substitution semantics, `%{OUT}`/`%{JOBS}`.
- `docs/trust.md`: the guarantee, seeds, stages, audit recipe, what is
  not claimed.
- `CHANGELOG.md`: start at 1.0.0.
- Evaluate stardoc for `docs/api.md` generation; hand-written is
  acceptable for v1 (stardoc drags in extra deps).

## 10. Risks and open questions

| risk | mitigation |
|---|---|
| `--experimental_use_hermetic_linux_sandbox` changes/renames in a future Bazel | CI against latest Bazel; `bazel_compatibility` ceiling if needed; the flag's evolution tracked per release |
| Seed URL rot (musl.cc, Alpine CDN) multiplied by consumer count | mirror list in pins where redistribution is clean; document the sha256-keeps-mirrors-honest property; Apple SDK stays direct-from-Apple (no mirroring) with the existing refresh recipe |
| Consumers misuse `BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN` in mixed repos | §4 documents both modes |
| First-build cost surprises consumers | quickstart states it in the first screen; disk-cache recipe |
| Registry constraints discovered late (name grammar, presubmit limits) | recorded now in §8.2 for the deferred decision |

## 11. Implementation plan (phased, with acceptance criteria)

**M1 — API formalization**
1. Add `defs.bzl`, `platform/BUILD.bazel` +
   `platform/userland/BUILD.bazel` aliases.
2. Implement `use_platform_cc` (autotools wrapper only, appended) and
   `stage_cc`; add the userland-preset `stage2_tree_merge`/
   `stage2_dist_tarball` wrappers; fold `make-s2` into the
   `userland-s2` merge and drop `make` from the public wrappers
   (§3.3(c)); rename hermetic inputs to `inputs`/`extra_inputs`
   (§3.3(d)).
3. Consumer-facing tripwire message (prints the tier-1 `.bazelrc`
   block).
4. Acceptance: `bazel build --nobuild //...` green; `e2e/consumer`
   (temporarily via local edit) analyzes using only `defs.bzl` +
   `//platform` labels.

**M2 — restructure and dogfood**
5. Migrate `tools/*` and `examples/` to the public API; visibility
   lockdown including the `Label()` repointing of §6.1; commit
   `e2e/consumer/` + `.bazelignore`. Known `stage_cc = False` sites:
   all `MINGW_HOST_CC` call sites in `gcc_w64`, plus
   `tools/mingw-w64-gcc:mingw-headers` and `:mingw-crt` (compiler-less
   host-prefixed configures). Verify `use_platform_cc` appending
   against every autotools call site's PATH expectations.
6. Acceptance: full `//tools/...` build green on the dev VM (cache
   makes this cheap); e2e consumer builds and runs hello.

**M3 — CI + docs**
7. Buildifier + analysis jobs; e2e consumer job with resumable disk
   cache.
8. Write `docs/consumers.md`, `docs/api.md`, `docs/trust.md`,
   `CHANGELOG.md`; reframe README top.
9. Acceptance: all CI jobs green twice in a row (cache warm + cold
   paths both exercised).

**M4 — dynamic runtime (§3.6, after M3)**
10. Re-enable musl-s2's shared library; add `//platform:libc`;
    implement `dynamic_runtime` in the preamble (loader link with the
    refuse-if-exists check, `LD_LIBRARY_PATH` assembly) and surface it
    on `stage2_run`/`stage2_autotools_build`.
11. Acceptance: an e2e case builds a shared-linked program with the
    stage-2 toolchain (no `-static`) and runs it in-sandbox; the same
    binary runs on Alpine unchanged; all existing targets' action
    keys outside musl-s2's chain are unaffected.

**M5 — (deferred) release engineering and publication**
Not part of this implementation; see §8.2 for the recorded
constraints when the decision is made. The only forward-looking item
kept in scope now: add `bazel_compatibility = [">=9.0.0"]` to
`module(...)` during M1 (the floor CI actually tests, per §8.1).

Sequencing note: M1–M2 are one logical change from consumers'
perspective; land them together. M3 and M4 are independent of each
other.
