"""Example recipes for bare-metal newlib GCC cross toolchains.

These macros deliberately live in the consumer workspace. They compose the
generic stage2 rules with consumer-owned binutils and GCC/newlib source
repositories declared in examples/MODULE.bazel.
"""

load(
    "@stage2.bzl",
    "stage2_autotools_build",
    "stage2_dist_tarball",
    "stage2_run",
)

visibility("//...")

_NO_MATCH = "the examples workspace's hermetic prerequisites are only wired for x86_64/aarch64 Linux hosts"

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
    no_match_error = _NO_MATCH,
)

# Compiler spellings for actions whose HOST is Windows (Canadian cross):
# a caller-supplied build->host mingw cross GCC provides these commands.
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
    "--enable-deterministic-archives",
    "--disable-dependency-tracking",
]

GCC_NEWLIB_ARGS = [
    "--enable-languages=c,c++",
    "--with-newlib",
    "--disable-shared",
    "--disable-threads",
    "--disable-tls",
    "--disable-nls",
    "--disable-libssp",
    "--disable-libquadmath",
    "--disable-libgomp",
    "--disable-multilib",
    "--enable-checking=release",
    "--disable-dependency-tracking",
    "--disable-libstdcxx-pch",
]

def newlib_gcc(name, target, gcc_args = [], gcc_version = "15.2.0"):
    """Builds a bare-metal newlib GCC cross toolchain and distribution.

    Generates a binutils target, a merged GCC/newlib toolchain, and a `dist`
    archive target in the calling package.
    """
    stage2_autotools_build(
        name = name + "-binutils",
        configure = Label("@binutils_src//:configure"),
        configure_args = ["--target=" + target] + BINUTILS_ARGS + OPT_FLAGS,
        srcs = Label("@binutils_src//:srcs"),
    )

    stage2_autotools_build(
        name = name,
        configure = Label("@gcc_combined_src//:configure"),
        configure_args = ["--target=" + target] + GCC_NEWLIB_ARGS + gcc_args + OPT_FLAGS,
        install_base = [":" + name + "-binutils"],
        srcs = Label("@gcc_combined_src//:srcs"),
    )

    stage2_dist_tarball(
        name = "dist",
        out = name + "-" + gcc_version + ".tar.gz",
        tree = ":" + name,
    )

_W64_HOST = "x86_64-w64-mingw32"

def newlib_gcc_w64(name, target, host_toolchain, target_toolchain, gcc_args = [], gcc_version = "15.2.0"):
    """Builds the Windows-hosted Canadian-cross variant of `newlib_gcc`.

    Every action still runs in the Linux sandbox. `host_toolchain` compiles
    the compiler itself as Windows executables, while `target_toolchain`
    builds target libraries because those fresh Windows executables cannot
    run during the build.

    Args:
      name: Target name and output prefix.
      target: GCC target triplet.
      host_toolchain: Build-to-Windows compiler tree.
      target_toolchain: Build-to-target compiler tree.
      gcc_args: Additional GCC configure arguments.
      gcc_version: Version suffix used for the distribution archive.
    """
    canadian_args = BUILD_TRIPLE_ARG + [
        "--host=" + _W64_HOST,
        "--target=" + target,
    ]

    stage2_autotools_build(
        name = name + "-binutils",
        configure = Label("@binutils_src//:configure"),
        configure_args = canadian_args + BINUTILS_ARGS + W64_OPT_FLAGS + MINGW_HOST_CC,
        path_trees = [host_toolchain],
        stage_cc = False,
        srcs = Label("@binutils_src//:srcs"),
    )

    stage2_autotools_build(
        name = name,
        configure = Label("@gcc_combined_src//:configure"),
        configure_args = canadian_args + GCC_NEWLIB_ARGS + gcc_args +
                         W64_OPT_FLAGS + MINGW_HOST_CC,
        install_base = [":" + name + "-binutils"],
        path_trees = [
            host_toolchain,
            target_toolchain,
        ],
        stage_cc = False,
        srcs = Label("@gcc_combined_src//:srcs"),
    )

    # Windows binaries cannot execute in the sandbox, so verify that every
    # installed bin/*.exe is an x86_64 PE image and that the set is complete.
    stage2_run(
        name = name + "-pe-check",
        inputs = {"TREE": ":" + name},
        script = """tree=%{TREE}
count=0
for exe in "$tree"/bin/*.exe; do
    magic=$(od -An -tx1 -N2 "$exe" | tr -d ' \\n')
    if [ "$magic" != "4d5a" ]; then
        echo "not a PE executable: $exe (MZ magic: $magic)" >&2
        exit 1
    fi
    lfanew=$(od -An -tu4 -j 60 -N4 "$exe" | tr -d ' \\n')
    sig=$(od -An -tx1 -j "$lfanew" -N4 "$exe" | tr -d ' \\n')
    if [ "$sig" != "50450000" ]; then
        echo "no PE signature at e_lfanew=$lfanew: $exe (got: $sig)" >&2
        exit 1
    fi
    machine=$(od -An -tx1 -j $((lfanew + 4)) -N2 "$exe" | tr -d ' \\n')
    if [ "$machine" != "6486" ]; then
        echo "COFF machine is not x86_64 (0x8664): $exe (got: $machine)" >&2
        exit 1
    fi
    count=$((count + 1))
done
if [ "$count" -lt 5 ]; then
    echo "only $count .exe files under bin/ - incomplete toolchain" >&2
    exit 1
fi
echo "$count PE32+ x86_64 executables verified (MZ + PE signature + machine) in bin/" > %{OUT}
""",
    )

    stage2_dist_tarball(
        name = "dist",
        out = name + "-" + gcc_version + ".tar.gz",
        tree = ":" + name,
    )
