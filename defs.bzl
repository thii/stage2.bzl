"""Public API for the stage2.bzl rules library."""

load(
    "//internal:gcc.bzl",
    _GCC_NEWLIB_ARGS = "GCC_NEWLIB_ARGS",
    _stage2_gcc = "gcc",
    _stage2_gcc_w64 = "gcc_w64",
)
load(
    "//internal:stage2.bzl",
    _BINUTILS_ARGS = "BINUTILS_ARGS",
    _BUILD_TRIPLE_ARG = "BUILD_TRIPLE_ARG",
    _MINGW_HOST_CC = "MINGW_HOST_CC",
    _OPT_FLAGS = "OPT_FLAGS",
    _STAGE_CC = "STAGE_CC",
    _W64_OPT_FLAGS = "W64_OPT_FLAGS",
    _stage2_autotools_build = "stage2_autotools_build",
    _stage2_dist_tarball = "stage2_dist_tarball",
    _stage2_run = "stage2_run",
    _stage2_tree_merge = "stage2_tree_merge",
)

visibility("public")

stage2_autotools_build = _stage2_autotools_build
stage2_run = _stage2_run
stage2_tree_merge = _stage2_tree_merge
stage2_dist_tarball = _stage2_dist_tarball
stage2_gcc = _stage2_gcc
stage2_gcc_w64 = _stage2_gcc_w64

STAGE_CC = _STAGE_CC
OPT_FLAGS = _OPT_FLAGS
BINUTILS_ARGS = _BINUTILS_ARGS
BUILD_TRIPLE_ARG = _BUILD_TRIPLE_ARG
MINGW_HOST_CC = _MINGW_HOST_CC
W64_OPT_FLAGS = _W64_OPT_FLAGS
GCC_NEWLIB_ARGS = _GCC_NEWLIB_ARGS
