"""Shell-seed description shared by bootstrap rules and consumers."""

visibility("//...")

ShellSeedInfo = provider(
    doc = "Executable shell seed used by bootstrap actions.",
    fields = {
        "args": "Arguments placed before -c for the top-level action invocation.",
        "executable": "Executable file used to run bootstrap scripts.",
        "files": "All files needed to execute the shell seed.",
        "tools_args": "Arguments that make tools_executable list its applets.",
        "tools_executable": "Optional multicall utility executable supplied by the seed.",
    },
)

def _shell_seed_impl(ctx):
    executable = ctx.executable.executable
    tools_executable = ctx.executable.tools_executable
    if ctx.attr.tools_args and not tools_executable:
        fail("tools_args requires tools_executable")
    files = depset(
        [executable] +
        ([tools_executable] if tools_executable else []) +
        ctx.files.inputs,
    )
    return [
        DefaultInfo(files = files),
        ShellSeedInfo(
            args = list(ctx.attr.args),
            executable = executable,
            files = files,
            tools_args = list(ctx.attr.tools_args),
            tools_executable = tools_executable,
        ),
    ]

_shell_seed = rule(
    implementation = _shell_seed_impl,
    attrs = {
        "args": attr.string_list(),
        "executable": attr.label(
            allow_files = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
        "inputs": attr.label_list(allow_files = True),
        "tools_args": attr.string_list(),
        "tools_executable": attr.label(
            allow_files = True,
            cfg = "exec",
            executable = True,
        ),
    },
    doc = "Describes a shell seed and all files needed to execute it.",
)

def stage2_shell_seed(
        name,
        executable,
        args = [],
        inputs = [],
        tools_executable = None,
        tools_args = [],
        visibility = ["//visibility:public"],
        **kwargs):
    """Declares a shell seed selectable through the shell_seeds extension.

    Args:
      name: Target name.
      executable: Shell executable label.
      args: Arguments placed before `-c` for the top-level action invocation.
        Nested build scripts invoke the executable through a `sh` symlink
        without these arguments.
      inputs: Additional files needed to execute the shell.
      tools_executable: Optional multicall executable that supplies bootstrap
        utilities. If omitted, the utilities are built from source with the
        selected compiler and shell seeds, and the shell must provide Bash
        semantics for that source build.
      tools_args: Arguments that make `tools_executable` list its applets.
      visibility: Target visibility; public by default because the generated
        seed-selection repository must reference it.
      **kwargs: Common target attributes such as tags and testonly.
    """
    _shell_seed(
        name = name,
        executable = executable,
        args = args,
        inputs = inputs,
        tools_args = tools_args,
        tools_executable = tools_executable,
        visibility = visibility,
        **kwargs
    )
