"""Public API for the stage2.bzl rules library."""

load(
    "//internal:compiler_seed.bzl",
    _stage2_compiler_seed = "stage2_compiler_seed",
)
load(
    "//internal:shell_seed.bzl",
    _stage2_shell_seed = "stage2_shell_seed",
)
load(
    "//internal:stage2.bzl",
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
stage2_compiler_seed = _stage2_compiler_seed
stage2_shell_seed = _stage2_shell_seed
