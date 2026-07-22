"""Compile a program with one of the just-built cross toolchains.

The toolchain install tree is an ordinary Bazel output (a tree artifact),
so this is the end-to-end proof: a compiler that was built from source
inside the hermetic sandbox is itself run inside the hermetic sandbox to
cross-compile a program. The action's shell is the from-source GNU
userland's bash; the sandbox root stays empty and no prebuilt binary is
among the inputs.
"""

def _cross_binary_impl(ctx):
    tc = ctx.file.toolchain
    ul = ctx.file.userland
    p = ctx.attr.target_prefix
    out = ctx.actions.declare_file(ctx.label.name + "." + ctx.attr.out_ext)
    binary = ctx.actions.declare_file(ctx.label.name + ".bin")
    size = ctx.actions.declare_file(ctx.label.name + ".size.txt")

    srcs = " ".join(['"$ROOT/{}"'.format(s.path) for s in ctx.files.srcs])
    copts = " ".join(["'" + o + "'" for o in ctx.attr.copts])
    script = """set -eu
ROOT="$PWD"
export PATH="$ROOT/{tc}/bin"
{p}-gcc {copts} {srcs} -o "$ROOT/{out}"
{p}-objcopy -O binary "$ROOT/{out}" "$ROOT/{bin}"
{p}-size "$ROOT/{out}" > "$ROOT/{size}"
""".format(
        tc = tc.path,
        p = p,
        copts = copts,
        srcs = srcs,
        out = out.path,
        bin = binary.path,
        size = size.path,
    )
    ctx.actions.run(
        executable = ul.path + "/bin/bash",
        arguments = ["-c", script],
        inputs = depset(ctx.files.srcs + ctx.files.hdrs + [tc, ul]),
        outputs = [out, binary, size],
        mnemonic = "CrossCompile",
        progress_message = "Cross-compiling %{label} with the from-source toolchain",
    )
    return [DefaultInfo(files = depset([out, binary, size]))]

cross_binary = rule(
    implementation = _cross_binary_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".c", ".cc", ".S"]),
        "hdrs": attr.label_list(allow_files = [".h"]),
        "copts": attr.string_list(),
        "target_prefix": attr.string(
            mandatory = True,
            doc = "Tool name prefix, e.g. riscv-none-elf or x86_64-w64-mingw32.",
        ),
        "out_ext": attr.string(default = "elf"),
        "toolchain": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "userland": attr.label(
            default = Label("//toolchain:userland-s2"),
            allow_single_file = True,
            cfg = "exec",
        ),
    },
    doc = "A binary built with one of the //tools cross toolchains.",
)
