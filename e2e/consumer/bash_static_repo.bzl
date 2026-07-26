"""Fetches the executable payload from Debian's bash-static package."""

visibility("public")

def _bash_static_repo_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
        type = "deb",
    )
    rctx.extract("data.tar.xz")
    rctx.file(
        "BUILD.bazel",
        """exports_files(
    ["usr/bin/bash-static"],
    visibility = ["//visibility:public"],
)
""",
    )

bash_static_repo = repository_rule(
    implementation = _bash_static_repo_impl,
    attrs = {
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(mandatory = True),
    },
)
