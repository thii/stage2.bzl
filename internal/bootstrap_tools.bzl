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

def _seed_exports(seed, roots, cache_root):
    exports = []
    for name in sorted(seed.env):
        if name in ["CC", "CXX"]:
            continue
        if name == "ZIG_GLOBAL_CACHE_DIR":
            value = cache_root + "/zig-global-cache"
        elif name == "ZIG_LOCAL_CACHE_DIR":
            value = cache_root + "/zig-local-cache"
        else:
            value = _assignment_value(seed.env[name], roots)
        exports.append("export {}=\"{}\"".format(name, value))
    return exports

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
    scratch = output.path + ".scratch"
    roots = dict(seed.roots)

    direct_exports = _seed_exports(seed, roots, "$ROOT/" + output.path + ".direct")
    build_exports = _seed_exports(seed, roots, "$SCRATCH")
    seed_path = _path_value(seed.path, roots)
    seed_cc = _assignment_value(seed.env["CC"], roots)
    tools_path = "$SCRATCH/prereq-bin"
    if seed_path:
        tools_path += ":" + seed_path

    script = """set -eu
umask 022
ROOT="$PWD"
export HOME="$ROOT" TMPDIR="$ROOT"
export PATH="{seed_path}"
{direct_exports}
export LC_ALL=C LANG=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
DIRECT_CC="{seed_cc}"
OUTPUT="$ROOT/{output}"
TOYBOX_INPUT="$ROOT/{toybox_source}"
if [ -e /bin/sh ] || [ -L /bin/sh ] || \
   [ -e /bin/bash ] || [ -L /bin/bash ]; then
    echo "source bootstrap tools require Bazel's empty hermetic Linux sandbox" >&2
    exit 1
fi

# Use Toybox's checked-in prerequisite build verbatim. Its output name is
# relative to the read-only source directory, so the temporary cc function
# redirects only that final argument to the declared output.
cc() {{
    local args=("$@")
    local last=$((${{#args[@]}} - 1))
    if [ "${{args[$last]}}" != toybox-prereq ]; then
        echo "unexpected Toybox prerequisite compiler invocation" >&2
        exit 1
    fi
    args[$last]="$OUTPUT"
    $DIRECT_CC "${{args[@]}}"
}}
cd "$TOYBOX_INPUT"
. scripts/prereq/build.sh
unset -f cc

SCRATCH="$ROOT/{scratch}"
"$OUTPUT" mkdir -p "$SCRATCH/prereq-bin" "$SCRATCH/tmp" "$SCRATCH/toybox"
"$OUTPUT" mkdir -p /bin
"$OUTPUT" ln -s "$ROOT/{shell}" /bin/sh
"$OUTPUT" ln -s "$ROOT/{shell}" /bin/bash

# Preserve the prerequisite multiplexer before the final build replaces
# OUTPUT, then install its applet links.
"$OUTPUT" cat "$OUTPUT" > "$SCRATCH/prereq-bin/toybox"
"$OUTPUT" chmod 0755 "$SCRATCH/prereq-bin/toybox"
PREREQ="$SCRATCH/prereq-bin/toybox"
for applet in $("$PREREQ"); do
    "$PREREQ" ln -sf toybox "$SCRATCH/prereq-bin/$applet"
done
"$PREREQ" ln -sf "$ROOT/{shell}" "$SCRATCH/prereq-bin/bash"

# Keep source inputs read-only. A shallow symlink view makes only Toybox's
# generated files and working state writable.
for entry in Config.in configure main.c toys.h lib scripts toys; do
    "$PREREQ" ln -s "$TOYBOX_INPUT/$entry" "$SCRATCH/toybox/$entry"
done

export HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp"
export PATH="{tools_path}"
{build_exports}
export LC_ALL=C LANG=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
export CC_FOR_BUILD="{seed_cc}"

# Toybox's build scripts require a one-word compiler command. The public
# compiler-seed contract intentionally permits commands such as `zig cc ...`,
# so expose that command through a temporary sh wrapper.
printf '%s\\n' '#!/bin/sh' 'exec $CC_FOR_BUILD "$@"' > "$SCRATCH/prereq-bin/cc"
"$PREREQ" chmod 0755 "$SCRATCH/prereq-bin/cc"

# scripts/make.sh copies the unstripped executable into OUTNAME, but the
# prerequisite configuration has cat rather than cp. This wrapper supplies
# the one two-file copy operation the script needs.
printf '%s\\n' '#!/bin/sh' 'cat "$1" > "$2"' > "$SCRATCH/prereq-bin/cp"
"$PREREQ" chmod 0755 "$SCRATCH/prereq-bin/cp"

# Build the normal command set plus the pending POSIX tools needed by GNU
# configure scripts. This is deliberately a source build; only the selected
# shell and compiler seeds execute before it.
printf '%s\\n' \
    'CONFIG_AWK=y' \
    'CONFIG_DIFF=y' \
    'CONFIG_EXPR=y' \
    'CONFIG_TR=y' > "$SCRATCH/bootstrap.config"
export KCONFIG_ALLCONFIG="$SCRATCH/bootstrap.config"
export KCONFIG_CONFIG="$SCRATCH/toybox/.config"
export GENDIR="$SCRATCH/toybox/generated"
export UNSTRIPPED="$SCRATCH/unstripped"
export OUTNAME="$OUTPUT"
export VERSION=0.8.14 NOSTRIP=1 CPUS={jobs}
export CC=cc HOSTCC=cc CFLAGS='-O2 -funsigned-char' LDFLAGS=-static
cd "$SCRATCH/toybox"
/bin/bash scripts/genconfig.sh -d
/bin/bash scripts/make.sh
""".format(
        build_exports = "\n".join(build_exports),
        direct_exports = "\n".join(direct_exports),
        jobs = ctx.attr.jobs,
        output = output.path,
        scratch = scratch,
        seed_cc = seed_cc,
        seed_path = seed_path,
        shell = shell.executable.path,
        tools_path = tools_path,
        toybox_source = _root_from_main(ctx.file.toybox_main),
    )

    inputs = depset(
        direct = (
            ctx.files.toybox_srcs +
            [ctx.file.toybox_main] +
            seed.files.to_list() +
            shell.files.to_list()
        ),
    )
    ctx.actions.run(
        executable = shell.executable,
        arguments = shell.args + ["-c", script],
        inputs = inputs,
        outputs = [output],
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
    },
    executable = True,
    doc = "Builds a static Toybox utility suite from source with the selected seeds.",
)
