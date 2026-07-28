"""Rules that run autotools builds inside Bazel's hermetic Linux sandbox.

The sandbox root is empty apart from declared inputs (this project uses no
--sandbox_add_mount_pair), so these rules bring their own userland. Two
modes exist, selected by which attribute a target sets:

  - `userland` (stage 2 and above): a from-source GNU userland tree
    (bash, coreutils, sed, grep, findutils, diffutils, tar, gzip, gawk —
    see //internal:userland-s2-final). The action executes its bash directly;
    PATH points into the tree. No prebuilt binary is among the action's
    inputs.
  - bootstrap (stage 0/1 and the first userland package builds): a
    selectable prebuilt shell seed runs the action. A seed may supply its own
    multicall utility suite; otherwise the selected compiler and shell build
    Toybox from source first. Alpine BusyBox supplies both roles by default.
    Building a shell from source still needs a shell.

Common machinery for both modes:

  - `/bin/sh` is created inside the ephemeral sandbox root (the root is
    writable; nothing is mounted from the host). Source trees hardcode
    `#!/bin/sh` in helper scripts such as gcc's move-if-change, and
    configure-generated code spawns it too. Actions refuse to run if a
    /bin/sh already exists: that would mean a non-hermetic sandbox and a
    mixed host/hermetic build.
  - The compiler comes either from the selected static compiler seed
    (described by `compiler_seed` for stage-0/1 targets only) or from a
    previously built stage tree (`path_trees` attr). Seed descriptions
    may provide another compiler, but must still link static configure
    tests and generated tools for a root with no dynamic loader.
  - autoconf quirks: MKDIR_P/INSTALL are pinned in the *environment*
    (autoconf 2.69's race-free-mkdir probe would otherwise fall back to
    the shebang-executed install-sh under the bootstrap tools; the GCC/binutils
    top-level configure does not forward VAR=VALUE arguments to
    sub-configures, but environment variables pass through).
  - Locale, timezone, source epoch, archive dates, and umask are fixed so
    they cannot leak host or invocation state into build outputs.

Every action runs from the same absolute path (/execroot/_main inside the
hermetic sandbox), so absolute paths configure bakes into one stage's
outputs (e.g. --with-sysroot) remain valid when a later action runs those
outputs. The `%{OUT}` token in configure_args expands to the absolute
path of the target's own output tree for exactly that purpose.

No genrules anywhere: genrules require the host bash. Every action here
execs its shell directly.
"""

load(":compiler_seed.bzl", "CompilerSeedInfo")
load(":shell_seed.bzl", "ShellSeedInfo")

visibility("//...")

def _subst(template, substitutions):
    for key, value in substitutions.items():
        template = template.replace("%{" + key + "}", value)
    return template

_COMMON_HEAD = """set -eu
ROOT="$PWD"
SCRATCH="$ROOT/%{scratch}"
"""

# Overlay copies must unlink an existing destination first. In Bazel's
# hermetic Linux sandbox, following a destination symlink can write through a
# hardlinked input and corrupt it. This long option is shared by GNU coreutils,
# BusyBox, and Toybox.
_COPY_TREE_FLAGS = "-a --remove-destination"

