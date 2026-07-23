"""Rules that run autotools builds inside Bazel's hermetic Linux sandbox.

The sandbox root is empty apart from declared inputs (this project uses no
--sandbox_add_mount_pair), so these rules bring their own userland. Two
modes exist, selected by which attribute a target sets:

  - `userland` (stage 2 and above): a from-source GNU userland tree
    (bash, coreutils, sed, grep, findutils, diffutils, tar, gzip, gawk —
    see //internal:userland-s2). The action executes its bash directly;
    PATH points into the tree. No prebuilt binary is among the action's
    inputs.
  - `busybox` (stage 0/1 and the userland package builds themselves): the
    prebuilt static Alpine busybox, exec'd directly as `sh`, with a
    symlink farm of its applets on PATH. This is the irreducible
    bootstrap shell: building a shell from source needs a shell.

Common machinery for both modes:

  - `/bin/sh` is created inside the ephemeral sandbox root (the root is
    writable; nothing is mounted from the host). Source trees hardcode
    `#!/bin/sh` in helper scripts such as gcc's move-if-change, and
    configure-generated code spawns it too. Actions refuse to run if a
    /bin/sh already exists: that would mean a non-hermetic sandbox and a
    mixed host/hermetic build.
  - The compiler comes either from the static musl.cc seed toolchain
    (`musl_toolchain`/`musl_gcc` attrs — stage-1 targets only) or from a
    previously built stage tree (`path_trees` attr). Every compiler
    spelling pins `-static` so that configure run-tests and generated
    tools work in a root with no dynamic loader.
  - autoconf quirks: MKDIR_P/INSTALL are pinned in the *environment*
    (autoconf 2.69's race-free-mkdir probe would otherwise fall back to
    the shebang-executed install-sh under busybox; the GCC/binutils
    top-level configure does not forward VAR=VALUE arguments to
    sub-configures, but environment variables pass through).

Every action runs from the same absolute path (/execroot/_main inside the
hermetic sandbox), so absolute paths configure bakes into one stage's
outputs (e.g. --with-sysroot) remain valid when a later action runs those
outputs. The `%{OUT}` token in configure_args expands to the absolute
path of the target's own output tree for exactly that purpose.

No genrules anywhere: genrules require the host bash. Every action here
execs its shell directly.
"""

visibility("//...")

def _subst(template, substitutions):
    for key, value in substitutions.items():
        template = template.replace("%{" + key + "}", value)
    return template

_COMMON_HEAD = """set -eu
ROOT="$PWD"
SCRATCH="$ROOT/%{scratch}"
"""

# Bootstrap mode a: prebuilt busybox — applet symlink farm on PATH.
_BUSYBOX_BOOTSTRAP = """BB="$ROOT/%{busybox}"
"$BB" mkdir -p "$SCRATCH/tools" "$SCRATCH/build" "$SCRATCH/tmp"
for a in $("$BB" --list); do "$BB" ln -sf "$BB" "$SCRATCH/tools/$a"; done
export PATH="$SCRATCH/tools:%{path}"
SH="$SCRATCH/tools/sh"
"""

# Bootstrap mode b: from-source GNU userland tree. Exporting PATH needs
# no external programs, so it comes first and everything after uses
# plain command names. An `sh` name is provided next to bash.
_USERLAND_BOOTSTRAP = """UL="$ROOT/%{userland}"
export PATH="$UL/bin:%{path}"
mkdir -p "$SCRATCH/tools" "$SCRATCH/build" "$SCRATCH/tmp"
ln -sf "$UL/bin/bash" "$SCRATCH/tools/sh"
export PATH="$SCRATCH/tools:$PATH"
SH="$SCRATCH/tools/sh"
"""

