"""Shared configuration for building the example packages with stage 2.

Everything here describes the self-hosted <arch>-unknown-linux-musl
stage-2 host toolchain and the from-source GNU userland: any action
using these builds with zero prebuilt binaries among its inputs.

The select()s mirror the ones inside //internal/BUILD.bazel (kept
separate so that file's action keys stay stable).
"""

load(
    "//internal:build_defs.bzl",
    "autotools_build",
    "dist_tarball",
    "hermetic_run",
    "tree_merge",
)

visibility("//...")

NO_MATCH = "this workspace's hermetic prerequisites are only wired for x86_64/aarch64 Linux hosts"

STAGE_CC = select(
    {
        "@platforms//cpu:aarch64": [
            "CC=aarch64-unknown-linux-musl-gcc -static",
            "CXX=aarch64-unknown-linux-musl-g++ -static",
        ],
        "@platforms//cpu:x86_64": [
            "CC=x86_64-unknown-linux-musl-gcc -static",
            "CXX=x86_64-unknown-linux-musl-g++ -static",
        ],
    },
    no_match_error = NO_MATCH,
)

STAGE_BUILD_CC = select(
    {
        "@platforms//cpu:aarch64": "aarch64-unknown-linux-musl-gcc -static",
        "@platforms//cpu:x86_64": "x86_64-unknown-linux-musl-gcc -static",
    },
    no_match_error = NO_MATCH,
)

STAGE_BUILD_CXX = select(
    {
        "@platforms//cpu:aarch64": "aarch64-unknown-linux-musl-g++ -static",
        "@platforms//cpu:x86_64": "x86_64-unknown-linux-musl-g++ -static",
    },
    no_match_error = NO_MATCH,
)

TOOL_SUBDIR = select(
    {
        "@platforms//cpu:aarch64": "aarch64-unknown-linux-musl",
        "@platforms//cpu:x86_64": "x86_64-unknown-linux-musl",
    },
    no_match_error = NO_MATCH,
)

HOST_TRIPLE = select(
    {
        "@platforms//cpu:aarch64": "aarch64-unknown-linux-musl",
        "@platforms//cpu:x86_64": "x86_64-unknown-linux-musl",
    },
    no_match_error = NO_MATCH,
)

OPT_FLAGS = [
    "CFLAGS=-O2",
    "CXXFLAGS=-O2",
    # libtool intercepts a plain -static; --static reaches the driver.
    "LDFLAGS=--static",
]

# --build for Canadian-cross configures (build != host != target). The
# stage-2 toolchain's triplet is the build system; config.guess would
# misreport it as -gnu inside the sandbox.
BUILD_TRIPLE_ARG = select(
    {
        "@platforms//cpu:aarch64": ["--build=aarch64-unknown-linux-musl"],
        "@platforms//cpu:x86_64": ["--build=x86_64-unknown-linux-musl"],
    },
    no_match_error = NO_MATCH,
)

# Compiler spellings for actions whose HOST is Windows (Canadian cross):
# a caller-supplied build->host mingw cross GCC provides these commands.
# Static output needs nothing but the OS's own DLLs at runtime.
MINGW_HOST_CC = [
    "CC=x86_64-w64-mingw32-gcc -static",
    "CXX=x86_64-w64-mingw32-g++ -static",
]

# Like OPT_FLAGS, for PE host binaries: --no-insert-timestamp keeps the
# PE header timestamp field zero so Windows-hosted trees are reproducible.
W64_OPT_FLAGS = [
    "CFLAGS=-O2",
    "CXXFLAGS=-O2",
    "LDFLAGS=--static -Wl,--no-insert-timestamp",
]

BINUTILS_ARGS = [
    "--disable-nls",
    "--disable-werror",
    "--disable-gdb",
    "--disable-gdbserver",
    "--disable-sim",
    "--disable-gprofng",
    "--disable-shared",
    "--enable-static",
    "--disable-dependency-tracking",
]

# Label() (not plain strings) so the references bind to THIS module:
# macro-supplied label strings resolve relative to the calling package,
# which for a dependent module would be the wrong repository.
STAGE2_KWARGS = dict(
    build_cc = STAGE_BUILD_CC,
    build_cxx = STAGE_BUILD_CXX,
    tool_subdir = TOOL_SUBDIR,
    userland = Label("//trees:default_userland"),
)

USERLAND_KWARGS = {
    "userland": Label("//trees:default_userland"),
}

def _reject_make(wrapper, kwargs):
    if "make" in kwargs:
        fail("{} does not accept make; provide bin/make through userland instead".format(wrapper))

def stage2_autotools_build(use_default_cc = True, stage_cc = True, **kwargs):
    """autotools_build preconfigured for the stage-2 toolchain + userland.

    BUILD files cannot splat **kwargs, so packages that need bespoke
    targets (e.g. mingw's multi-step build) use this wrapper instead.

    The default compiler is appended after caller-supplied path_trees
    unless use_default_cc is false. STAGE_CC is appended to
    configure_args unless stage_cc is false.

    Args:
      use_default_cc: Whether to append //trees:cc to path_trees.
      stage_cc: Whether to append STAGE_CC to configure_args.
      **kwargs: Attributes forwarded to the internal autotools rule.
    """
    _reject_make("stage2_autotools_build", kwargs)
    if use_default_cc:
        kwargs["path_trees"] = kwargs.get("path_trees", []) + [
            Label("//trees:cc"),
        ]
    if stage_cc:
        kwargs["configure_args"] = kwargs.get("configure_args", []) + STAGE_CC
    autotools_build(**(STAGE2_KWARGS | kwargs))

def stage2_run(inputs = {}, extra_inputs = [], **kwargs):
    """hermetic_run preconfigured for the stage-2 toolchain + userland.

    Args:
      inputs: Token name -> label mapping for inputs referenced as %{TOKEN}.
      extra_inputs: Additional declared inputs that need no token.
      **kwargs: Attributes forwarded to the internal hermetic-run rule.
    """
    _reject_make("stage2_run", kwargs)
    for old_name, replacement in [
        ("files", "inputs"),
        ("srcs", "extra_inputs"),
    ]:
        if old_name in kwargs:
            fail("stage2_run no longer accepts {}; use {} instead".format(
                old_name,
                replacement,
            ))
    if "input_tokens" in kwargs:
        fail("stage2_run.input_tokens is internal; use inputs instead")

    input_tokens = {}
    for token, label in inputs.items():
        if label in input_tokens:
            fail("stage2_run.inputs maps {} to more than one token".format(label))
        input_tokens[label] = token
    kwargs["input_tokens"] = input_tokens
    kwargs["extra_inputs"] = extra_inputs
    hermetic_run(**(STAGE2_KWARGS | kwargs))

def stage2_tree_merge(**kwargs):
    """tree_merge preconfigured with the default stage-2 userland."""
    tree_merge(**(USERLAND_KWARGS | kwargs))

def stage2_dist_tarball(**kwargs):
    """dist_tarball preconfigured with the default stage-2 userland."""
    dist_tarball(**(USERLAND_KWARGS | kwargs))
