"""Internal repository rule assembling the host GCC source tree.

GCC's top-level build supports in-tree copies of GMP, MPFR, and MPC. The
stage-2 Linux-musl host compiler uses those prerequisites but explicitly
disables ISL and does not use newlib, so this repository contains only the
source closure needed by the default userland.

Layout produced (repository root = GCC source root):
    configure, gcc/, libstdc++-v3/, ...   from gcc-15.2.0.tar.xz
    gmp/, mpfr/, mpc/                     extracted in place

In-tree GMP is configured by GCC with assembly disabled (generic C), which
also removes its build-time m4 requirement.
"""

visibility("//...")

_GCC = struct(
    url = [
        "https://ftpmirror.gnu.org/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz",
        "https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz",
    ],
    sha256 = "438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e",
    strip_prefix = "gcc-15.2.0",
)

# name in tree -> archive; versions per gcc-15.2.0/contrib/download_prerequisites.
_PREREQUISITES = {
    "gmp": struct(
        url = [
            "https://ftpmirror.gnu.org/gmp/gmp-6.2.1.tar.bz2",
            "https://ftp.gnu.org/gnu/gmp/gmp-6.2.1.tar.bz2",
            "https://gcc.gnu.org/pub/gcc/infrastructure/gmp-6.2.1.tar.bz2",
        ],
        sha256 = "eae9326beb4158c386e39a356818031bd28f3124cf915f8c5b1dc4c7a36b4d7c",
        strip_prefix = "gmp-6.2.1",
    ),
    "mpfr": struct(
        url = [
            "https://ftpmirror.gnu.org/mpfr/mpfr-4.1.0.tar.bz2",
            "https://ftp.gnu.org/gnu/mpfr/mpfr-4.1.0.tar.bz2",
            "https://gcc.gnu.org/pub/gcc/infrastructure/mpfr-4.1.0.tar.bz2",
        ],
        sha256 = "feced2d430dd5a97805fa289fed3fc8ff2b094c02d05287fd6133e7f1f0ec926",
        strip_prefix = "mpfr-4.1.0",
    ),
    "mpc": struct(
        url = [
            "https://ftpmirror.gnu.org/mpc/mpc-1.2.1.tar.gz",
            "https://ftp.gnu.org/gnu/mpc/mpc-1.2.1.tar.gz",
            "https://gcc.gnu.org/pub/gcc/infrastructure/mpc-1.2.1.tar.gz",
        ],
        sha256 = "17503d2c395dfcf106b622dc142683c1199431d095367c6aacba6eec30340459",
        strip_prefix = "mpc-1.2.1",
    ),
}

_BUILD_FILE = """filegroup(
    name = "srcs",
    # No testsuite exclusions: several subdirectories (libiberty,
    # libstdc++-v3, ...) list testsuite/Makefile in AC_CONFIG_FILES, so
    # configure fails if testsuite/Makefile.in is missing.
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
exports_files(["configure"])
"""

def _impl(rctx):
    rctx.download_and_extract(
        url = _GCC.url,
        sha256 = _GCC.sha256,
        stripPrefix = _GCC.strip_prefix,
    )
    for name, archive in _PREREQUISITES.items():
        rctx.download_and_extract(
            url = archive.url,
            sha256 = archive.sha256,
            stripPrefix = archive.strip_prefix,
            output = name,
        )

    rctx.file("BUILD.bazel", _BUILD_FILE)

gcc_source_repo = repository_rule(
    implementation = _impl,
    doc = "GCC 15.2.0 source tree with the host compiler prerequisites.",
)