# Bootstrap mode a: selected multicall utility symlink farm on PATH. The
# preamble supplies its `sh` link explicitly from the selected shell.
_TOOLS_BOOTSTRAP = """TOOLS="$ROOT/%{tools}"
"$TOOLS" mkdir -p "$SCRATCH/tools" "$SCRATCH/build" "$SCRATCH/tmp"
for a in $("$TOOLS" %{list_args}); do "$TOOLS" ln -sf "$TOOLS" "$SCRATCH/tools/$a"; done
export PATH="%{path}$SCRATCH/tools"
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
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
umask 022
export MKDIR_P="%{bindir}/mkdir -p" ac_cv_path_mkdir="%{bindir}/mkdir"
export INSTALL="%{bindir}/install -c" MAKEINFO=true
export CC_FOR_BUILD="%{build_cc}" CXX_FOR_BUILD="%{build_cxx}"
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
    # userland / compiler_seed have no defaults: stage-2+ targets must
    # pass a from-source userland explicitly, and only stage-0/1 targets
    # may reference a prebuilt compiler seed. bootstrap_shell selects the
    # shell used by the bootstrap tier; a shell without its own utilities uses
    # source_bootstrap_tools, built from the selected compiler and shell.
    return {
        "userland": attr.label(
            allow_single_file = True,
            cfg = "exec",
            doc = "From-source userland tree; replaces bootstrap seeds and PATH.",
        ),
        "bootstrap_shell": attr.label(
            cfg = "exec",
            default = Label("//internal:bootstrap_shell"),
            providers = [ShellSeedInfo],
            doc = "Selected prebuilt shell for bootstrap-tier actions.",
        ),
        "source_bootstrap_tools": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = Label("//internal:source-bootstrap-tools"),
            doc = "Utilities built from source when the selected shell supplies none.",
        ),
        "compiler_seed": attr.label(
            cfg = "exec",
            providers = [CompilerSeedInfo],
            doc = "Complete static compiler seed for stage-0/1 actions.",
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

def _expand_seed_template(template, roots):
    result = template
    for token, root in roots.items():
        result = result.replace("%{" + token + "}", root)
    if "%{" in result:
        fail("unknown compiler-seed root token in {!r}".format(template))
    return result

def _seed_shell_value(template, roots):
    # Values are assigned inside shell double quotes. Escape user-provided
    # shell metacharacters first, then inject the one expansion we intend:
    # $ROOT followed by an execroot-relative declared-input path.
    escaped = template.replace("\\", "\\\\")
    escaped = escaped.replace("\"", "\\\"")
    escaped = escaped.replace("`", "\\`")
    escaped = escaped.replace("$", "\\$")
    shell_roots = {
        token: "$ROOT/" + root
        for token, root in roots.items()
    }
    return _expand_seed_template(escaped, shell_roots)

def _shell_single_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

def _preamble(ctx, scratch, extra_path_dirs):
    path_dirs = list(extra_path_dirs)
    for tree in ctx.files.path_trees:
        path_dirs.append(tree.path + "/bin")
        if ctx.attr.tool_subdir:
            path_dirs.append(tree.path + "/" + ctx.attr.tool_subdir + "/bin")

    seed = ctx.attr.compiler_seed[CompilerSeedInfo] if ctx.attr.compiler_seed else None
    if seed and ctx.file.userland:
        fail("compiler_seed is only valid in the stage-0/1 bootstrap")
    seed_roots = {}
    if seed:
        # Compiler commands use stable scratch-local copies, rather than
        # repository-dependent input paths that configure could record. The
        # copies also let a seed safely request synthetic links.
        seed_roots = {
            token: scratch + "/compiler-seed/" + token
            for token in seed.roots
        }
        for entry in seed.path:
            path_dirs.append(_expand_seed_template(entry, seed_roots))
    path = ":".join(['"$ROOT"/' + d for d in path_dirs])

    text = _subst(_COMMON_HEAD, {"scratch": scratch})
    if ctx.file.userland:
        text += _subst(_USERLAND_BOOTSTRAP, {
            "userland": ctx.file.userland.path,
            "path": path,
        })
        bindir = '"$UL"/bin'
    else:
        shell = ctx.attr.bootstrap_shell[ShellSeedInfo]
        tools = shell.tools_executable or ctx.file.source_bootstrap_tools
        text += _subst(_TOOLS_BOOTSTRAP, {
            "list_args": " ".join([_shell_single_quote(arg) for arg in shell.tools_args]),
            "path": path + ":" if path else "",
            "tools": tools.path,
        })
        text += '"$TOOLS" ln -sf "$ROOT"/{} "$SCRATCH/tools/sh"\n'.format(
            _shell_single_quote(shell.executable.path),
        )
        bindir = '"$SCRATCH"/tools'

    build_cc = ctx.attr.build_cc
    build_cxx = ctx.attr.build_cxx
    if seed:
        build_cc = _seed_shell_value(seed.env["CC"], seed_roots)
        build_cxx = _seed_shell_value(seed.env["CXX"], seed_roots)
    text += _subst(_COMMON_TAIL, {
        "bindir": bindir,
        "build_cc": build_cc,
        "build_cxx": build_cxx,
    })

    if seed:
        text += 'mkdir -p "$SCRATCH/compiler-seed"\n'
        for token in sorted(seed.roots):
            text += """"$TOOLS" mkdir -p "$SCRATCH/compiler-seed"/{token}
