#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Exports addons as an OCI artifact on a native Linux host, like addons/Export.ps1 does on Windows
# hosts: per addon implementation one OCI manifest with config, manifests, charts, scripts, Linux
# images and packages layers, referenced by an OCI image index, written as
# K2s-<version>-addons-<names>.oci.tar. Windows images cannot be pulled on a Linux host and are
# skipped, like the Windows packages. The artifact can be imported with 'k2s addons import' on
# Windows and Linux hosts.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"
# Names and digests are compared byte-wise, independent of the locale of the host.
export LC_ALL=C

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/cluster/addon-oci.sh"

readonly ADDON_EXPORT_MANIFEST='addon.manifest.yaml'
readonly ADDON_EXPORT_PROXY_PORT=8181
readonly ADDON_EXPORT_PULL_ATTEMPTS=3

# Runs a filter with the jq functions of addon-oci.sh: addon_export_jq <filter> [jq options and arguments...].
addon_export_jq() {
  local filter="$1"
  shift
  jq "$ADDON_OCI_JQ_DEFS
$filter" "$@"
}

# Progress is always shown, like the console output of addons/Export.ps1.
addon_export_log() {
  k2s_log INFO "$*"
  k2s_show_logs || printf '%s\n' "$*"
}

# For functions whose stdout is their result: k2s_log INFO would write to stdout when logs are shown.
addon_export_log_to_file() {
  printf '%s [INFO] %s\n' "$(date -Is)" "$*" >>"$K2S_LOG_FILE"
}

# The last error line is the reason the Go wrapper reports, so every failure prints exactly one.
addon_export_error() {
  k2s_log ERROR "${addon_export_context:+$addon_export_context: }$*"
}

addon_export_usage() {
  cat <<'USAGE'
Usage: Export-Addon.sh -d <output-dir> [-a <addon>]... [--omit-images] [--omit-packages]

  -d, --output-dir   directory that receives K2s-<version>-addons-<names>.oci.tar
  -a, --addon        addon to export ('ingress', 'ingress nginx' or 'ingress', 'nginx'); repeatable, default: all
  --omit-images      do not pull and package container images
  --omit-packages    do not download and package debian, linux and windows packages
USAGE
}

addon_export_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Fills manifest_paths, manifest_names and manifest_dirs with the addons of the installation, like
# Find-AddonManifests of addons/addons.module.psm1 (addon.manifest.yaml one level below addons/).
addon_export_find_manifests() {
  local path name
  manifest_paths=() manifest_names=() manifest_dirs=()
  while IFS= read -r path; do
    if ! name="$(yq '.metadata.name // ""' "$path" 2>/dev/null)"; then
      addon_export_error "reading addon manifest $path failed"
      return 1
    fi
    [[ -z $name || $name == null ]] && continue
    manifest_paths+=("$path")
    manifest_names+=("$name")
    manifest_dirs+=("$(dirname "$path")")
  done < <(find "$K2S_INSTALL_DIR/addons" -mindepth 2 -maxdepth 2 -type f -name "$ADDON_EXPORT_MANIFEST" | sort)
}

addon_export_implementations() {
  yq '.spec.implementations[] | .name // ""' "${manifest_paths[$1]}"
}

