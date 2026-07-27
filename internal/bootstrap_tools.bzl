"""Builds bootstrap utilities from source using only the selected seeds."""

load(":compiler_seed.bzl", "CompilerSeedInfo")
load(":shell_seed.bzl", "ShellSeedInfo")

visibility("//...")

def _expand(template, roots):
    result = template
    for token, root in roots.items():
        result = result.replace("%{" + token + "}", root)
    if "%{" in result:
        fail("unknown compiler-seed root token in {!r}".format(template))
    return result

def _assignment_value(template, roots):
    """Escapes a seed value for assignment inside shell double quotes."""
    escaped = template.replace("\\", "\\\\")
    escaped = escaped.replace("\"", "\\\"")
    escaped = escaped.replace("`", "\\`")
    escaped = escaped.replace("$", "\\$")
    shell_roots = {
        token: "$ROOT/" + root
        for token, root in roots.items()
    }
    return _expand(escaped, shell_roots)

def _manifest_field(value):
    if "\n" in value or "\r" in value or "\t" in value:
        fail("bootstrap materializer paths and link targets cannot contain tabs or newlines: {!r}".format(value))
    return value

def _root_from_main(main):
    suffix = "/main.c"
    if not main.path.endswith(suffix):
        fail("toybox_main must end in /main.c, got {!r}".format(main.path))
    return main.path[:-len(suffix)]

def _path_value(entries, roots):
    return ":".join([
        _assignment_value(entry, roots)
        for entry in entries
    ])

