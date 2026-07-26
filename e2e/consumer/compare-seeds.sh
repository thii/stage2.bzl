#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export TZ=UTC

: "${DISK_CACHE_ROOT:?}"
: "${REPOSITORY_CACHE:?}"
: "${STAGE2_ARTIFACTS:?}"
: "${STAGE2_OUTPUT_BASE:?}"

readonly BAZEL="$(command -v bazel)"

shutdown_bazel() {
  "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" shutdown >/dev/null 2>&1 || true
}

trap shutdown_bazel EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
  "$DISK_CACHE_ROOT/muslcc" \
  "$DISK_CACHE_ROOT/zig" \
  "$DISK_CACHE_ROOT/toybox" \
  "$STAGE2_ARTIFACTS"

canonicalize_tree() {
  local source="$1"
  local destination="$2"
  # The runner's tools are the comparison oracle, not either bootstrapped
  # userland. Hard-link materialization is not part of a Bazel TreeArtifact.
  /usr/bin/tar \
    --hard-dereference \
    --format=gnu \
    --sort=name \
    --mtime=@0 \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$source" \
    -cf - . |
    /usr/bin/gzip -n >"$destination"
}

build_lineage() {
  local lineage="$1"
  local compiler_seed="$2"
  local shell_seed="$3"
  local disk_cache="$4"
  local artifact_dir="$STAGE2_ARTIFACTS/$lineage"
  mkdir -p "$artifact_dir"
  mkdir -p "$DISK_CACHE_ROOT/$disk_cache"

  local host_arch
  case "$(/usr/bin/uname -m)" in
    aarch64) host_arch="aarch64" ;;
    x86_64) host_arch="x86_64" ;;
    *)
      echo "unsupported host architecture: $(/usr/bin/uname -m)" >&2
      return 1
      ;;
  esac

  local compiler_seed_input
  compiler_seed_input="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
      --ui_event_filters=-info,-warning \
      --noshow_progress \
      --define=compiler_seed="$compiler_seed" \
      --define=shell_seed="$shell_seed" \
      --repository_cache="$REPOSITORY_CACHE" \
      --output=files \
      "config(//:compiler_seed_$host_arch, target)" |
      /usr/bin/sed -n '1p'
  )"
  case "$compiler_seed:$compiler_seed_input" in
    muslcc:*musl_toolchain_linux_*) ;;
    zig:*zig_compiler_seed_*) ;;
    *)
      echo "$compiler_seed resolved to the wrong compiler seed: $compiler_seed_input" >&2
      return 1
      ;;
  esac

  local shell_seed_input
  shell_seed_input="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
      --ui_event_filters=-info,-warning \
      --noshow_progress \
      --define=compiler_seed="$compiler_seed" \
      --define=shell_seed="$shell_seed" \
      --repository_cache="$REPOSITORY_CACHE" \
      --output=files \
      "config(//:shell_seed_$host_arch, target)" |
      /usr/bin/sed -n '1p'
  )"
  case "$shell_seed:$shell_seed_input" in
    busybox:*busybox_linux_*) ;;
    toybox:*toybox_shell_seed_*) ;;
    *)
      echo "$shell_seed resolved to the wrong shell seed: $shell_seed_input" >&2
      return 1
      ;;
  esac

  echo "Building the $lineage bootstrap-seed lineage"
  echo "  compiler: $compiler_seed_input"
  echo "  shell: $shell_seed_input"
  "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" build \
    --define=compiler_seed="$compiler_seed" \
    --define=shell_seed="$shell_seed" \
    --disk_cache="$DISK_CACHE_ROOT/$disk_cache" \
    --jobs=1 \
    --repository_cache="$REPOSITORY_CACHE" \
    //:hello-output \
    @stage2.bzl//trees:cc \
    @stage2.bzl//trees:default_userland

  local execroot
  execroot="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" info \
      --define=compiler_seed="$compiler_seed" \
      --define=shell_seed="$shell_seed" \
      execution_root
  )"

  while IFS='|' read -r name label; do
    local relative
    local source
    relative="$(
      "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
        --ui_event_filters=-info,-warning \
        --noshow_progress \
        --define=compiler_seed="$compiler_seed" \
        --define=shell_seed="$shell_seed" \
        --output=files \
        "config($label, target)"
    )"
    [[ -n "$relative" && "$relative" != *$'\n'* ]]
    source="$execroot/$relative"
    [[ -d "$source" ]]
    canonicalize_tree "$source" "$artifact_dir/$name.tar.gz"
  done <<'TREES'
cc|@stage2.bzl//trees:cc
hello|//:hello
userland|@stage2.bzl//trees:default_userland
TREES

  local hello_output
  hello_output="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
      --ui_event_filters=-info,-warning \
      --noshow_progress \
      --define=compiler_seed="$compiler_seed" \
      --define=shell_seed="$shell_seed" \
      --output=files \
      "config(//:hello-output, target)"
  )"
  [[ -n "$hello_output" && "$hello_output" != *$'\n'* ]]
  cp "$execroot/$hello_output" "$artifact_dir/hello-output"
}

# Keep the absolute execroot identical so build paths cannot distinguish the
# lineages. Expunging between them prevents Bazel's local action cache from
# crossing the boundary; the persistent disk caches are also split by lineage.
build_lineage muslcc-busybox muslcc busybox muslcc
"$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" clean --expunge
build_lineage zig-busybox zig busybox zig
"$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" clean --expunge
build_lineage muslcc-toybox muslcc toybox toybox
shutdown_bazel

comparison_failed=0
compare_to_baseline() {
  local alternate="$1"
  local name

  for name in cc hello userland; do
    local baseline_archive="$STAGE2_ARTIFACTS/muslcc-busybox/$name.tar.gz"
    local alternate_archive="$STAGE2_ARTIFACTS/$alternate/$name.tar.gz"
    sha256sum "$baseline_archive" "$alternate_archive"
    if ! cmp -s "$baseline_archive" "$alternate_archive"; then
      comparison_failed=1
      mkdir -p "$STAGE2_ARTIFACTS/muslcc-busybox-$name"
      mkdir -p "$STAGE2_ARTIFACTS/$alternate-$name"
      tar -xzf "$baseline_archive" -C "$STAGE2_ARTIFACTS/muslcc-busybox-$name"
      tar -xzf "$alternate_archive" -C "$STAGE2_ARTIFACTS/$alternate-$name"
      diff -qr --no-dereference \
        "$STAGE2_ARTIFACTS/muslcc-busybox-$name" \
        "$STAGE2_ARTIFACTS/$alternate-$name" || true
      diff -u \
        <(tar --numeric-owner --full-time -tvzf "$baseline_archive") \
        <(tar --numeric-owner --full-time -tvzf "$alternate_archive") || true
    fi
  done

  local baseline_output="$STAGE2_ARTIFACTS/muslcc-busybox/hello-output"
  local alternate_output="$STAGE2_ARTIFACTS/$alternate/hello-output"
  sha256sum "$baseline_output" "$alternate_output"
  if ! cmp -s "$baseline_output" "$alternate_output"; then
    comparison_failed=1
    diff -u "$baseline_output" "$alternate_output" || true
  fi
}

compare_to_baseline zig-busybox
compare_to_baseline muslcc-toybox

if ((comparison_failed)); then
  echo "The bootstrap seed lineages produced different final outputs" >&2
  exit 1
fi

echo "All three bootstrap seed lineages produced identical canonicalized trees and Hello output"
