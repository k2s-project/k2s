#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

dir="."
dockerfile=""
name=""
tag=""
push=false
build_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir|--input-folder)
      dir="$2"
      shift 2
      ;;
    -f|--file|--dockerfile)
      dockerfile="$2"
      shift 2
      ;;
    -n|--name|--image-name)
      name="$2"
      shift 2
      ;;
    -t|--tag|--image-tag)
      tag="$2"
      shift 2
      ;;
    -p|--push)
      push=true
      shift
      ;;
    --build-arg)
      build_args+=("--build-arg" "$2")
      shift 2
      ;;
    --build-arg=*)
      build_args+=("--build-arg" "${1#*=}")
      shift
      ;;
    -h|--help)
      echo "Usage: Build-Image.sh [-d <dir>] [-f <dockerfile>] [-n <name>] [-t <tag>] [--push] [--build-arg <k=v>...]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

k2s_require_directory "$dir" || exit 1

full_image=""
if [[ -n "$name" && -n "$tag" ]]; then
  full_image="${name}:${tag}"
elif [[ -n "$name" ]]; then
  full_image="${name}"
elif [[ -n "$tag" ]]; then
  full_image="${tag}"
fi

if ! command -v buildah >/dev/null 2>&1 && ! command -v nerdctl >/dev/null 2>&1; then
  k2s_log INFO "buildah is not installed; installing buildah..."
  if command -v apt-get >/dev/null 2>&1; then
    k2s_run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
      buildah || true
  fi
fi

precompiled_binary=""
cleanup() {
  if [[ -n "$precompiled_binary" && -f "$precompiled_binary" ]]; then
    rm -f "$precompiled_binary"
  fi
}
trap cleanup EXIT

# If no dockerfile specified, check for Dockerfile.PreCompile or Dockerfile
if [[ -z "$dockerfile" ]]; then
  if [[ -f "$dir/Dockerfile.PreCompile" ]]; then
    dockerfile="$dir/Dockerfile.PreCompile"
  elif [[ -f "$dir/Dockerfile" ]]; then
    dockerfile="$dir/Dockerfile"
  fi
elif [[ ! -f "$dockerfile" && -f "$dir/$dockerfile" ]]; then
  dockerfile="$dir/$dockerfile"
fi

# Pre-compilation support: compile the binary on the Linux host first, then use for image build
if [[ -n "$dockerfile" && "$dockerfile" == *"PreCompile"* && -f "$dockerfile" ]]; then
  exe_name="$(grep -m1 -E '^# *ExeName: +' "$dockerfile" | awk '{print $NF}' || true)"
  if [[ -n "$exe_name" && ! -f "$dir/$exe_name" ]]; then
    go_cmd="$(command -v go 2>/dev/null || echo "")"
    if [[ -z "$go_cmd" && -x /usr/local/go/bin/go ]]; then
      go_cmd="/usr/local/go/bin/go"
    fi
    if [[ -n "$go_cmd" ]] && { [[ -f "$dir/go.mod" ]] || [[ -f "$dir/main.go" ]]; }; then
      k2s_log INFO "Pre-compiling Go binary '$exe_name' on Linux host..."
      (cd "$dir" && CGO_ENABLED=0 "$go_cmd" build -ldflags="-w -s" -trimpath -o "$exe_name" .)
      precompiled_binary="$dir/$exe_name"
    else
      k2s_log WARN "PreCompile requested for '$exe_name' but Go compiler or Go source not found in '$dir'"
    fi
  fi
fi

builder=""
if command -v buildah >/dev/null 2>&1; then
  builder="buildah"
elif command -v nerdctl >/dev/null 2>&1; then
  builder="nerdctl"
else
  k2s_log ERROR "No container image builder found. Please install buildah (apt-get install -y buildah)."
  exit 127
fi

build_cmd=("$builder")
if [[ "$builder" == "buildah" ]]; then
  build_cmd+=("bud" "--layers")
else
  build_cmd+=("build")
fi

if [[ -n "$dockerfile" ]]; then
  build_cmd+=("-f" "$dockerfile")
fi
if [[ -n "$full_image" ]]; then
  build_cmd+=("-t" "$full_image")
fi
if [[ ${#build_args[@]} -gt 0 ]]; then
  build_cmd+=("${build_args[@]}")
fi
build_cmd+=("$dir")

k2s_log INFO "Building container image with $builder"
k2s_run "${build_cmd[@]}"

if [[ "$push" == true ]]; then
  if [[ -z "$full_image" ]]; then
    k2s_log ERROR "Cannot push image: image name not specified"
    exit 1
  fi
  k2s_log INFO "Pushing container image $full_image with $builder"
  k2s_run "$builder" push "$full_image"
fi