# Fills export_manifests and export_implementations with the addon implementations to export. A request
# is a base addon ('ingress', all implementations), a quoted implementation ('ingress nginx') or an
# addon followed by an implementation ('ingress', 'nginx'); the next request is taken as implementation
# unless it names an addon itself. 'storage' alone means its default implementation 'smb', like
# 'k2s addons enable storage'.
addon_export_select() {
  local -a requests=("$@") parts=()
  local i j request addon implementation next found implementation_name
  export_manifests=() export_implementations=()

  if ((${#requests[@]} == 0)); then
    for j in "${!manifest_paths[@]}"; do
      while IFS= read -r implementation_name; do
        [[ -n $implementation_name ]] || continue
        export_manifests+=("$j") export_implementations+=("$implementation_name")
      done < <(addon_export_implementations "$j")
    done
    return 0
  fi

  for ((i = 0; i < ${#requests[@]}; i++)); do
    request="${requests[i]}"
    parts=()
    read -r -a parts <<<"$request" || true
    addon="${parts[0]:-}" implementation="${parts[1]:-}"

    if [[ -z $implementation ]] && ((i + 1 < ${#requests[@]})); then
      next="${requests[i + 1]}"
      next="${next%%[[:space:]]*}"
      found=false
      for j in "${!manifest_names[@]}"; do
        [[ ${manifest_names[j],,} == "${next,,}" ]] && found=true
      done
      if [[ $found == false ]]; then
        implementation="${requests[i + 1]}"
        i=$((i + 1))
      fi
    fi
    if [[ -z $implementation && ${addon,,} == storage ]]; then
      implementation=smb
    fi

    found=""
    for j in "${!manifest_names[@]}"; do
      if [[ ${manifest_names[j],,} == "${addon,,}" ]]; then
        found="$j"
        break
      fi
    done
    if [[ -z $found ]]; then
      addon_export_error "no addon with name '$addon' found"
      return 1
    fi

    local matched=false
    while IFS= read -r implementation_name; do
      [[ -n $implementation_name ]] || continue
      if [[ -z $implementation || ${implementation_name,,} == "${implementation,,}" ]]; then
        export_manifests+=("$found") export_implementations+=("$implementation_name")
        matched=true
      fi
    done < <(addon_export_implementations "$found")
    # Export.ps1 silently exports nothing here; an artifact without the requested addon would only fail
    # later, when it is imported offline.
    if [[ $matched == false ]]; then
      addon_export_error "addon '${manifest_names[found]}' has no implementation${implementation:+ '$implementation'}"
      return 1
    fi
  done
}

# Copies the files below a directory that match one of the find name tests, keeping their relative paths.
addon_export_copy_matching() {
  local source="$1" destination="$2" file relative
  shift 2
  [[ -d $source ]] || return 0
  while IFS= read -r -d '' file; do
    relative="${file#"$source"/}"
    mkdir -p "$destination/$(dirname "$relative")" || return 1
    cp "$file" "$destination/$relative" || return 1
  done < <(find "$source" -type f \( "$@" \) -print0)
}

# Copies the files at the root of a multi-implementation addon (README, shared modules) into the shared scripts
# layer, like Copy-AddonSharedScripts of addons/export.module.psm1. The manifest is merged through the config layer.
addon_export_shared_scripts() {
  local addon_path="$1" implementation_path="$2" destination="$3" file
  if [[ $addon_path == "$implementation_path" ]]; then
    return 0
  fi
  while IFS= read -r -d '' file; do
    case $(basename "$file") in
      addon.manifest.yaml | addon.manifest.yaml.license) continue ;;
    esac
    cp "$file" "$destination/" || return 1
  done < <(find "$addon_path" -maxdepth 1 -type f -print0)
}

# Adds the gitops-sync Job template to the manifests layer for GitOps delivery.
addon_export_gitops_sync() {
  local destination="$1" folder_name="$2" source="$K2S_INSTALL_DIR/addons/common/manifests/addon-sync/gitops-sync"
  local job content timestamp
  if [[ ! -d $source ]]; then
    addon_export_log "Warning: gitops-sync source directory not found at $source"
    return 0
  fi
  mkdir -p "$destination/gitops-sync" || return 1
  cp -R "$source/." "$destination/gitops-sync/" || return 1

  job="$destination/gitops-sync/sync-job.yaml"
  if [[ ! -f $job ]]; then
    addon_export_log "Warning: sync-job.yaml not found at $job"
    return 0
  fi
  timestamp="$(addon_export_timestamp)"
  content="$(<"$job")"
  content="${content//EXPORT_TIMESTAMP_PLACEHOLDER/$timestamp}"
  content="${content//ADDON_NAME_PLACEHOLDER/$folder_name}"
  printf '%s\n' "$content" >"$job" || return 1
  addon_export_log "Injected gitops-sync Job template with timestamp $timestamp and addon name $folder_name"
}

# Collects the configuration files: the addon manifest (reduced to the exported implementation when a
# single implementation of a multi-implementation addon is exported), values and settings files, the
# config subdirectory and addon-specific JSON configuration.
addon_export_config_files() {
  local base_manifest="$1" base_name="$2" implementation="$3" implementation_path="$4" destination="$5" single_export="$6" file name parent
  if [[ -f $base_manifest ]]; then
    cp "$base_manifest" "$destination/$ADDON_EXPORT_MANIFEST" || return 1
    if [[ $single_export == true && $implementation != "$base_name" ]]; then
      if IMPLEMENTATION="$implementation" yq -i '.spec.implementations |= [.[] | select(.name == strenv(IMPLEMENTATION))]' "$destination/$ADDON_EXPORT_MANIFEST"; then
        addon_export_log "Filtered manifest for single implementation: $implementation"
      else
        addon_export_log "Failed to filter manifest with yq, falling back to copy"
        cp "$base_manifest" "$destination/$ADDON_EXPORT_MANIFEST" || return 1
      fi
    fi
  else
    k2s_log INFO "Warning: $ADDON_EXPORT_MANIFEST not found for $base_name"
  fi

  while IFS= read -r -d '' file; do
    cp "$file" "$destination/" || return 1
  done < <(find "$implementation_path" -mindepth 1 -maxdepth 1 -type f \( -iname 'values.yaml' -o -iname 'values-*.yaml' \
    -o -iname 'settings.json' -o -iname '*.config.json' -o -iname '*.config.yaml' \) -print0)

  if [[ -d "$implementation_path/config" ]]; then
    mkdir -p "$destination/config" || return 1
    cp -R "$implementation_path/config/." "$destination/config/" || return 1
  fi

  while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    [[ ${name,,} =~ ^(package|tsconfig|eslint|babel) ]] && continue
    parent="$(basename "$(dirname "$file")")"
    [[ ${parent,,} == "${base_name,,}" ]] || continue
    grep -Eqi '"apiVersion"[[:space:]]*:[[:space:]]*"' "$file" && continue
    cp "$file" "$destination/" || return 1
  done < <(find "$implementation_path" -type f -iname '*.json' -print0)
}

# Prints the images referenced by 'image:' lines of the YAML files as '<linux|windows>\t<image>'; files
# marked '## exclude-from-export' and commented lines are skipped, '#windows_image' marks Windows images.
addon_export_images_of_files() {
  local file line lower prefix rest lower_rest image kind
  for file in "$@"; do
    [[ -f $file ]] || continue
    grep -qi -- '## exclude-from-export' "$file" && continue
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%$'\r'}"
      lower="${line,,}"
      [[ $lower == *'image:'* ]] || continue
      [[ ${line#"${line%%[![:space:]]*}"} == '#'* ]] && continue
      [[ $lower == *'image: '* ]] || continue
      prefix="${lower%%image: *}"
      rest="${line:${#prefix}+7}"
      lower_rest="${rest,,}"
      if [[ $lower_rest == *'image: '* ]]; then
        prefix="${lower_rest%%image: *}"
        rest="${rest:0:${#prefix}}"
      fi
      image="${rest%%#*}"
      if [[ $image != *:* ]]; then
        addon_export_log_to_file "Image is not valid $image, will skip it"
        continue
      fi
      kind=linux
      [[ $line == *'#windows_image'* ]] && kind=windows
      printf '%s\t%s\n' "$kind" "$image"
    done <"$file"
  done
}

# Prints the images of additionalImagesFiles, resolved against the implementation directory.
addon_export_images_of_declared_files() {
  local base="$1" file
  shift
  for file in "$@"; do
    [[ $file == /* ]] || file="$base/$file"
    if [[ ! -f $file ]]; then
      addon_export_log_to_file "Warning: YAML file not found: $file"
      continue
    fi
    addon_export_jq 'images_from_yaml[]' -rRs <"$file"
  done
}

# Pulls an image with buildah and prints its image ID.
addon_export_pull() {
  local image="$1" attempt output
  for ((attempt = 1; attempt <= ADDON_EXPORT_PULL_ATTEMPTS; attempt++)); do
    if output="$(buildah pull -q "$image" 2>&1)"; then
      printf '%s\n' "${output##*$'\n'}"
      return 0
    fi
    addon_export_log_to_file "Pulling linux image $image failed (attempt $attempt): $output"
  done
  addon_export_error "Pulling linux image $image failed: ${output##*$'\n'}"
  return 1
}

# Collects, pulls and exports the Linux images of one addon implementation into images-linux.tar.
addon_export_images() {
  local addon_name="$1" implementation_path="$2" dir_name="$3" implementation_json="$4" images_dir="$5" layer="$6"
  local chart chart_folder values base release image id archive kind output
  local -a files=() charts=() linux=() windows=() additional=() archives=()

  addon_export_log "Pulling images for addon $addon_name from $implementation_path"
  mapfile -t files < <(find "$implementation_path" -type f -iname '*?yaml' | sort)

  if [[ -d "$implementation_path/manifests/chart" ]]; then
    mapfile -t charts < <(find "$implementation_path/manifests/chart" -type f -iname '*?tgz' | sort -u)
    if ((${#charts[@]} == 0)); then
      addon_export_log_to_file "No images found for addon $addon_name in form of an chart"
    else
      if ! command -v helm >/dev/null 2>&1; then
        addon_export_error "helm is required to find the images of the charts of addon $addon_name"
        return 1
      fi
      chart_folder="$work_dir/helm/$dir_name"
      mkdir -p "$chart_folder" || return 1
      values="$implementation_path/manifests/chart/values.yaml"
      for chart in "${charts[@]}"; do
        # kubernetes-dashboard-7.0.0.tgz -> release kubernetes-dashboard
        base="$(basename "$chart")"
        base="${base%.*}"
        release="${base%-*}"
        local -a values_args=()
        if [[ -f $values ]]; then
          values_args=(-f "$values")
        fi
        # Images referenced only by the chart would be missing from the artifact, so a chart that cannot
        # be rendered fails the export.
        if ! output="$(helm template "$release" "$chart" "${values_args[@]}" --output-dir "$chart_folder" 2>&1)"; then
          addon_export_error "rendering chart $(basename "$chart") of addon $addon_name failed: ${output##*$'\n'}"
          return 1
        fi
        printf '%s\n' "$output" | k2s_log_output >/dev/null
        mapfile -t -O "${#files[@]}" files < <(find "$chart_folder" -type f -iname '*?yaml' | sort)
      done
    fi
  fi

  while IFS=$'\t' read -r kind image; do
    [[ -z $image ]] && continue
    if [[ $kind == windows ]]; then windows+=("$image"); else linux+=("$image"); fi
  done < <(addon_export_images_of_files "${files[@]}")

  mapfile -t additional < <(jq -r '.offline_usage.linux.additionalImages // [] | .[] | tostring' <<<"$implementation_json")
  linux+=("${additional[@]}")
  mapfile -t additional < <(jq -r '.offline_usage.linux.additionalImagesFiles // [] | .[] | tostring' <<<"$implementation_json")
  if ((${#additional[@]} > 0)); then
    mapfile -t -O "${#linux[@]}" linux < <(addon_export_images_of_declared_files "$implementation_path" "${additional[@]}")
  fi
  mapfile -t additional < <(jq -r '.offline_usage.windows.additionalImages // [] | .[] | tostring' <<<"$implementation_json")
  windows+=("${additional[@]}")
  mapfile -t additional < <(jq -r '.offline_usage.windows.additionalImagesFiles // [] | .[] | tostring' <<<"$implementation_json")
  if ((${#additional[@]} > 0)); then
    mapfile -t -O "${#windows[@]}" windows < <(addon_export_images_of_declared_files "$implementation_path" "${additional[@]}")
  fi

  mapfile -t linux < <(addon_export_jq '$ARGS.positional | clean_images[]' -nr --args "${linux[@]}")
  mapfile -t windows < <(addon_export_jq '$ARGS.positional | clean_images[]' -nr --args "${windows[@]}")
  addon_export_log_to_file "[AddonExport] Linux images to pull (${#linux[@]}): ${linux[*]}"
  addon_export_log_to_file "[AddonExport] Windows images (${#windows[@]}): ${windows[*]}"
  if ((${#windows[@]} > 0)); then
    addon_export_log "Skipping ${#windows[@]} Windows image(s) of addon $addon_name: exporting them is not supported on Linux hosts"
  fi
  if ((${#linux[@]} == 0)); then
    addon_export_log_to_file "No images found for addon $addon_name"
    return 0
  fi

  addon_export_log "Exporting images for addon $addon_name"
  for image in "${linux[@]}"; do
    addon_export_log_to_file "Pulling linux image $image"
    id="$(addon_export_pull "$image")" || return 1
    archive="$(addon_export_jq '$image | archive_name' -nr --arg image "$image")"
    if ! bash "$K2S_INSTALL_DIR/lib/scripts/linux/debian/host/image/Export-Image.sh" -i "$id" -t "$images_dir/$archive"; then
      addon_export_error "Image $image could not be exported."
      return 1
    fi
    archives+=("./$archive")
  done

  addon_export_log_to_file "Consolidating ${#archives[@]} Linux images into single layer"
  tar -cf "$layer" -C "$images_dir" "${archives[@]}" || return 1
}

# Downloads a package through the K2s HTTP proxy of the host, like Invoke-DownloadFile.
addon_export_download() {
  local destination="$1" url="$2"
  mkdir -p "$(dirname "$destination")" || return 1
  if [[ -n $proxy ]]; then
    addon_export_log_to_file "Downloading '$url' to '$destination' with proxy: $proxy"
    curl --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo "$destination" "$url" --proxy "$proxy" && return 0
  else
    addon_export_log_to_file "Downloading '$url' to '$destination' (no proxy)"
    curl --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo "$destination" "$url" --noproxy '*' && return 0
  fi
  addon_export_error "Download '$url' failed"
  return 1
}

# Downloads the offline packages of one addon implementation: debian packages with their dependencies
# (after running the repository setup commands of the manifest) and the linux curl packages. Windows
# packages are skipped, they are only used on Windows hosts. The debian packages are kept in
# ~/.<addon> between exports, like on the Linux node of a Windows host, so that a package is
# downloaded only once.
addon_export_packages() {
  local addon_name="$1" dir_name="$2" implementation_json="$3" destination="$4"
  local repo command package cache archives url output
  local -a repos=() debs=() urls=()

  addon_export_log "Downloading packages for addon $addon_name"

  mapfile -t repos < <(jq -r '.offline_usage.linux.repos // [] | .[] | tostring' <<<"$implementation_json")
  if ((${#repos[@]} > 0)); then
    addon_export_log_to_file "Adding repos for debian packages download"
    for repo in "${repos[@]}"; do
      command="${repo//__LOCAL_HTTP_PROXY__/${proxy_address:-\"\"}}"
      bash -c "$command" 2>&1 | k2s_log_output >/dev/null || addon_export_log "Warning: adding a package repository for addon $addon_name failed"
    done
    apt-get update >/dev/null 2>&1 || addon_export_log "Warning: apt-get update failed"
  fi

  mapfile -t debs < <(jq -r '.offline_usage.linux.deb // [] | .[] | tostring' <<<"$implementation_json")
  if ((${#debs[@]} > 0)); then
    if ! command -v apt-get >/dev/null 2>&1; then
      addon_export_error "apt-get is required to download the debian packages of addon $addon_name"
      return 1
    fi
    cache="$(addon_export_home_dir)/.$dir_name"
    archives="$(addon_export_apt_archives)"
    apt-get clean >/dev/null 2>&1 || true
    for package in "${debs[@]}"; do
      if compgen -G "$cache/$package/*.deb" >/dev/null; then
        addon_export_log_to_file "Debian package \"$package\" is already available offline"
        continue
      fi
      addon_export_log_to_file "Downloading debian package \"$package\" with dependencies"
      # A missing package would only be noticed when the addon is enabled offline, so a failed download
      # fails the export, and an incomplete cache entry is removed so that a retry downloads it again.
      if ! output="$(DEBIAN_FRONTEND=noninteractive apt-get --download-only reinstall -y "$package" 2>&1)"; then
        apt-get clean >/dev/null 2>&1 || true
        addon_export_error "downloading debian package $package failed: ${output##*$'\n'}"
        return 1
      fi
      local -a downloaded=()
      shopt -s nullglob
      downloaded=("$archives"*.deb)
      shopt -u nullglob
      if ((${#downloaded[@]} == 0)) || ! mkdir -p "$cache/$package" || ! cp "${downloaded[@]}" "$cache/$package/"; then
        rm -rf "${cache:?}/$package"
        apt-get clean >/dev/null 2>&1 || true
        addon_export_error "no debian packages were downloaded for $package"
        return 1
      fi
      apt-get clean >/dev/null 2>&1 || true
    done
    mkdir -p "$destination/debianpackages" || return 1
    cp -R "$cache/." "$destination/debianpackages/" || return 1
  fi

  mapfile -t urls < <(jq -r '.offline_usage.linux.curl // [] | .[] | .url // empty | tostring' <<<"$implementation_json")
  for url in "${urls[@]}"; do
    addon_export_download "$destination/linuxpackages/$(addon_oci_url_file_name "$url")" "$url" || return 1
  done
  mapfile -t urls < <(jq -r '.offline_usage.windows.curl // [] | .[] | .url // empty | tostring' <<<"$implementation_json")
  if ((${#urls[@]} > 0)); then
    addon_export_log "Skipping ${#urls[@]} Windows package(s) of addon $addon_name: they are only used on Windows hosts"
  fi
}

addon_export_home_dir() {
  if [[ -n ${HOME:-} ]]; then
    printf '%s\n' "$HOME"
  else
    getent passwd "$(id -un)" | cut -d: -f6
  fi
}

# Prints the apt download directory (Dir::Cache::archives, /var/cache/apt/archives/ by default).
addon_export_apt_archives() {
  local ARCHIVES=""
  if command -v apt-config >/dev/null 2>&1; then
    eval "$(apt-config shell ARCHIVES Dir::Cache::archives/d 2>/dev/null)" || ARCHIVES=""
  fi
  ARCHIVES="${ARCHIVES:-/var/cache/apt/archives/}"
  printf '%s\n' "${ARCHIVES%/}/"
}

# Moves a file into the blobs directory and prints '<digest> <size>'.
addon_export_add_blob() {
  local file="$1" digest size
  digest="$(sha256sum "$file" | cut -d' ' -f1)" || return 1
  size="$(stat -c %s "$file")" || return 1
  mv -f "$file" "$blobs_dir/$digest" || return 1
  printf 'sha256:%s %s\n' "$digest" "$size"
}

# Archives the content of a directory as gzipped tar and adds it as layer of the current addon.
addon_export_add_tar_gz_layer() {
  local source="$1" media_type="$2" title="$3" archive="$artifact_dir/$3"
  if ! tar -czf "$archive" -C "$source" .; then
    addon_export_error "creating the $title layer failed"
    return 1
  fi
  addon_export_add_layer "$archive" "$media_type" "$title"
}

addon_export_add_layer() {
  local file="$1" media_type="$2" title="$3" blob digest size
  blob="$(addon_export_add_blob "$file")" || return 1
  read -r digest size <<<"$blob"
  layers_json="$(jq -c --arg mediaType "$media_type" --arg digest "$digest" --argjson size "$size" --arg title "$title" \
    '. + [{mediaType: $mediaType, size: $size, digest: $digest, annotations: {"org.opencontainers.image.title": $title}}]' <<<"$layers_json")" || return 1
  addon_export_log_to_file "Created $title layer: $digest"
}

addon_export_has_files() {
  [[ -d $1 ]] && [[ -n $(find "$1" -mindepth 1 -print -quit) ]]
}

# Exports one addon implementation into the OCI layout: stages its files, packs the layers, and stores
# its metadata config and OCI manifest as blobs.
addon_export_addon() {
  local index="$1" implementation="$2"
  local manifest="${manifest_paths[index]}" base_name="${manifest_names[index]}" base_dir="${manifest_dirs[index]}"
  local addon_name="$base_name" dir_name dir_path folder_name implementation_json version description now blob digest size
  local config_stage manifests_stage scripts_stage shared_stage packages_stage images_stage count

  dir_name="$(basename "$base_dir")" dir_path="$base_dir"
  if [[ $implementation != "$base_name" ]]; then
    addon_name+=" $implementation" dir_name+="-$implementation" dir_path="$base_dir/$implementation"
  fi
  folder_name="${addon_name// /-}"
  addon_export_context="exporting addon '$addon_name'"

  if ! implementation_json="$(IMPLEMENTATION="$implementation" yq -o=json -I=0 '.spec.implementations[] | select(.name == strenv(IMPLEMENTATION))' "$manifest" | head -n 1)"; then
    addon_export_error "reading implementation $implementation of $manifest failed"
    return 1
  fi
  [[ -n $implementation_json ]] || implementation_json='{}'

  artifact_dir="$artifacts_dir/$folder_name"
  config_stage="$artifact_dir/config-staging" manifests_stage="$artifact_dir/manifests-staging"
  scripts_stage="$artifact_dir/scripts-staging" shared_stage="$artifact_dir/shared-scripts-staging"
  packages_stage="$artifact_dir/packages-staging" images_stage="$artifact_dir/images-staging"
  mkdir -p "$config_stage" "$manifests_stage" "$scripts_stage" "$shared_stage" "$packages_stage" "$images_stage" || return 1

  addon_export_shared_scripts "$base_dir" "$dir_path" "$shared_stage" || return 1

  if [[ -d "$dir_path/manifests" ]]; then
    count="$(find "$dir_path/manifests" -type f | wc -l)"
    addon_export_log_to_file "Copying $count files from addon manifests directory"
    cp -R "$dir_path/manifests/." "$manifests_stage/" || return 1
  else
    addon_export_log_to_file "No manifests directory found at $dir_path/manifests"
  fi

  if [[ $base_name == storage && $implementation == ceph ]]; then
    if [[ -d "$base_dir/smb/manifests" ]]; then
      addon_export_log_to_file "Copying shared SMB manifest files into Ceph export fallback bundle"
      mkdir -p "$manifests_stage/smb-shared" || return 1
      cp -R "$base_dir/smb/manifests/." "$manifests_stage/smb-shared/" || return 1
    else
      addon_export_log "Warning: shared SMB manifests not found at $base_dir/smb/manifests while exporting storage ceph"
    fi
  fi

  addon_export_gitops_sync "$manifests_stage" "$folder_name" || return 1

  if [[ -f "$dir_path/README.md" ]]; then
    cp "$dir_path/README.md" "$scripts_stage/" || return 1
  fi
  addon_export_copy_matching "$dir_path" "$scripts_stage" -iname '*.ps1' -o -iname '*.psm1' -o -iname '*.sh' || return 1
  addon_export_copy_matching "$dir_path" "$scripts_stage" \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \
    -o -iname '*.svg' -o -iname '*.drawio' -o -iname '*.md' -o -iname '*.ndjson' -o -iname '*.json' -o -iname '*.license' \
    -o -iname '*.tar.gz' -o -iname 'Dockerfile*' \) ! -path "$dir_path/README.md" || return 1

  addon_export_config_files "$base_dir/$ADDON_EXPORT_MANIFEST" "$base_name" "$implementation" "$dir_path" "$config_stage" "$single_export" || return 1

  addon_export_log "Preparing OCI artifact for addon $addon_name"
  if [[ $omit_images == true ]]; then
    addon_export_log "Omitting container images for addon $addon_name (--omit-images)"
  else
    addon_export_images "$addon_name" "$dir_path" "$dir_name" "$implementation_json" "$images_stage" "$artifact_dir/images-linux.tar" || return 1
  fi

  if [[ $omit_packages == true ]]; then
    addon_export_log "Omitting packages for addon $addon_name (--omit-packages)"
  elif jq -e '.offline_usage != null' >/dev/null <<<"$implementation_json"; then
    addon_export_packages "$addon_name" "$dir_name" "$implementation_json" "$packages_stage" || return 1
  fi

  addon_export_log "Creating OCI artifact layers for $addon_name"
  layers_json='[]'
  if addon_export_has_files "$config_stage"; then
    addon_export_add_tar_gz_layer "$config_stage" "$ADDON_OCI_CONFIG_FILES_MEDIA_TYPE" config.tar.gz || return 1
  fi
  # The manifests layer is always present, empty if the addon has no manifests.
  addon_export_add_tar_gz_layer "$manifests_stage" "$ADDON_OCI_MANIFESTS_MEDIA_TYPE" manifests.tar.gz || return 1
  if [[ -d "$manifests_stage/chart" ]]; then
    addon_export_add_tar_gz_layer "$manifests_stage/chart" "$ADDON_OCI_CHARTS_MEDIA_TYPE" charts.tar.gz || return 1
  fi
  if addon_export_has_files "$scripts_stage"; then
    addon_export_add_tar_gz_layer "$scripts_stage" "$ADDON_OCI_SCRIPTS_MEDIA_TYPE" scripts.tar.gz || return 1
  fi
  if [[ -n $(find "$shared_stage" -mindepth 1 -maxdepth 1 -type f -print -quit) ]]; then
    addon_export_add_tar_gz_layer "$shared_stage" "$ADDON_OCI_SHARED_SCRIPTS_MEDIA_TYPE" shared-scripts.tar.gz || return 1
  fi
  if [[ -f "$artifact_dir/images-linux.tar" ]]; then
    addon_export_add_layer "$artifact_dir/images-linux.tar" "$ADDON_OCI_LINUX_IMAGES_MEDIA_TYPE" images-linux.tar || return 1
  fi
  if addon_export_has_files "$packages_stage"; then
    addon_export_add_tar_gz_layer "$packages_stage" "$ADDON_OCI_PACKAGES_MEDIA_TYPE" packages.tar.gz || return 1
  fi

  version="$(jq -r '.version // "1.0.0" | tostring' <<<"$implementation_json")"
  description="$(yq '.metadata.description // ""' "$manifest")"
  now="$(addon_export_timestamp)"

  jq -n --arg name "$base_name" --arg version "$version" --arg implementation "$implementation" --arg description "$description" \
    --arg k2sVersion "$k2s_version" --arg exportDate "$now" \
    '{name: $name, version: $version, implementation: $implementation, description: $description, k2sVersion: $k2sVersion, exportDate: $exportDate}' \
    >"$artifact_dir/metadata.json" || return 1
  blob="$(addon_export_add_blob "$artifact_dir/metadata.json")" || return 1
  read -r digest size <<<"$blob"
  local config_descriptor
  config_descriptor="$(jq -nc --arg mediaType "$ADDON_OCI_CONFIG_MEDIA_TYPE" --arg digest "$digest" --argjson size "$size" \
    '{mediaType: $mediaType, size: $size, digest: $digest}')"

  if [[ $layers_json == '[]' ]]; then
    printf '{}' >"$artifact_dir/empty.json"
    blob="$(addon_export_add_blob "$artifact_dir/empty.json")" || return 1
    read -r digest size <<<"$blob"
    layers_json="$(jq -nc --arg mediaType "$ADDON_OCI_EMPTY_MEDIA_TYPE" --arg digest "$digest" --argjson size "$size" \
      '[{mediaType: $mediaType, size: $size, digest: $digest}]')"
  fi

  jq -n --arg mediaType "$ADDON_OCI_MANIFEST_MEDIA_TYPE" --arg artifactType "$ADDON_OCI_ARTIFACT_TYPE" \
    --argjson config "$config_descriptor" --argjson layers "$layers_json" \
    --arg title "$folder_name" --arg version "$version" --arg created "$now" --arg description "${description:-K2s addon: $base_name}" \
    --arg name "$base_name" --arg implementation "$implementation" --arg k2sVersion "$k2s_version" --arg exportType "$export_type" \
    --arg nameKey "$ADDON_OCI_NAME_ANNOTATION" --arg implementationKey "$ADDON_OCI_IMPL_ANNOTATION" \
    '{schemaVersion: 2, mediaType: $mediaType, artifactType: $artifactType, config: $config, layers: $layers,
      annotations: {
        "org.opencontainers.image.title": $title, "org.opencontainers.image.version": $version,
        "org.opencontainers.image.created": $created, "org.opencontainers.image.vendor": "K2s Project",
        "org.opencontainers.image.licenses": "Apache-2.0", "org.opencontainers.image.description": $description,
        ($nameKey): $name, ($implementationKey): $implementation, "vnd.k2s.addon.export-name": $title,
        "vnd.k2s.version": $k2sVersion, "vnd.k2s.export.date": $created, "vnd.k2s.export.type": $exportType}}' \
    >"$artifact_dir/manifest.json" || return 1
  blob="$(addon_export_add_blob "$artifact_dir/manifest.json")" || return 1
  read -r digest size <<<"$blob"

  if ! jq -nc --arg dirName "$folder_name" --arg name "$base_name" --arg implementation "$implementation" --arg version "$version" \
    --arg digest "$digest" --argjson size "$size" \
    '{dirName: $dirName, name: $name, implementation: $implementation, version: $version, digest: $digest, size: $size}' \
    >>"$work_dir/references.jsonl"; then
    addon_export_error "recording the OCI manifest failed"
    return 1
  fi
  addon_export_log_to_file "Stored addon manifest in blobs: $digest"

  rm -rf "$artifact_dir"
  addon_export_context=""
  addon_export_log '---'
}

addon_export_require_tools() {
  local tool
  for tool in tar sha256sum stat jq yq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      addon_export_error "required command '$tool' is not available - install it and export again"
      return 1
    fi
  done
  if [[ $(yq --version 2>&1) != *mikefarah* ]]; then
    addon_export_error "yq from https://github.com/mikefarah/yq is required; $(command -v yq) is another implementation"
    return 1
  fi
  if [[ $omit_images == false ]] && ! command -v buildah >/dev/null 2>&1; then
    addon_export_error "buildah is required to export container images - install it or export with --omit-images"
    return 1
  fi
}

addon_export_main() {
  local output_dir="" i names_part final now line
  local -a names=()
  omit_images=false omit_packages=false single_export=false export_type=all
  work_dir="" artifacts_dir="" blobs_dir="" artifact_dir="" layers_json='[]' addon_export_context="" proxy="" proxy_address=""
  manifest_paths=() manifest_names=() manifest_dirs=() export_manifests=() export_implementations=()

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        addon_export_usage
        return 0
        ;;
      -d | --output-dir | -a | --addon)
        if (($# < 2)); then
          addon_export_error "option $1 requires a value"
          return 2
        fi
        case "$1" in
          -d | --output-dir) output_dir="$2" ;;
          -a | --addon) names+=("$2") ;;
        esac
        shift 2
        ;;
      --omit-images)
        omit_images=true
        shift
        ;;
      --omit-packages)
        omit_packages=true
        shift
        ;;
      *)
        addon_export_error "unknown option: $1"
        return 2
        ;;
    esac
  done
  if [[ -z $output_dir ]]; then
    addon_export_error "no export path provided (-d)"
    return 2
  fi
  if ((${#names[@]} > 0)); then
    export_type=specific
  fi
  if ((${#names[@]} == 1)); then
    single_export=true
  fi

  addon_export_require_tools || return 1
  if [[ ! -f "$K2S_INSTALL_DIR/VERSION" ]]; then
    addon_export_error "VERSION file not found in $K2S_INSTALL_DIR"
    return 1
  fi
  k2s_version="$(tr -d '[:space:]' <"$K2S_INSTALL_DIR/VERSION")"
  proxy_address="$(jq -r '.smallsetup.kubeSwitch // empty' "$K2S_INSTALL_DIR/cfg/config.json" 2>/dev/null || true)"
  if [[ -n $proxy_address ]]; then
    proxy_address+=":$ADDON_EXPORT_PROXY_PORT"
    proxy="http://$proxy_address"
  fi

  addon_export_find_manifests || return 1
  addon_export_select "${names[@]}" || return 1

  # Staged next to the artifact rather than below the RAM-backed /tmp of Debian 13.
  work_dir="$output_dir/tmp-exported-addons"
  rm -rf "$work_dir"
  artifacts_dir="$work_dir/artifacts"
  blobs_dir="$artifacts_dir/blobs/sha256"
  mkdir -p "$blobs_dir" || return 1
  trap 'rm -rf "$work_dir"' EXIT
  jq -nc --arg version "$ADDON_OCI_LAYOUT_VERSION" '{imageLayoutVersion: $version}' >"$artifacts_dir/oci-layout"
  : >"$work_dir/references.jsonl"

  for i in "${!export_manifests[@]}"; do
    addon_export_addon "${export_manifests[i]}" "${export_implementations[i]}" || return 1
  done

  now="$(addon_export_timestamp)"
  if ! jq -s --arg mediaType "$ADDON_OCI_INDEX_MEDIA_TYPE" --arg manifestMediaType "$ADDON_OCI_MANIFEST_MEDIA_TYPE" \
    --arg artifactType "$ADDON_OCI_ARTIFACT_TYPE" --arg created "$now" --arg k2sVersion "$k2s_version" --arg exportType "$export_type" \
    --arg nameKey "$ADDON_OCI_NAME_ANNOTATION" --arg implementationKey "$ADDON_OCI_IMPL_ANNOTATION" \
    '{schemaVersion: 2, mediaType: $mediaType,
      manifests: [.[] | {mediaType: $manifestMediaType, size: .size, digest: .digest, artifactType: $artifactType,
        annotations: {"org.opencontainers.image.ref.name": ("v" + .version), "org.opencontainers.image.title": .dirName,
          "org.opencontainers.image.version": .version, ($nameKey): .name, ($implementationKey): .implementation,
          "vnd.k2s.addon.export-name": .dirName}}],
      annotations: {"org.opencontainers.image.created": $created, "org.opencontainers.image.vendor": "K2s Project",
        "org.opencontainers.image.licenses": "Apache-2.0", "vnd.k2s.version": $k2sVersion, "vnd.k2s.export.date": $created,
        "vnd.k2s.export.type": $exportType, "vnd.k2s.addon.count": (length | tostring)}}' \
    "$work_dir/references.jsonl" >"$artifacts_dir/index.json"; then
    addon_export_error "writing the OCI image index failed"
    return 1
  fi

  if [[ $export_type == all ]]; then
    names_part=all
  else
    names_part="$(jq -r '[.dirName | gsub("[_\\s]+"; "-") | ascii_downcase] | .[]' "$work_dir/references.jsonl" | paste -sd- -)"
  fi
  final="$output_dir/K2s-$k2s_version-addons-$names_part$ADDON_OCI_ARTIFACT_SUFFIX"
  rm -f "$final"
  if ! tar -cf "$final" -C "$artifacts_dir" .; then
    addon_export_error "writing $final failed"
    return 1
  fi

  addon_export_log "Addons exported successfully as OCI-compliant artifact to $final"
  while IFS= read -r line; do
    addon_export_log "$line"
  done <<EOF
OCI Image Layout structure:
  oci-layout           - OCI layout marker (imageLayoutVersion: $ADDON_OCI_LAYOUT_VERSION)
  index.json           - OCI image index with manifest references
  blobs/sha256/        - Content-addressable blob storage
Layer types:
  Config:  metadata.json       ($ADDON_OCI_CONFIG_MEDIA_TYPE)
  Layer 0: config.tar.gz       ($ADDON_OCI_CONFIG_FILES_MEDIA_TYPE)
  Layer 1: manifests.tar.gz    ($ADDON_OCI_MANIFESTS_MEDIA_TYPE)
  Layer 2: charts.tar.gz       ($ADDON_OCI_CHARTS_MEDIA_TYPE) [if helm-based]
  Layer 3: scripts.tar.gz      ($ADDON_OCI_SCRIPTS_MEDIA_TYPE)
  Shared: shared-scripts.tar.gz (addon-root scripts, when present)
  Layer 4: images-linux.tar    ($ADDON_OCI_LINUX_IMAGES_MEDIA_TYPE)$([[ $omit_images == true ]] && printf ' [SKIPPED]')
  Layer 5: images-windows.tar  ($ADDON_OCI_WINDOWS_IMAGES_MEDIA_TYPE) [SKIPPED on Linux hosts]
  Layer 6: packages.tar.gz     ($ADDON_OCI_PACKAGES_MEDIA_TYPE)$([[ $omit_packages == true ]] && printf ' [SKIPPED]' || printf ' [Windows packages SKIPPED on Linux hosts]')
EOF
}

# Sourcing the script only defines its functions.
if ! (return 0 2>/dev/null); then
  addon_export_main "$@"
fi
