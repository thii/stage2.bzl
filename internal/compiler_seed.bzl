"""Compiler-seed description shared by bootstrap rules and consumers."""

visibility("//...")

CompilerSeedInfo = provider(
    doc = "Complete executable compiler seed used by stage-0 and stage-1 actions.",
    fields = {
        "env": "Environment commands such as CC and CXX, with root tokens.",
        "files": "All files needed to execute the seed and link static programs.",
        "path": "PATH entries containing root tokens.",
        "roots": "Token name to execroot-relative seed-root path.",
        "symlinks": "Ephemeral link path to literal target, with root tokens.",
    },
)

_RESERVED_ENV = [
    "CC_FOR_BUILD",
    "CONFIG_SHELL",
    "CXX_FOR_BUILD",
    "HOME",
    "INSTALL",
    "MAKEINFO",
    "MKDIR_P",
    "PATH",
    "ROOT",
    "SCRATCH",
    "SH",
    "SHELL",
    "TMPDIR",
    "TOOLS",
    "UL",
]

def _validate_token(token):
    if not token:
        fail("compiler seed root tokens must not be empty")
    for char in token.elems():
        if char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_":
            fail("compiler seed root token {!r} must contain only A-Z, 0-9, and _".format(token))

def _validate_env_name(name):
    if not name or name[0] in "0123456789":
        fail("compiler seed environment name {!r} is invalid".format(name))
    for char in name.elems():
        if char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_":
            fail("compiler seed environment name {!r} is invalid".format(name))

def _validate_relative_path(path, field):
    if not path or path.startswith("/"):
        fail("{} must be a non-empty relative path, got {!r}".format(field, path))
    if ".." in path.split("/"):
        fail("{} must not contain '..', got {!r}".format(field, path))

def _validate_template_tokens(template, roots, field):
    remainder = template
    for token in roots:
        remainder = remainder.replace("%{" + token + "}", "")
    if "%{" in remainder:
        fail("{} contains an unknown compiler seed root token: {!r}".format(field, template))

def _validate_rooted_path(path, roots, field):
    _validate_template_tokens(path, roots, field)
    for token in roots:
        prefix = "%{" + token + "}"
        if path == prefix:
            return
        if path.startswith(prefix + "/"):
            _validate_relative_path(path[len(prefix) + 1:], field)
            return
    fail("{} must begin with a compiler seed root token, got {!r}".format(field, path))

def _root_from_anchor(anchor, relative_path, token):
    if relative_path == ".":
        return anchor.path
    suffix = "/" + relative_path
    if not anchor.path.endswith(suffix):
        fail(
            "compiler seed root {} uses anchor {}, whose path {!r} does not end in {!r}".format(
                token,
                anchor.owner,
                anchor.path,
                relative_path,
            ),
        )
    return anchor.path[:-len(suffix)]

def _compiler_seed_impl(ctx):
    roots = {}
    anchors = []
    for target, token in ctx.attr.root_anchors.items():
        _validate_token(token)
        if token in roots:
            fail("compiler seed root token {} is defined more than once".format(token))
        if token not in ctx.attr.root_paths:
            fail("compiler seed root {} has no anchor-relative path".format(token))

        files = target.files.to_list()
        if len(files) != 1:
            fail(
                "compiler seed root {} anchor {} must provide exactly one file, got {}".format(
                    token,
                    target.label,
                    len(files),
                ),
            )
        relative_path = ctx.attr.root_paths[token]
        _validate_relative_path(relative_path, "compiler seed root {} anchor path".format(token))
        anchor = files[0]
        roots[token] = _root_from_anchor(anchor, relative_path, token)
        anchors.append(anchor)

    for token in ctx.attr.root_paths:
        if token not in roots:
            fail("compiler seed root path {} has no anchor".format(token))
    if not roots:
        fail("compiler seed must define at least one root")

    for required in ["CC", "CXX"]:
        if required not in ctx.attr.env:
            fail("compiler seed env must define {}".format(required))
    for name, value in ctx.attr.env.items():
        _validate_env_name(name)
        if name in _RESERVED_ENV:
            fail("compiler seed environment name {} is reserved by the sandbox".format(name))
        _validate_template_tokens(value, roots, "compiler seed env {}".format(name))

    for entry in ctx.attr.path:
        _validate_rooted_path(entry, roots, "compiler seed PATH entry")
    for link in ctx.attr.symlinks:
        _validate_rooted_path(link, roots, "compiler seed symlink path")

    files = depset(ctx.files.inputs + anchors)
    return [
        DefaultInfo(files = files),
        CompilerSeedInfo(
            env = dict(ctx.attr.env),
            files = files,
            path = list(ctx.attr.path),
            roots = roots,
            symlinks = dict(ctx.attr.symlinks),
        ),
    ]

_compiler_seed = rule(
    implementation = _compiler_seed_impl,
    attrs = {
        "env": attr.string_dict(mandatory = True),
        "inputs": attr.label_list(allow_files = True, mandatory = True),
        "path": attr.string_list(),
        "root_anchors": attr.label_keyed_string_dict(allow_files = True),
        "root_paths": attr.string_dict(),
        "symlinks": attr.string_dict(),
    },
    doc = "Describes a complete static compiler seed without assuming its layout.",
)

def stage2_compiler_seed(
        name,
        inputs,
        roots,
        env,
        path = [],
        symlinks = {},
        visibility = ["//visibility:public"],
        **kwargs):
    """Declares a compiler seed selectable through the compiler_seeds extension.

    Args:
      name: Target name.
      inputs: Complete file trees needed to compile and statically link C/C++.
      roots: Token -> (anchor label, anchor-relative path). The anchor locates
        the root without baking repository names into commands.
      env: Environment variable -> command/value. CC and CXX are required.
        Root tokens use the `%{TOKEN}` spelling.
      path: PATH entries with root tokens.
      symlinks: Ephemeral link path -> literal target, with root tokens. Links
        are restored after bootstrap utilities exist, so they cannot repair the
        first compiler invocation when the shell seed supplies no utilities.
      visibility: Target visibility; public by default because the generated
        seed-selection repository must reference it.
      **kwargs: Common target attributes such as tags and testonly.
    """
    root_anchors = {}
    root_paths = {}
    for token, root in roots.items():
        if type(root) not in ["list", "tuple"] or len(root) != 2:
            fail("compiler seed root {} must be (anchor label, anchor-relative path)".format(token))
        anchor, relative_path = root
        if anchor in root_anchors:
            fail("compiler seed root anchors must be unique; {} is reused".format(anchor))
        root_anchors[anchor] = token
        root_paths[token] = relative_path

    _compiler_seed(
        name = name,
        env = env,
        inputs = inputs,
        path = path,
        root_anchors = root_anchors,
        root_paths = root_paths,
        symlinks = symlinks,
        visibility = visibility,
        **kwargs
    )