"$TOOLS" cp {copy_flags} "$ROOT"/{root}/. "$SCRATCH/compiler-seed"/{token}/
""".format(
                copy_flags = _COPY_TREE_FLAGS,
                root = _shell_single_quote(seed.roots[token]),
                token = _shell_single_quote(token),
            )

        for name in sorted(seed.env):
            if name in ["CC", "CXX"]:
                continue
            text += "export {}=\"{}\"\n".format(
                name,
                _seed_shell_value(seed.env[name], seed_roots),
            )
        text += 'export CC="$CC_FOR_BUILD" CXX="$CXX_FOR_BUILD"\n'

        # Some archive layouts omit cyclic links that Bazel cannot represent
        # as declared inputs. Recreate only links explicitly requested by the
        # selected seed, inside its ephemeral scratch copy.
        for link in sorted(seed.symlinks):
            target = seed.symlinks[link]
            link_path = _expand_seed_template(link, seed_roots)
            link_arg = '"$ROOT"/' + _shell_single_quote(link_path)
            text += """if [ ! -e {link} ] && [ ! -L {link} ]; then
    "$TOOLS" ln -sf {target} {link}
fi
""".format(
                link = link_arg,
                target = _shell_single_quote(target),
            )
    return text

def _common_inputs(ctx):
    # A source-built userland and the bootstrap inputs are mutually exclusive,
    # so userland-mode actions receive neither seed nor bootstrap utilities.
    if ctx.file.userland:
        inputs = [ctx.file.userland]
    else:
        shell = ctx.attr.bootstrap_shell[ShellSeedInfo]
        inputs = shell.files.to_list()
        if not shell.tools_executable:
            inputs.append(ctx.file.source_bootstrap_tools)
    if ctx.attr.compiler_seed:
        inputs += ctx.attr.compiler_seed[CompilerSeedInfo].files.to_list()
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
        shell = ctx.attr.bootstrap_shell[ShellSeedInfo]
        ctx.actions.run(
            executable = shell.executable,
            arguments = shell.args + ["-c", script],
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
        progress_message = "Bootstrapping GNU make %{label}",
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
        script += 'cp {} "$ROOT/{}/." "$ROOT/{}/"\n'.format(
            _COPY_TREE_FLAGS,
            base.path,
            out.path,
        )

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
    if ctx.attr.prune_empty_dirs:
        script += 'find "$ROOT/{}" -depth -mindepth 1 -type d -empty -delete\n'.format(out.path)

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
        progress_message = "configure && make && make install %{label}",
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
        "prune_empty_dirs": attr.bool(
            doc = "Remove empty directories from the installed output tree.",
        ),
    },
    doc = "Runs configure/make/make-install of an autotools tree in the hermetic sandbox.",
)

def _tree_merge_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    script = _preamble(ctx, out.path + ".scratch", [])
    for tree in ctx.files.trees:
        script += 'cp {} "$ROOT/{}/." "$ROOT/{}/"\n'.format(
            _COPY_TREE_FLAGS,
            tree.path,
            out.path,
        )
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
    script += 'cp {} "$ROOT/{}/." "$SCRATCH/build/tree/"\n'.format(
        _COPY_TREE_FLAGS,
        tree.path,
    )
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