def _source_bootstrap_tools_impl(ctx):
    shell = ctx.attr.shell_seed[ShellSeedInfo]
    if shell.tools_executable:
        output = ctx.actions.declare_file(
            ctx.label.name + "/" + shell.tools_executable.basename,
        )
        ctx.actions.symlink(
            output = output,
            target_file = shell.tools_executable,
            is_executable = True,
        )
        return [DefaultInfo(
            executable = output,
            files = depset([output]),
        )]

    seed = ctx.attr.compiler_seed[CompilerSeedInfo]

    # Toybox enters multicall mode by recognizing its own basename. Keep the
    # declared executable named `toybox` even though the producing target has
    # a more descriptive name.
    output = ctx.actions.declare_file(ctx.label.name + "/toybox")
    materializer = ctx.actions.declare_file(ctx.label.name + ".materialize")
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    scratch = output.path + ".scratch"

    original_roots = dict(seed.roots)
    copied_roots = {
        token: scratch + "/compiler-seed/" + token
        for token in seed.roots
    }

    manifest_lines = []
    for token in sorted(seed.roots):
        manifest_lines.append("copy\t{}\t{}".format(
            _manifest_field(seed.roots[token]),
            _manifest_field(copied_roots[token]),
        ))
    manifest_lines.append("copy\t{}\t{}".format(
        _manifest_field(_root_from_main(ctx.file.toybox_main)),
        _manifest_field(scratch + "/toybox"),
    ))
    for link in sorted(seed.symlinks):
        manifest_lines.append("symlink\t{}\t{}".format(
            _manifest_field(seed.symlinks[link]),
            _manifest_field(_expand(link, copied_roots)),
        ))
    ctx.actions.write(manifest, "\n".join(manifest_lines) + "\n")

    direct_exports = []
    for name in sorted(seed.env):
        if name in ["CC", "CXX"]:
            continue

        # Zig creates these directories itself. They cannot live below the
        # read-only original seed root during the first compiler invocation.
        if name == "ZIG_GLOBAL_CACHE_DIR":
            value = "$ROOT/{}.zig-global-cache".format(materializer.basename)
        elif name == "ZIG_LOCAL_CACHE_DIR":
            value = "$ROOT/{}.zig-local-cache".format(materializer.basename)
        else:
            value = _assignment_value(seed.env[name], original_roots)
        direct_exports.append("export {}=\"{}\"".format(name, value))

    copied_exports = []
    for name in sorted(seed.env):
        if name in ["CC", "CXX"]:
            continue
        if name == "ZIG_GLOBAL_CACHE_DIR":
            value = "$SCRATCH/zig-global-cache"
        elif name == "ZIG_LOCAL_CACHE_DIR":
            value = "$SCRATCH/zig-local-cache"
        else:
            value = _assignment_value(seed.env[name], copied_roots)
        copied_exports.append("export {}=\"{}\"".format(name, value))

    direct_path = _path_value(seed.path, original_roots)
    copied_path = _path_value(seed.path, copied_roots)
    direct_cc = _assignment_value(seed.env["CC"], original_roots)
    copied_cc = _assignment_value(seed.env["CC"], copied_roots)

    script = """set -eu
umask 022
ROOT="$PWD"
export HOME="$ROOT" TMPDIR="$ROOT"
export PATH="{direct_path}"
{direct_exports}
export LC_ALL=C LANG=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
MATERIALIZER="$ROOT/{materializer}"
MANIFEST="$ROOT/{manifest}"
DIRECT_CC="{direct_cc}"
if [ -e /bin/sh ] || [ -L /bin/sh ] || \
   [ -e /bin/bash ] || [ -L /bin/bash ]; then
    echo "source bootstrap tools require Bazel's empty hermetic Linux sandbox" >&2
    exit 1
fi

$DIRECT_CC \
    -Os -ffreestanding -fno-builtin -fno-stack-protector \
    -fno-pie -fno-pic -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -nostdlib -nostartfiles -nodefaultlibs -no-pie \
    -Wl,-e,_start -Wl,--build-id=none \
    "$ROOT/{materializer_source}" -o "$MATERIALIZER"

"$MATERIALIZER" apply "$MANIFEST"
SCRATCH="$ROOT/{scratch}"
"$MATERIALIZER" mkdir "$SCRATCH/early-bin"
"$MATERIALIZER" mkdir "$SCRATCH/prereq-bin"
"$MATERIALIZER" mkdir "$SCRATCH/tmp"
"$MATERIALIZER" mkdir /bin
"$MATERIALIZER" symlink "$ROOT/{shell}" /bin/sh
"$MATERIALIZER" symlink "$ROOT/{shell}" /bin/bash

export HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp"
export PATH="{copied_path}"
{copied_exports}
export LC_ALL=C LANG=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
export CC_FOR_BUILD="{copied_cc}"

# Toybox's build scripts require a one-word compiler command. The public
# compiler-seed contract intentionally permits commands such as `zig cc ...`,
# so expose that command through a temporary sh wrapper.
printf '%s\\n' '#!/bin/sh' 'exec $CC_FOR_BUILD "$@"' > "$SCRATCH/early-bin/cc"
"$MATERIALIZER" chmod 0755 "$SCRATCH/early-bin/cc"
export PATH="$SCRATCH/early-bin:$PATH"

TOYBOX_SOURCE="$SCRATCH/toybox"
cd "$TOYBOX_SOURCE"
/bin/sh scripts/prereq/build.sh
PREREQ="$TOYBOX_SOURCE/toybox-prereq"

# The checked-in prerequisite configuration intentionally has cat rather than
# cp. Use it to copy itself, then install its applet links.
"$PREREQ" cat "$PREREQ" > "$SCRATCH/prereq-bin/toybox"
"$PREREQ" chmod 0755 "$SCRATCH/prereq-bin/toybox"
PREREQ="$SCRATCH/prereq-bin/toybox"
for applet in $("$PREREQ"); do
    "$PREREQ" ln -sf toybox "$SCRATCH/prereq-bin/$applet"
done
"$PREREQ" ln -sf "$ROOT/{shell}" "$SCRATCH/prereq-bin/bash"

# scripts/make.sh copies the unstripped executable into OUTNAME. The checked-in
# prerequisite suite has no cp applet, so provide that one narrow operation
# through the already source-built materializer.
export STAGE2_MATERIALIZER="$MATERIALIZER"
printf '%s\\n' '#!/bin/sh' 'exec "$STAGE2_MATERIALIZER" copy "$1" "$2"' > "$SCRATCH/early-bin/cp"
"$MATERIALIZER" chmod 0755 "$SCRATCH/early-bin/cp"
export PATH="$SCRATCH/early-bin:$SCRATCH/prereq-bin:{copied_path}"

# Build the normal command set plus the pending POSIX tools needed by GNU
# configure scripts. This is deliberately a source build; only the selected
# shell and compiler seeds execute before it.
printf '%s\\n' \\
    'CONFIG_AWK=y' \\
    'CONFIG_DIFF=y' \\
    'CONFIG_EXPR=y' \\
    'CONFIG_TR=y' > "$SCRATCH/bootstrap.config"
export KCONFIG_ALLCONFIG="$SCRATCH/bootstrap.config"
export KCONFIG_CONFIG="$TOYBOX_SOURCE/.config"
export GENDIR="$TOYBOX_SOURCE/generated"
export UNSTRIPPED="$SCRATCH/unstripped"
export OUTNAME="$ROOT/{output}"
export VERSION=0.8.14 NOSTRIP=1 CPUS={jobs}
export CC=cc HOSTCC=cc CFLAGS='-O2 -funsigned-char' LDFLAGS=-static
/bin/bash scripts/genconfig.sh -d
/bin/bash scripts/make.sh
""".format(
        copied_exports = "\n".join(copied_exports),
        copied_path = copied_path,
        copied_cc = copied_cc,
        direct_cc = direct_cc,
        direct_exports = "\n".join(direct_exports),
        direct_path = direct_path,
        jobs = ctx.attr.jobs,
        manifest = manifest.path,
        materializer = materializer.path,
        materializer_source = ctx.file._materializer_source.path,
        output = output.path,
        scratch = scratch,
        shell = shell.executable.path,
    )

    inputs = depset(
        direct = (
            ctx.files.toybox_srcs +
            [ctx.file.toybox_main, ctx.file._materializer_source, manifest] +
            seed.files.to_list() +
            shell.files.to_list()
        ),
    )
    ctx.actions.run(
        executable = shell.executable,
        arguments = shell.args + ["-c", script],
        inputs = inputs,
        outputs = [output, materializer],
        mnemonic = "SourceBootstrapTools",
        progress_message = "Building bootstrap utilities from source %{label}",
    )
    return [DefaultInfo(
        executable = output,
        files = depset([output]),
    )]

source_bootstrap_tools = rule(
    implementation = _source_bootstrap_tools_impl,
    attrs = {
        "compiler_seed": attr.label(
            cfg = "exec",
            mandatory = True,
            providers = [CompilerSeedInfo],
        ),
        "jobs": attr.int(default = 4),
        "shell_seed": attr.label(
            cfg = "exec",
            mandatory = True,
            providers = [ShellSeedInfo],
        ),
        "toybox_main": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "toybox_srcs": attr.label(
            allow_files = True,
            mandatory = True,
        ),
        "_materializer_source": attr.label(
            allow_single_file = True,
            default = Label("//internal:bootstrap/materialize.c"),
        ),
    },
    executable = True,
    doc = "Builds a static Toybox utility suite from source with the selected seeds.",
)
