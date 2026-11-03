#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

tar_path=""
dir_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tar|--image-path)
      tar_path="$2"
      shift 2
      ;;
    -d|--dir|--image-dir)
      dir_path="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Import-Image.sh [-t <tar-path>] [-d <dir-path>]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$tar_path" && -z "$dir_path" ]]; then
  k2s_log ERROR "Either tar file path (-t) or directory path (-d) must be specified"
  exit 1
fi

# Prints the top-level Docker manifest.json member names of an archive (tar member names that are manifest.json
# after removing './' prefixes), one per line; fails when the archive cannot be listed
docker_archive_manifest_members() {
  local members
  members="$(tar -tf "$1" 2>/dev/null)" || return 1
  grep -xE '(\./+)*manifest\.json' <<<"$members" || true
}

# Prints the Docker manifest.json of an archive that has exactly one manifest.json member; fails otherwise
docker_archive_manifest() {
  local file="$1" member
  member="$(docker_archive_manifest_members "$file")" || return 1
  [[ -n "$member" && "$member" != *$'\n'* ]] || return 1
  tar -xOf "$file" "$member" 2>/dev/null
}

# Prints the number of entries of the Docker manifest.json of an archive, or 0 when the archive has no manifest.json.
# Fails with an error when the archive cannot be listed, or when a manifest.json exists but cannot be used: it is present
# more than once, jq (a native Linux K2s host prerequisite, see k2s_require_host) is missing, it cannot be read, or it is
# not a non-empty JSON array of objects. Falling back to the single-image import in these cases would hide that a
# multi-image archive is not imported completely.
docker_archive_entry_count() {
  local file="$1" manifest_members manifest count
  if ! manifest_members="$(docker_archive_manifest_members "$file")"; then
    k2s_log ERROR "$file could not be read as a tar archive; the archive is not imported"
    return 1
  fi
  if [[ -z "$manifest_members" ]]; then
    echo 0
    return 0
  fi
  if [[ "$manifest_members" == *$'\n'* ]]; then
    k2s_log ERROR "$file contains more than one manifest.json; the archive is not imported"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    k2s_log ERROR "jq is required to read the Docker manifest.json of $file but is not installed; install the 'jq' package (a K2s Linux host prerequisite) and import again"
    return 1
  fi
  if ! manifest="$(docker_archive_manifest "$file")"; then
    k2s_log ERROR "The Docker manifest.json of $file could not be read; the archive is not imported"
    return 1
  fi
  if ! count="$(jq -er 'if type == "array" and length > 0 and all(.[]; type == "object") then length else error("not a non-empty array of objects") end' <<<"$manifest" 2>/dev/null)" ||
    [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
    k2s_log ERROR "The Docker manifest.json of $file is empty, malformed or not a list of image entries; the archive is not imported"
    return 1
  fi
  echo "$count"
}

# Imports every entry of a multi-image Docker archive with its own Buildah selector ('@<index>' of manifest.json);
# the entry's RepoTags are applied by Buildah. Successfully imported entries are kept when another entry fails.
import_docker_archive_entries() {
  local file="$1" count="$2" manifest i tags pull_out duplicate
  local -a failed=()
  manifest="$(docker_archive_manifest "$file")"
  k2s_log INFO "Docker archive $file contains $count images; importing each entry"

  while IFS= read -r duplicate; do
    if [[ -n "$duplicate" ]]; then
      k2s_log WARN "Tag '$duplicate' is used by more than one archive entry of $file; it will refer to the last of them"
    fi
  done < <(jq -r '[.[] | (.RepoTags // [])[]] | group_by(.) | map(select(length > 1) | .[0]) | .[]' <<<"$manifest" 2>/dev/null || true)

  for ((i = 0; i < count; i++)); do
    tags="$(jq -r --argjson i "$i" '(.[$i].RepoTags // []) | join(", ")' <<<"$manifest" 2>/dev/null || true)"
    if pull_out="$(buildah pull "docker-archive:$file:@$i" 2>&1)"; then
      k2s_log INFO "Imported archive entry @$i (${tags:-<untagged>}) from $file"
    else
      k2s_log ERROR "Failed to import archive entry @$i (${tags:-<untagged>}) from $file: $pull_out"
      failed+=("@$i")
    fi
  done

  if ((${#failed[@]} > 0)); then
    k2s_log ERROR "Imported $((count - ${#failed[@]})) of $count images from $file; failed entries: ${failed[*]}. Successfully imported images are kept."
    return 1
  fi
  k2s_log INFO "Successfully imported all $count images from Docker archive: $file"
}

import_single_tar() {
  local file="$1"
  k2s_log INFO "Importing container image from $file"
  if command -v buildah >/dev/null 2>&1; then
    if [[ "$file" == *:* ]]; then
      # ':' separates the path from the image in Buildah transport references; containers/image rejects such paths
      k2s_log ERROR "The archive path $file contains ':', which Buildah does not support in archive paths; rename or move the archive and import again"
      return 1
    fi
    local entry_count
    entry_count="$(docker_archive_entry_count "$file")" || return 1
    if ((entry_count >= 2)); then
      import_docker_archive_entries "$file" "$entry_count" || return 1
      return 0
    fi

    local pull_out=""
    if pull_out="$(buildah pull "oci-archive:$file" 2>&1)"; then
      k2s_log INFO "Successfully imported OCI archive: $file"
    elif pull_out="$(buildah pull "docker-archive:$file" 2>&1)"; then
      k2s_log INFO "Successfully imported Docker archive: $file"
    else
      k2s_log ERROR "Failed to import image from $file: $pull_out"
      return 1
    fi

    local imported_id=""
    imported_id="$(echo "$pull_out" | grep -oE '[0-9a-f]{12,64}' | tail -n 1 || true)"
    if [[ -z "$imported_id" ]]; then
      imported_id="$(echo "$pull_out" | tail -n 1 | tr -d '\r\n' || true)"
    fi

    # Check if the imported image has any non-<none> names in buildah
    local current_names=""
    if [[ -n "$imported_id" ]]; then
      current_names="$(buildah images --json "$imported_id" 2>/dev/null | jq -r '.[0].names[]? // empty' 2>/dev/null | grep -v '<none>' || true)"
    fi

    # If the image was imported without tags (names appears as <none>), resolve and apply the tag
    if [[ -z "$current_names" && -n "$imported_id" ]]; then
      local tag_to_apply=""

      # 1. Try reading OCI archive index.json annotation
      tag_to_apply="$(tar -xOf "$file" index.json 2>/dev/null | jq -r '.manifests[0].annotations["org.opencontainers.image.ref.name"] // empty' 2>/dev/null || true)"

      if [[ -z "$tag_to_apply" || "$tag_to_apply" == "null" ]]; then
        # 2. Try reading Docker manifest.json RepoTags
        tag_to_apply="$(tar -xOf "$file" manifest.json 2>/dev/null | jq -r '.[0].RepoTags[0] // empty' 2>/dev/null || true)"
      fi

      if [[ -z "$tag_to_apply" || "$tag_to_apply" == "null" ]]; then
        # 3. Derive from archive filename if it is not a hexadecimal hash
        local base_name="$(basename "$file" .tar)"
        base_name="${base_name%_linux}"
        if [[ ! "$base_name" =~ ^[0-9a-f]{12,64}$ ]]; then
          if [[ "$base_name" == *":"* ]]; then
            tag_to_apply="$base_name"
          else
            tag_to_apply="${base_name}:latest"
          fi
        fi
      fi

      if [[ -n "$tag_to_apply" && "$tag_to_apply" != "<none>" && "$tag_to_apply" != "null" ]]; then
        k2s_log INFO "Tagging imported image $imported_id as $tag_to_apply"
        buildah tag "$imported_id" "$tag_to_apply" || true
      fi
    fi
  elif command -v ctr >/dev/null 2>&1; then
    k2s_run ctr -n k8s.io images import "$file"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io load -i "$file"
  else
    k2s_log ERROR "No container tool found to import image. Please install buildah or containerd (ctr)."
    exit 127
  fi
}

if [[ -n "$tar_path" ]]; then
  k2s_require_file "$tar_path" || exit 1
  import_single_tar "$tar_path"
fi

if [[ -n "$dir_path" ]]; then
  k2s_require_directory "$dir_path" || exit 1
  k2s_log INFO "Importing container images from directory $dir_path"
  shopt -s nullglob
  tar_files=("$dir_path"/*.tar)
  shopt -u nullglob
  if [[ ${#tar_files[@]} -eq 0 ]]; then
    k2s_log WARN "No .tar files found in $dir_path"
  else
    for file in "${tar_files[@]}"; do
      import_single_tar "$file"
    done
  fi
fi
