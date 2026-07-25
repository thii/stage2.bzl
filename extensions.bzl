"""Root-controlled compiler-seed selection for stage2.bzl."""

visibility("public")

_SUPPORTED_ARCHES = ["aarch64", "x86_64"]

def _compiler_seed_config_repo_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """alias(
    name = "aarch64",
    actual = {aarch64},
    visibility = ["//visibility:public"],
)

alias(
    name = "x86_64",
    actual = {x86_64},
    visibility = ["//visibility:public"],
)
""".format(
            aarch64 = repr(str(rctx.attr.aarch64)),
            x86_64 = repr(str(rctx.attr.x86_64)),
        ),
    )

_compiler_seed_config_repo = repository_rule(
    implementation = _compiler_seed_config_repo_impl,
    attrs = {
        "aarch64": attr.label(mandatory = True),
        "x86_64": attr.label(mandatory = True),
    },
)

def _compiler_seeds_impl(module_ctx):
    selected = {
        "aarch64": Label("//internal:default_compiler_seed_aarch64"),
        "x86_64": Label("//internal:default_compiler_seed_x86_64"),
    }
    seen = {}

    for module in module_ctx.modules:
        if not module.is_root:
            continue
        for tag in module.tags.seed:
            if tag.arch not in _SUPPORTED_ARCHES:
                fail(
                    "unsupported compiler seed architecture {!r}; expected one of {}".format(
                        tag.arch,
                        _SUPPORTED_ARCHES,
                    ),
                )
            if tag.arch in seen:
                fail("the root module selects more than one {} compiler seed".format(tag.arch))
            seen[tag.arch] = True
            selected[tag.arch] = tag.target

    _compiler_seed_config_repo(
        name = "stage2_compiler_seeds",
        aarch64 = selected["aarch64"],
        x86_64 = selected["x86_64"],
    )

compiler_seeds = module_extension(
    implementation = _compiler_seeds_impl,
    tag_classes = {
        "seed": tag_class(
            attrs = {
                "arch": attr.string(mandatory = True),
                "target": attr.label(mandatory = True),
            },
            doc = "Selects a stage2_compiler_seed target for one Linux host architecture.",
        ),
    },
    doc = "Selects root-provided compiler seeds while retaining defaults for other architectures.",
)
