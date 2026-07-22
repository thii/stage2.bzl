"""The `gcc` macro: a bare-metal newlib GCC cross toolchain package.

Scope: this is specifically the newlib bare-metal recipe (binutils +
GCC/newlib combined tree). Targets with their own C runtime story build
their sequence out of stage2_autotools_build instead — see
//tools/mingw-w64-gcc.
"""

load("//toolchain:build_defs.bzl", "dist_tarball")
load(
    "//toolchain:stage2.bzl",
    "BINUTILS_ARGS",
    "OPT_FLAGS",
    "STAGE_CC",
    "stage2_autotools_build",
)

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
        configure = "@binutils_src//:configure",
        configure_args = ["--target=" + target] + BINUTILS_ARGS + OPT_FLAGS + STAGE_CC,
        path_trees = ["//toolchain:host-gcc-s2"],
        srcs = "@binutils_src//:srcs",
    )

    stage2_autotools_build(
        name = name,
        configure = "@gcc_combined_src//:configure",
        configure_args = ["--target=" + target] + GCC_NEWLIB_ARGS + gcc_args + OPT_FLAGS + STAGE_CC,
        install_base = [":" + name + "-binutils"],
        path_trees = ["//toolchain:host-gcc-s2"],
        srcs = "@gcc_combined_src//:srcs",
    )

    dist_tarball(
        name = "dist",
        out = name + "-" + gcc_version + ".tar.gz",
        tree = ":" + name,
        userland = "//toolchain:userland-s2",
    )