_COMMON_TAIL = """if [ -e /bin/sh ] || [ -L /bin/sh ]; then
    echo "ERROR: stage2.bzl requires Bazel's empty hermetic Linux sandbox," >&2
    echo "but /bin/sh already exists in this action's sandbox root." >&2
    echo "Refusing a mixed host/hermetic build." >&2
    echo >&2
    echo "Add this exact block to the consuming workspace's .bazelrc:" >&2
    echo >&2
    echo "common --enable_platform_specific_config" >&2
    echo "build:linux --experimental_use_hermetic_linux_sandbox" >&2
    echo "build:linux --spawn_strategy=linux-sandbox" >&2
    echo "build:linux --sandbox_default_allow_network=false" >&2
    exit 1
fi
mkdir -p /bin
ln -sf "$SH" /bin/sh
export SHELL="$SH" CONFIG_SHELL="$SH"
export HOME="$SCRATCH" TMPDIR="$SCRATCH/tmp"
export MKDIR_P="%{bindir}/mkdir -p" ac_cv_path_mkdir="%{bindir}/mkdir"
export INSTALL="%{bindir}/install -c" MAKEINFO=true
export CC_FOR_BUILD="%{build_cc}" CXX_FOR_BUILD="%{build_cxx}"
"""

# The musl.cc seed toolchain resolves headers/libraries through a
# `usr -> .` self-symlink at its root. That symlink cannot be a declared
# input (it would make glob(["**"]) recurse forever), so recreate it
# inside the ephemeral sandbox copy of the repository.
_SEED_USR_LINK = """if [ ! -e "$ROOT/%{musl_root}/usr" ]; then
    ln -sf . "$ROOT/%{musl_root}/usr" || true
fi
"""

def _run(cmd, log, tail = "80"):
    return _subst(
        """%{cmd} > "$SCRATCH/%{log}" 2>&1 || (
    echo "=== %{log} failed; last %{tail} lines: ==="
    tail -n %{tail} "$SCRATCH/%{log}"
    exit 1
)
""",
        {"cmd": cmd, "log": log, "tail": tail},
    )

def _common_attrs():
    # cfg = "exec": these are host prerequisites, and //internal's aliases
    # select() on the CPU of the configuration they are analyzed in. The
    # exec configuration's platform is the host even when --platforms
    # points somewhere exotic.
    #
    # userland / musl_toolchain / musl_gcc have no defaults: stage-2+
    # targets must pass a from-source userland explicitly, and only
    # stage-1 targets may reference the prebuilt compiler seed. The
    # busybox default covers the bootstrap tier.
    return {
        "userland": attr.label(
            allow_single_file = True,
            cfg = "exec",
            doc = "From-source userland tree; replaces busybox as shell and PATH.",
        ),
        "busybox": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = Label("//internal:busybox"),
        ),
        "musl_toolchain": attr.label(
            cfg = "exec",
        ),
        "musl_gcc": attr.label(
            allow_single_file = True,
            cfg = "exec",
        ),
        "build_cc": attr.string(default = "gcc -static"),
        "build_cxx": attr.string(default = "g++ -static"),
        # When set (to the host toolchain's target triplet), each entry in
        # path_trees also contributes <tree>/<tool_subdir>/bin to PATH.
        # That directory holds the plain-named binutils tools (ar, as,
        # ld, ranlib, ...): the GCC/binutils top-level configure resolves
        # plain `ar` when build==host and exports it to sub-configures
        # that are cross, so plain names must resolve to real tools.
        "tool_subdir": attr.string(default = ""),
    }

def _preamble(ctx, scratch, extra_path_dirs):
    path_dirs = list(extra_path_dirs)
    for tree in ctx.files.path_trees:
        path_dirs.append(tree.path + "/bin")
        if ctx.attr.tool_subdir:
            path_dirs.append(tree.path + "/" + ctx.attr.tool_subdir + "/bin")
    musl_root = None
    if ctx.file.musl_gcc:
        musl_bin = ctx.file.musl_gcc.dirname
        path_dirs.append(musl_bin)
        musl_root = musl_bin.rsplit("/", 1)[0]
    path = ":".join(['"$ROOT"/' + d for d in path_dirs])

    text = _subst(_COMMON_HEAD, {"scratch": scratch})
    if ctx.file.userland:
        text += _subst(_USERLAND_BOOTSTRAP, {
            "userland": ctx.file.userland.path,
            "path": path,
        })
        bindir = '"$UL"/bin'
    else:
        text += _subst(_BUSYBOX_BOOTSTRAP, {
            "busybox": ctx.file.busybox.path,
            "path": path,
        })
        bindir = '"$SCRATCH"/tools'
    text += _subst(_COMMON_TAIL, {
        "bindir": bindir,
        "build_cc": ctx.attr.build_cc,
        "build_cxx": ctx.attr.build_cxx,
    })
    if musl_root:
        text += _subst(_SEED_USR_LINK, {"musl_root": musl_root})
    return text

