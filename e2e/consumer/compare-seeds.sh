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

mkdir -p "$DISK_CACHE_ROOT/muslcc" "$DISK_CACHE_ROOT/zig" "$STAGE2_ARTIFACTS"

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

build_seed() {
  local seed="$1"
  local artifact_dir="$STAGE2_ARTIFACTS/$seed"
  mkdir -p "$artifact_dir"
  mkdir -p "$DISK_CACHE_ROOT/$seed"

  local host_arch
  case "$(/usr/bin/uname -m)" in
    aarch64) host_arch="aarch64" ;;
    x86_64) host_arch="x86_64" ;;
    *)
      echo "unsupported host architecture: $(/usr/bin/uname -m)" >&2
      return 1
      ;;
  esac

  local first_seed_input
  first_seed_input="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
      --ui_event_filters=-info,-warning \
      --noshow_progress \
      --define=compiler_seed="$seed" \
      --repository_cache="$REPOSITORY_CACHE" \
      --output=files \
      "config(//:compiler_seed_$host_arch, target)" |
      /usr/bin/sed -n '1p'
  )"
  case "$seed:$first_seed_input" in
    muslcc:*musl_toolchain_linux_*) ;;
    zig:*zig_compiler_seed_*) ;;
    *)
      echo "$seed resolved to the wrong compiler seed: $first_seed_input" >&2
      return 1
      ;;
  esac

  echo "Building the $seed compiler-seed lineage from $first_seed_input"
  "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" build \
    --define=compiler_seed="$seed" \
    --disk_cache="$DISK_CACHE_ROOT/$seed" \
    --jobs=1 \
    --repository_cache="$REPOSITORY_CACHE" \
    //:hello-output \
    @stage2.bzl//trees:cc \
    @stage2.bzl//trees:default_userland

  local execroot
  execroot="$(
    "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" info \
      --define=compiler_seed="$seed" \
      execution_root
  )"

  while IFS='|' read -r name label; do
    local relative
    local source
    relative="$(
      "$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" cquery \
        --ui_event_filters=-info,-warning \
        --noshow_progress \
        --define=compiler_seed="$seed" \
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
      --define=compiler_seed="$seed" \
      --output=files \
      "config(//:hello-output, target)"
  )"
  [[ -n "$hello_output" && "$hello_output" != *$'\n'* ]]
  cp "$execroot/$hello_output" "$artifact_dir/hello-output"
}

# Keep the absolute execroot identical so build paths cannot distinguish the
# lineages. Expunging between them prevents Bazel's local action cache from
# crossing the boundary; the persistent disk caches are also split by seed.
build_seed muslcc
"$BAZEL" --output_base="$STAGE2_OUTPUT_BASE" clean --expunge
build_seed zig
shutdown_bazel

comparison_failed=0
for name in cc hello userland; do
  muslcc="$STAGE2_ARTIFACTS/muslcc/$name.tar.gz"
  zig="$STAGE2_ARTIFACTS/zig/$name.tar.gz"
  sha256sum "$muslcc" "$zig"
  if ! cmp -s "$muslcc" "$zig"; then
    comparison_failed=1
    mkdir -p "$STAGE2_ARTIFACTS/muslcc-$name"
    mkdir -p "$STAGE2_ARTIFACTS/zig-$name"
    tar -xzf "$muslcc" -C "$STAGE2_ARTIFACTS/muslcc-$name"
    tar -xzf "$zig" -C "$STAGE2_ARTIFACTS/zig-$name"
    diff -qr --no-dereference \
      "$STAGE2_ARTIFACTS/muslcc-$name" \
      "$STAGE2_ARTIFACTS/zig-$name" || true
    diff -u \
      <(tar --numeric-owner --full-time -tvzf "$muslcc") \
      <(tar --numeric-owner --full-time -tvzf "$zig") || true
  fi
done

sha256sum \
  "$STAGE2_ARTIFACTS/muslcc/hello-output" \
  "$STAGE2_ARTIFACTS/zig/hello-output"
if ! cmp -s \
  "$STAGE2_ARTIFACTS/muslcc/hello-output" \
  "$STAGE2_ARTIFACTS/zig/hello-output"; then
  comparison_failed=1
  diff -u \
    "$STAGE2_ARTIFACTS/muslcc/hello-output" \
    "$STAGE2_ARTIFACTS/zig/hello-output" || true
fi

if ((comparison_failed)); then
  echo "musl.cc and Zig produced different final outputs" >&2
  exit 1
fi

echo "musl.cc and Zig produced identical canonicalized trees and Hello output"
