"""The `gcc` macro: a bare-metal newlib GCC cross toolchain package.

Scope: this is specifically the newlib bare-metal recipe (binutils +
GCC/newlib combined tree). Targets with their own C runtime story build
their sequence out of stage2_autotools_build instead — see
//examples/mingw-w64-gcc.
"""

load(
    "//internal:stage2.bzl",
    "BINUTILS_ARGS",
    "BUILD_TRIPLE_ARG",
    "MINGW_HOST_CC",
    "OPT_FLAGS",
    "W64_OPT_FLAGS",
    "stage2_autotools_build",
    "stage2_dist_tarball",
    "stage2_run",
)

visibility("//...")

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

def gcc(name, target, gcc_args = [], gcc_version = "15.2.0"):
    """A bare-metal newlib GCC cross toolchain: binutils + gcc + dist.

    Generates:
      <name>-binutils : binutils 2.45 for `target`
      <name>          : merged toolchain prefix (gcc 15.2.0 + newlib 4.5.0
                        combined tree, installed over the binutils tree)
      dist            : <name>-<gcc_version>.tar.gz
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

def gcc_w64(name, target, host_toolchain, target_toolchain, gcc_args = [], gcc_version = "15.2.0"):
    """The Windows-hosted (Canadian cross) variant of `gcc`.

    Every action still runs inside the empty Linux sandbox; only the
    produced binaries are PE executables. Three toolchains participate,
    all of them stage-2 artifacts:
      - CC/CXX: `host_toolchain`, a build->host mingw cross, compiles
        the compiler's own sources into static .exe files;
      - CC_FOR_BUILD: stage-2 compiles the build-time generators;
      - `target_toolchain`: the Linux-hosted build->target cross (same
        GCC version) builds libgcc/newlib/libstdc++, because the freshly
        built xgcc is a Windows binary and cannot run here.

    Generates <name>-binutils, <name>, <name>-pe-check, and dist.

    Args:
      name: Base name for the generated targets.
      target: GCC target triplet.
      host_toolchain: Linux-hosted build-to-x86_64-w64-mingw32 tree.
      target_toolchain: Linux-hosted build-to-target toolchain tree.
      gcc_args: Additional arguments passed to GCC's configure.
      gcc_version: Version embedded in the distribution tarball name.
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

    # Windows binaries cannot execute in the sandbox, so the end-to-end
    # check is structural: every installed bin/*.exe must be a real PE32+
    # image — DOS MZ magic, a valid e_lfanew pointing at the PE\\0\\0
    # signature, and COFF machine 0x8664 (x86_64) — with a full
    # complement of them.
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