def _common_inputs(ctx):
    # The shell is either the from-source userland tree or the prebuilt
    # busybox — never both, so userland-mode actions have no prebuilt
    # binary among their inputs.
    inputs = [ctx.file.userland] if ctx.file.userland else [ctx.file.busybox]
    if ctx.attr.musl_toolchain:
        inputs += ctx.attr.musl_toolchain.files.to_list()
    return inputs

def _run_shell(ctx, script, inputs, outputs, mnemonic, progress_message):
    if ctx.file.userland:
        ctx.actions.run(
            executable = ctx.file.userland.path + "/bin/bash",
            arguments = ["-c", script],
            inputs = inputs,
            outputs = outputs,
            mnemonic = mnemonic,
            progress_message = progress_message,
        )
    else:
        ctx.actions.run(
            executable = ctx.file.busybox,
            arguments = ["sh", "-c", script],
            inputs = inputs,
            outputs = outputs,
            mnemonic = mnemonic,
            progress_message = progress_message,
        )

def _expand_out(arg, out):
    # %{OUT} -> absolute path of this target's output tree at action time.
    # Spliced as '"$ROOT"/path' inside the single-quoted argument, keeping
    # the argument one shell word.
    return arg.replace("%{OUT}", "'\"$ROOT\"'/" + out.path + "'")

