"""Shared configuration for building //tools packages with stage 2.

Everything here describes the self-hosted <arch>-unknown-linux-musl
stage-2 host toolchain and the from-source GNU userland: any action
using these builds with zero prebuilt binaries among its inputs.

The select()s mirror the ones inside //toolchain/BUILD.bazel (kept
separate so that file's action keys stay stable).
"""

load("//toolchain:build_defs.bzl", "autotools_build", "hermetic_run")

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
# the build->host mingw cross gcc from //tools/mingw-w64-gcc. Static, so
# the produced .exe files need nothing but the OS's own DLLs at runtime.
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

STAGE2_KWARGS = dict(
    build_cc = STAGE_BUILD_CC,
    build_cxx = STAGE_BUILD_CXX,
    make = "//toolchain:make-s2",
    tool_subdir = TOOL_SUBDIR,
    userland = "//toolchain:userland-s2",
)

def stage2_autotools_build(**kwargs):
    """autotools_build preconfigured for the stage-2 toolchain + userland.

    BUILD files cannot splat **kwargs, so packages that need bespoke
    targets (e.g. mingw's multi-step build) use this wrapper instead.
    """
    autotools_build(**(STAGE2_KWARGS | kwargs))

def stage2_hermetic_run(**kwargs):
    """hermetic_run preconfigured for the stage-2 toolchain + userland."""
    hermetic_run(**(STAGE2_KWARGS | kwargs))
