"""Internal repository rule assembling the GCC "combined tree".

GCC's top-level build system natively supports building in-tree copies of
its prerequisites (gmp/mpfr/mpc/isl, versions from
contrib/download_prerequisites) and of newlib/libgloss (the classic
one-tree cross build). Assembling the tree at fetch time means the build
action needs exactly one source input and no network.

Layout produced (repository root = GCC source root):
    configure, gcc/, libstdc++-v3/, ...   from gcc-15.2.0.tar.xz
    gmp/, mpfr/, mpc/, isl/               extracted in place
    newlib/, libgloss/                    from newlib-4.5.0.20241231.tar.gz

In-tree gmp is configured by GCC with assembly disabled (generic C), which
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

_NEWLIB = struct(
    url = [
        "https://mirrors.kernel.org/sourceware/newlib/newlib-4.5.0.20241231.tar.gz",
        "https://sourceware.org/pub/newlib/newlib-4.5.0.20241231.tar.gz",
    ],
    sha256 = "33f12605e0054965996c25c1382b3e463b0af91799001f5bb8c0630f2ec8c852",
    strip_prefix = "newlib-4.5.0.20241231",
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
    "isl": struct(
        url = [
            "https://mirrors.kernel.org/sourceware/gcc/infrastructure/isl-0.24.tar.bz2",
            "https://libisl.sourceforge.io/isl-0.24.tar.bz2",
            "https://gcc.gnu.org/pub/gcc/infrastructure/isl-0.24.tar.bz2",
        ],
        sha256 = "fcf78dd9656c10eb8cf9fbd5f59a0b6b01386205fe1934b3b287a0a1898145c0",
        strip_prefix = "isl-0.24",
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
    rctx.download_and_extract(
        url = _NEWLIB.url,
        sha256 = _NEWLIB.sha256,
        stripPrefix = _NEWLIB.strip_prefix,
        output = "_newlib",
    )

    # Bazel's repository API performs the filesystem assembly directly, so
    # fetching this source tree does not execute a host or prebuilt utility.
    for d in ["newlib", "libgloss"]:
        rctx.rename("_newlib/" + d, d)

    # Newlib's release tarball also carries headers in its top-level
    # include/ that the target code includes via the shared toplevel
    # include directory (e.g. arm-acle-compat.h for the Arm ports).
    # Merge them into the GCC tree's include/ without overwriting GCC's own
    # copies of shared headers.
    include = rctx.path("include")
    for entry in rctx.path("_newlib/include").readdir():
        destination = include.get_child(entry.basename)
        if not destination.exists:
            rctx.rename(entry, destination)
    rctx.delete("_newlib")

    rctx.file("BUILD.bazel", _BUILD_FILE)

gcc_combined_src_repo = repository_rule(
    implementation = _impl,
    doc = "GCC 15.2.0 combined source tree with in-tree newlib and prerequisites.",
)