def _make_bootstrap_impl(ctx):
    if ctx.attr.out_tree:
        out = ctx.actions.declare_directory(ctx.label.name)
    else:
        out = ctx.actions.declare_file(ctx.label.name)
    script = _preamble(ctx, out.path + ".scratch", [])
    script += 'cd "$SCRATCH/build"\n'
    script += _run(
        '"$CONFIG_SHELL" "$ROOT/{}" --disable-nls --disable-dependency-tracking "CC=$CC_FOR_BUILD"'.format(ctx.file.configure.path),
        "configure.log",
    )

    # build.sh compiles make without needing an existing make.
    script += _run('"$CONFIG_SHELL" ./build.sh', "build.log")
    if ctx.attr.out_tree:
        script += 'mkdir -p "$ROOT/{}/bin"\n'.format(out.path)
        script += 'cp make "$ROOT/{}/bin/make"\n'.format(out.path)
    else:
        script += 'cp make "$ROOT/{}"\n'.format(out.path)
    _run_shell(
        ctx,
        script,
        inputs = depset(ctx.files.srcs + ctx.files.path_trees + _common_inputs(ctx)),
        outputs = [out],
        mnemonic = "BootstrapGnuMake",
        progress_message = "Bootstrapping GNU make (hermetic sandbox) %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

make_bootstrap = rule(
    implementation = _make_bootstrap_impl,
    attrs = _common_attrs() | {
        "srcs": attr.label(mandatory = True),
        "configure": attr.label(mandatory = True, allow_single_file = True),
        "out_tree": attr.bool(
            doc = "Emit a bin/make install tree instead of a single bootstrap executable.",
        ),
        "path_trees": attr.label_list(allow_files = True),
    },
    doc = "Bootstraps GNU make from source using only a shell and a C compiler.",
)

def _autotools_build_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)

    script = _preamble(
        ctx,
        out.path + ".scratch",
        [out.path + "/bin"],
    )

    # Bootstrap tiers inject make independently; stage-2 userlands carry
    # GNU make in their bin/ tree and leave this attribute unset.
    if ctx.file.make:
        script += 'ln -sf "$ROOT/{}" "$SCRATCH/tools/make"\n'.format(ctx.file.make.path)

    # Seed the install prefix with previously built trees (e.g. binutils
    # before gcc) so the result is one merged prefix, exactly as if both
    # had been installed into it in sequence.
    for base in ctx.files.install_base:
        script += 'cp -a "$ROOT/{}/." "$ROOT/{}/"\n'.format(base.path, out.path)

    quoted_args = " ".join([
        "'" + _expand_out(a, out) if "%{OUT}" in a else "'" + a + "'"
        for a in ctx.attr.configure_args
    ])
    prefix = out.path
    if ctx.attr.prefix_subdir:
        prefix += "/" + ctx.attr.prefix_subdir
    script += 'cd "$SCRATCH/build"\n'
    script += _run(
        '"$CONFIG_SHELL" "$ROOT/{}" {} --prefix="$ROOT/{}"'.format(
            ctx.file.configure.path,
            quoted_args,
            prefix,
        ),
        "configure.log",
    )

    # MAKEINFO=true must be on the make command line (not just in the
    # environment): release tarballs can carry .texi files newer than the
    # shipped .info docs, and e.g. libgloss then invokes $(MAKEINFO).
    make_targets = " " + ctx.attr.make_targets if ctx.attr.make_targets else ""
    install_targets = ctx.attr.install_targets or "install"
    script += _run("make -j {} MAKEINFO=true{}".format(ctx.attr.jobs, make_targets), "make.log", tail = "100")
    script += _run("make {} MAKEINFO=true".format(install_targets), "install.log")

    _run_shell(
        ctx,
        script,
        inputs = depset(
            ctx.files.srcs + ctx.files.install_base + ctx.files.path_trees +
            [ctx.file.configure] +
            ([ctx.file.make] if ctx.file.make else []) + _common_inputs(ctx),
        ),
        outputs = [out],
        mnemonic = "AutotoolsBuild",
        progress_message = "configure && make && make install (hermetic sandbox) %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

autotools_build = rule(
    implementation = _autotools_build_impl,
    attrs = _common_attrs() | {
        "srcs": attr.label(mandatory = True, doc = "Filegroup of the whole source tree."),
        "configure": attr.label(mandatory = True, allow_single_file = True),
        "configure_args": attr.string_list(
            doc = "Arguments for configure; %{OUT} expands to the absolute output tree path.",
        ),
        "make": attr.label(
            allow_single_file = True,
            cfg = "exec",
            doc = "Bootstrap-tier make binary; stage-2 builds use make from userland.",
        ),
        "install_base": attr.label_list(
            allow_files = True,
            doc = "Install trees copied into the prefix before building.",
        ),
        "path_trees": attr.label_list(
            allow_files = True,
            doc = "Install trees whose bin/ directories join PATH (e.g. a stage-1 compiler).",
        ),
        "jobs": attr.int(default = 4, doc = "make -j value inside the action."),
        "prefix_subdir": attr.string(
            doc = "Install under <out>/<prefix_subdir> instead of <out> (e.g. a target sysroot).",
        ),
        "make_targets": attr.string(
            doc = "Targets for the build step instead of the default all (e.g. 'all-gcc').",
        ),
        "install_targets": attr.string(
            doc = "Targets for the install step instead of 'install' (e.g. 'install-gcc').",
        ),
    },
    doc = "Runs configure/make/make-install of an autotools tree in the hermetic sandbox.",
)

def _tree_merge_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    script = _preamble(ctx, out.path + ".scratch", [])
    for tree in ctx.files.trees:
        script += 'cp -a "$ROOT/{}/." "$ROOT/{}/"\n'.format(tree.path, out.path)
    _run_shell(
        ctx,
        script,
        inputs = depset(ctx.files.trees + _common_inputs(ctx)),
        outputs = [out],
        mnemonic = "TreeMerge",
        progress_message = "Merging install trees %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

tree_merge = rule(
    implementation = _tree_merge_impl,
    attrs = _common_attrs() | {
        "trees": attr.label_list(mandatory = True, allow_files = True),
        "path_trees": attr.label_list(allow_files = True),
    },
    doc = "Merges install trees into one prefix (later trees win on conflicts).",
)

def _hermetic_run_impl(ctx):
    if ctx.attr.out_tree:
        out = ctx.actions.declare_directory(ctx.label.name)
    else:
        out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name)

    script = _preamble(ctx, out.path + ".scratch", [])
    if ctx.file.make:
        script += 'ln -sf "$ROOT/{}" "$SCRATCH/tools/make"\n'.format(ctx.file.make.path)

    substitutions = {
        "OUT": '"$ROOT"/' + out.path,
        "JOBS": str(ctx.attr.jobs),
    }
    token_input_files = []
    for label, token in ctx.attr.input_tokens.items():
        found = label.files.to_list()
        if len(found) != 1:
            fail("hermetic_run.input_tokens: {} must resolve to exactly one file/tree, got {}".format(
                label.label,
                len(found),
            ))
        token_input_files.append(found[0])
        substitutions[token] = '"$ROOT"/' + found[0].path

    script += 'cd "$SCRATCH/build"\n'
    script += _subst(ctx.attr.script, substitutions)

    _run_shell(
        ctx,
        script,
        inputs = depset(
            ctx.files.extra_inputs + ctx.files.path_trees + token_input_files +
            ([ctx.file.make] if ctx.file.make else []) + _common_inputs(ctx),
        ),
        outputs = [out],
        mnemonic = "HermeticRun",
        progress_message = "Running hermetic script (empty sandbox) %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

hermetic_run = rule(
    implementation = _hermetic_run_impl,
    attrs = _common_attrs() | {
        "script": attr.string(
            mandatory = True,
            doc = "Shell body run from $SCRATCH/build after the preamble. " +
                  "%{OUT} expands to the output path, %{JOBS} to the jobs " +
                  "count, and each `input_tokens` token to its input's path (all " +
                  "absolute via $ROOT).",
        ),
        "input_tokens": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Internal label -> token mapping populated by stage2_run.",
        ),
        "extra_inputs": attr.label_list(
            allow_files = True,
            doc = "Additional declared inputs that receive no token substitution.",
        ),
        "out": attr.string(doc = "Output file name (default: target name)."),
        "out_tree": attr.bool(doc = "Declare the output as a directory tree."),
        "make": attr.label(allow_single_file = True, cfg = "exec"),
        "path_trees": attr.label_list(allow_files = True),
        "jobs": attr.int(default = 4),
    },
    doc = "Runs an arbitrary script in the hermetic sandbox with the stage userland.",
)

def _dist_tarball_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name + ".tar.gz")
    tree = ctx.file.tree
    script = _preamble(ctx, out.path + ".scratch", [])

    # Normalize timestamps on a scratch copy (the input tree is hardlinked
    # into the sandbox and must not be modified in place) and archive with
    # a stable entry order, so the tarball is reproducible.
    script += 'mkdir -p "$SCRATCH/build/tree"\n'
    script += 'cp -a "$ROOT/{}/." "$SCRATCH/build/tree/"\n'.format(tree.path)
    script += 'find "$SCRATCH/build/tree" -exec touch -h -d @0 (BRACES) +\n'.replace("(BRACES)", "{}")
    script += 'tar --sort=name -C "$SCRATCH/build/tree" -czf "$ROOT/{}" .\n'.format(out.path)
    _run_shell(
        ctx,
        script,
        inputs = depset([tree] + _common_inputs(ctx)),
        outputs = [out],
        mnemonic = "DistTarball",
        progress_message = "Packaging %{output}",
    )
    return [DefaultInfo(files = depset([out]))]

dist_tarball = rule(
    implementation = _dist_tarball_impl,
    attrs = _common_attrs() | {
        "tree": attr.label(mandatory = True, allow_single_file = True),
        "out": attr.string(),
        "path_trees": attr.label_list(allow_files = True),
    },
    doc = "Packages an install tree into a .tar.gz.",
)
