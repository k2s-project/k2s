#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Imports the addons of an OCI artifact written by 'k2s addons export' on a native Linux host,
# like addons/Import.ps1 does on Windows hosts. The addon files are staged into the addons directory
# of the installation, the Linux images are loaded into the container runtime of the local host, or of
# exactly the Linux nodes selected with --nodes, and the debian and linux packages are put where the
# addons expect them for an offline enable. Windows images and Windows packages of the artifact are
# skipped. Addons are not enabled; that is 'k2s addons enable'.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"
# Names, digests and media types are compared byte-wise, independent of the locale of the host.
export LC_ALL=C

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/infra/ssh.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/cluster/addon-oci.sh"

# The Go wrapper maps this exit code to a not-supported error.
readonly ADDON_IMPORT_EXIT_NOT_SUPPORTED=3
readonly ADDON_IMPORT_MANIFEST='addon.manifest.yaml'
readonly ADDON_IMPORT_SSH_PORT=22
readonly ADDON_IMPORT_PATH_SEGMENT_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly ADDON_IMPORT_NODE_NAME_PATTERN='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'
readonly ADDON_IMPORT_PARENT_SEGMENT_PATTERN='(^|/)\.\.(/|$)'

# The jq functions of the omit handling, a port of New-AddonImagePrunePlan of addons/imageprune.module.psm1.
# They build on ADDON_OCI_JQ_DEFS of addon-oci.sh.
read -r -d '' ADDON_IMPORT_JQ_DEFS <<'JQ' || true
# Reduces an image reference to registry and repository, so that an omit declaration still matches an
# artifact that carries another version of the image.
def comparable_key:
  (trimspace | split("@") | .[0] // "") as $reference
  | (($reference | rindex("/")) // -1) as $slash
  | $reference[$slash + 1:] as $last
  | (($last | rindex(":")) // -1) as $tag
  | (if $tag >= 0 then $reference[:$slash + 1] + $last[:$tag] else $reference end)
  | trimspace
  | if . == "" then "" else sanitize end;

# Derives the comparable key of an image archive name by dropping the version segment.
def identity_key:
  ((trimspace | split("/") | last) // "") as $name
  | if ($name | endswith(".tar")) | not then ""
    else ($name[:-4] | if startswith("windows_") then .[8:] else . end) as $base
      | (($base | rindex("_")) // -1) as $separator
      | if $separator > 0 then $base[:$separator] else "" end
    end;

# An omit value is '<flag>', '<addon>:<flag>' or '<addon>/<implementation>:<flag>'.
def parse_tokens:
  [ .[] | trimspace as $raw
    | if ($raw | contains(":")) then
        ($raw | index(":")) as $colon
        | ($raw[:$colon] | trimspace) as $scope
        | (if ($scope | contains("/")) then
             ($scope | index("/")) as $slash
             | {addon: ($scope[:$slash] | trimspace), implementation: ($scope[$slash + 1:] | trimspace)}
           else {addon: $scope, implementation: ""} end)
        + {raw: $raw, flag: ($raw[$colon + 1:] | trimspace)}
      else {raw: $raw, flag: $raw, addon: "", implementation: ""} end
    | select(.flag != "") ];

def matching_token($tokens; $addon; $implementation; $flag):
  first($tokens[]
    | select((.flag | lc) == ($flag | lc)
      and (.addon == "" or (.addon | lc) == ($addon | lc))
      and (.implementation == "" or (.implementation | lc) == ($implementation | lc)))) // null;

# The enable flags of an addon manifest that declare omittedImages, or null.
def omit_flags($implementation):
  try (
    (.spec.implementations // null) as $implementations
    | if ($implementations | type) != "array" or ($implementations | length) == 0 then null
      else (first($implementations[] | select($implementation != "" and .name == $implementation)) // $implementations[0]) as $selected
        | [ ($selected.commands.enable.cli.flags // [])[]
            | select(type == "object" and .omittedImages != null)
            | {name: ((.name // "") | tostring),
               fromFiles: [(.omittedImages.fromFiles // [])[] | tostring],
               explicit: [(.omittedImages.explicit // [])[] | tostring]} ]
        | if length > 0 then . else null end
      end
  ) catch null;

# With A = images an addon carries, O = images of the requested omit options and K = images of its omit
# options that were not requested, an addon still requires R = A - (O - K). An image is skipped only when
# no imported addon requires it.
def prune_plan:
  (.omit | parse_tokens) as $tokens
  | (reduce .entries[] as $entry (
      {all: [], required: {}, omitted: {}, matched: {}, fileToImages: {}, omittedBy: {}, requiredBy: {}, warnings: [], available: []};
      $entry.key as $key
      | (reduce $entry.files[] as $file ({}; ($file | identity_key) as $identity
          | if $identity != "" then append_unique($identity; $file) else . end)) as $byIdentity
      | .all = (.all + $entry.files | unique_in_order)
      | (reduce $entry.flags[] as $flag ({state: ., omitted: {}, kept: {}};
          .state.available += [$key + ":" + $flag.name]
          | if ($flag.images | length) == 0 then
              .state.warnings += ["[Prune] Omit option '\($flag.name)' of '\($key)' declares 'omittedImages' but no image reference could be resolved - not pruning for this option."]
            else
              # An exact match comes first; the identity fallback tolerates another version in the artifact.
              (reduce $flag.images[] as $image ({files: [], pairs: []};
                ($image | archive_name) as $archive
                | (if ($entry.files | any(.[]; . == $archive)) then [$archive]
                   else (($image | comparable_key) as $identity | if $identity != "" then ($byIdentity[$identity] // []) else [] end) end) as $matched
                | reduce $matched[] as $file (.;
                    (if any(.files[]; . == $file) then . else .files += [$file] end) | .pairs += [[$file, $image]]))) as $flagFiles
              | reduce $flagFiles.pairs[] as $pair (.; .state.fileToImages |= append_unique($pair[0]; $pair[1]))
              | matching_token($tokens; $entry.name; $entry.implementation; $flag.name) as $token
              | if $token != null then
                  .state.matched[$token.raw] = true
                  | reduce $flagFiles.files[] as $file (.;
                      .omitted[$file] = true
                      | .state.omittedBy |= append_unique($file; "\($key) (--omit \($flag.name))"))
                else
                  reduce $flagFiles.files[] as $file (.; .kept[$file] = true)
                end
            end)) as $result
      | $result.state
      | reduce $entry.files[] as $file (.;
          if ($result.omitted[$file] | not) or $result.kept[$file] then
            .required[$file] = true | .requiredBy |= append_unique($file; $key)
          else . end)
      | .omitted += $result.omitted
    )) as $state
  # The guard keeps an archive that two different images map onto after name sanitization.
  | (reduce ($state.all | sort)[] as $file ({prunable: {}, warnings: []};
      if $state.required[$file] then .
      else ([($state.fileToImages[$file] // [])[] | comparable_key | select(. != "")] | unique) as $identities
        | if ($identities | length) > 1 then
            .warnings += ["[Prune] '\($file)' maps to more than one image reference (\($state.fileToImages[$file] | join(", "))) - keeping it to stay on the safe side."]
          else .prunable[$file] = true end
      end)) as $guard
  | [ $state.omitted | keys[] as $file
      | {image: (if (($state.fileToImages[$file] // []) | length) > 0 then $state.fileToImages[$file] | join(", ") else $file end),
         omittedBy: ($state.omittedBy[$file] // []), requiredBy: ($state.requiredBy[$file] // []),
         pruned: ($guard.prunable[$file] == true)} ] as $decisions
  | {
      skip: (reduce .entries[] as $entry ({}; .[$entry.key] = [$entry.files[] | select($guard.prunable[.] == true)])),
      warnings: ($state.warnings + $guard.warnings),
      applied: [$tokens[] | select($state.matched[.raw]) | .raw],
      unmatched: [$tokens[] | select($state.matched[.raw] | not) | .raw],
      available: ($state.available | unique),
      pruned: [$decisions[] | select(.pruned)],
      retained: [$decisions[] | select(.pruned | not)]
    };

# The lines that report the decisions of a plan before any image is imported.
def plan_log:
  .warnings[],
  (.available as $available | .unmatched[] | (
    "[Prune] WARNING: '--omit \(.)' did not match any addon selected for import - ignoring it.",
    if ($available | length) > 0 then "[Prune] Omit options available in this artifact: \($available | join(", "))"
    else "[Prune] This artifact does not declare any omit options." end)),
  (if (.applied | length) > 0 then "[Prune] Applied omit options: \(.applied | join(", "))" else empty end),
  (.pruned[] | ("[Prune] SKIPPED  \(.image)", "[Prune]          omitted by : \(.omittedBy | join(", "))")),
  (.retained[] | ("[Prune] RETAINED \(.image)", "[Prune]          omitted by : \(.omittedBy | join(", "))",
    "[Prune]          required by: \(.requiredBy | join(", "))"));

# The lines that list the images that were not imported once the import has finished.
def plan_summary:
  if (.pruned | length) == 0 then empty
  else "Omit options were applied: \(.pruned | length) image(s) were not imported.",
    (.pruned[] | "  - \(.image)"),
    "Enable the affected addons with the matching omit options, or re-run the import without",
    "the omit options to add these images later. The OCI artifact itself is unchanged."
  end;
JQ

# Runs a filter with the jq functions above: addon_import_jq <filter> [jq options and arguments...].
addon_import_jq() {
  local filter="$1"
  shift
  jq "$ADDON_OCI_JQ_DEFS
$ADDON_IMPORT_JQ_DEFS
$filter" "$@"
}

# Progress is always shown, like the console output of addons/Import.ps1.
addon_import_log() {
  k2s_log INFO "$*"
  k2s_show_logs || printf '%s\n' "$*"
}

# For functions whose stdout is their result: k2s_log INFO would write to stdout when logs are shown.
addon_import_log_to_file() {
  printf '%s [INFO] %s\n' "$(date -Is)" "$*" >>"$K2S_LOG_FILE"
}

# The last error line is the reason the Go wrapper reports, so every failure prints exactly one.
addon_import_error() {
  k2s_log ERROR "${addon_import_context:+$addon_import_context: }$*"
}


addon_import_usage() {
  cat <<'USAGE'
Usage: Import-Addon.sh -f <artifact.oci.tar> [-c <setup-config-dir>] [-a <addon>]... [-o <omit>]...
                       [-n <node>[,<node>...]] [-k <ssh-private-key>]

  -f, --file        OCI artifact written by 'k2s addons export'
  -c, --config-dir  K2s setup config directory with setup.json and cluster.json (default: /var/lib/k2s)
  -a, --addon       addon to import ('ingress', 'ingress nginx' or 'ingress-nginx'); repeatable, default: all
  -o, --omit        omit option ('<flag>', '<addon>:<flag>' or '<addon>/<implementation>:<flag>'); repeatable
  -n, --nodes       Linux nodes that receive the images (default: the local host)
  -k, --ssh-key     SSH private key for additional Linux nodes (default: the K2s key pair)
USAGE
}

# '<name>' or '<name>/<implementation>'.
addon_import_key() {
  local name="$1" implementation="$2"
  if [[ -z $implementation || $implementation == "$name" ]]; then
    printf '%s\n' "$name"
  else
    printf '%s/%s\n' "$name" "$implementation"
  fi
}

# Prints '<addon directory>\t<implementation subdirectory>'; the subdirectory is empty for an addon
# with a single implementation. Both originate from the artifact and must be plain names.
addon_import_resolve_path() {
  local name="$1" implementation="$2"
  local -a segments=()
  # Older artifacts carry the implementation as last segment of the name ('storage ceph').
  read -r -a segments <<<"$name" || true
  if ((${#segments[@]} > 1)) && [[ ${segments[-1]} == "$implementation" ]]; then
    name="${segments[*]:0:${#segments[@]}-1}"
  fi
  if [[ $implementation == "$name" ]]; then
    implementation=""
  fi

  if [[ ! $name =~ $ADDON_IMPORT_PATH_SEGMENT_PATTERN ]]; then
    addon_import_error "addon name '$name' is not a valid directory name"
    return 1
  fi
  if [[ -n $implementation && ! $implementation =~ $ADDON_IMPORT_PATH_SEGMENT_PATTERN ]]; then
    addon_import_error "addon implementation '$implementation' is not a valid directory name"
    return 1
  fi
  printf '%s\t%s\n' "$name" "$implementation"
}

addon_import_local_node_name() {
  local name
  name="$(uname -n 2>/dev/null || true)"
  name="${name,,}"
  printf '%s\n' "${name:-linux}"
}

addon_import_is_node_ready() {
  local status
  status="$(kubectl get node "$1" -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || return 1
  [[ ${status//[[:space:]]/} == True ]]
}

# Fills target_names, target_ips and target_users with the nodes that receive the images: the local
# host without a node selector, otherwise exactly the selected nodes. An additional Linux worker must be
# listed in the cluster descriptor (cluster.json) with IP address and user, like Resolve-ImageNode of the
# Windows image scripts. Every node is checked before the import changes anything.
addon_import_resolve_targets() {
  local selector="$1" local_name control_plane node descriptor os ip user i duplicate
  local -a local_names=() requested=()
  target_names=() target_ips=() target_users=()

  local_name="$(addon_import_local_node_name)"
  local_names=("$local_name")
  if [[ -f "$config_dir/setup.json" ]]; then
    control_plane="$(jq -r '.ControlPlaneNodeHostname // empty | strings' "$config_dir/setup.json" 2>/dev/null || true)"
    if [[ -n $control_plane ]]; then
      local_names+=("${control_plane,,}")
    fi
  fi
  local_names+=("linux")

  IFS=',' read -r -a requested <<<"$selector" || true
  for node in "${requested[@]}"; do
    node="${node#"${node%%[![:space:]]*}"}"
    node="${node%"${node##*[![:space:]]}"}"
    node="${node,,}"
    [[ -z $node ]] && continue

    ip="" user=""
    if [[ " ${local_names[*]} " == *" $node "* ]]; then
      # The readiness of the local host is checked under its actual node name, not an alias.
      if ! addon_import_is_node_ready "$local_name"; then
        addon_import_error "node '$local_name' is not in Ready state - run 'kubectl get nodes' to check node status"
        return 1
      fi
      node="$local_name"
    else
      if [[ ! $node =~ $ADDON_IMPORT_NODE_NAME_PATTERN ]]; then
        addon_import_error "'$node' is not a valid node name - run 'kubectl get nodes' to list available nodes"
        return 1
      fi

      descriptor=""
      if [[ -f "$config_dir/cluster.json" ]]; then
        if ! descriptor="$(jq -c --arg node "$node" '[(.nodes // [])[] | select(((.Name // "") | ascii_downcase) == $node)] | last // empty' "$config_dir/cluster.json" 2>/dev/null)"; then
          addon_import_error "error occurred while loading cluster config file $config_dir/cluster.json"
          return 1
        fi
      fi
      if [[ -z $descriptor ]]; then
        addon_import_error "node '$node' was not found in the cluster - run 'kubectl get nodes' to list available nodes"
        return 1
      fi

      os="$(jq -r '(.OS // "") | ascii_downcase' <<<"$descriptor")"
      case "$os" in
        linux) ;;
        windows)
          k2s_log ERROR "node '$node' is a Windows node; Windows images cannot be imported from a Linux host"
          exit "$ADDON_IMPORT_EXIT_NOT_SUPPORTED"
          ;;
        *)
          addon_import_error "node '$node' has unsupported OS '$(jq -r '.OS // ""' <<<"$descriptor")' in the cluster descriptor"
          return 1
          ;;
      esac

      ip="$(jq -r '.IpAddress // ""' <<<"$descriptor")"
      user="$(jq -r '.Username // ""' <<<"$descriptor")"
      if [[ -z $ip || -z $user ]]; then
        addon_import_error "node '$node' is a Linux worker but IpAddress or Username is missing in the cluster descriptor"
        return 1
      fi
      # Both end up on the ssh/scp command line and must not be taken for options.
      if [[ ! $ip =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ || ! $user =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        addon_import_error "node '$node' has an invalid IpAddress or Username in the cluster descriptor"
        return 1
      fi
      if ! addon_import_is_node_ready "$node"; then
        addon_import_error "node '$node' is not in Ready state - run 'kubectl get nodes' to check node status"
        return 1
      fi
    fi

    duplicate=false
    for i in "${!target_names[@]}"; do
      if [[ ${target_names[i]} == "$node" && ${target_ips[i]} == "$ip" && ${target_users[i]} == "$user" ]]; then
        duplicate=true
      fi
    done
    if [[ $duplicate == false ]]; then
      target_names+=("$node") target_ips+=("$ip") target_users+=("$user")
    fi
  done

  if ((${#target_names[@]} == 0)); then
    target_names=("$local_name") target_ips=("") target_users=("")
  fi
}

# Fails unless the archive entry stays inside of the extraction directory.
addon_import_check_entry() {
  local entry="${1//\\//}"
  while [[ $entry == ./* ]]; do entry="${entry#./}"; done
  if [[ $entry == /* || $entry =~ $ADDON_IMPORT_PARENT_SEGMENT_PATTERN ]]; then
    addon_import_error "archive entry '$1' is outside of the extraction directory"
    return 1
  fi
}

# Extracts the directories and regular files of a tar archive into the destination. Entries pointing
# outside of the destination are rejected before anything is written; links and special files are never
# part of an exported addon and are dropped.
addon_import_extract() {
  local archive="$1" destination="$2" compression="$3" entries entry stage
  local -a options=()
  if [[ $compression == gzip ]]; then
    options=(-z)
  fi

  if ! entries="$(tar "${options[@]}" -tf "$archive" 2>/dev/null)"; then
    addon_import_error "reading archive $archive failed"
    return 1
  fi
  while IFS= read -r entry; do
    [[ -z $entry ]] && continue
    addon_import_check_entry "$entry" || return 1
  done <<<"$entries"

  stage="$(mktemp -d "$work_dir/extract-XXXXXX")" || return 1
  if ! tar "${options[@]}" -xf "$archive" -C "$stage" --no-same-owner --no-same-permissions 2>/dev/null; then
    addon_import_error "extracting archive $archive failed"
    return 1
  fi
  find "$stage" -mindepth 1 ! -type f ! -type d -delete || return 1

  if [[ ! -e $destination ]]; then
    mkdir -p "$(dirname "$destination")" || return 1
    mv "$stage" "$destination" || return 1
  else
    cp -R "$stage/." "$destination/" || return 1
    rm -rf "$stage"
  fi
}

# Prints the path of a blob after checking its content against the digest.
addon_import_verified_blob() {
  local digest="$1" blob computed
  if [[ ! $digest =~ ^sha256:[a-f0-9]{64}$ ]]; then
    addon_import_error "invalid digest format '$digest' (expected sha256:<64 lowercase hex chars>)"
    return 1
  fi
  blob="$blobs_dir/${digest#sha256:}"
  if [[ ! -f $blob ]]; then
    addon_import_error "blob not found for digest $digest"
    return 1
  fi
  computed="$(sha256sum "$blob" | cut -d' ' -f1)" || return 1
  if [[ "sha256:$computed" != "$digest" ]]; then
    addon_import_error "blob integrity check failed for digest $digest (computed sha256:$computed)"
    return 1
  fi
  printf '%s\n' "$blob"
}

# Fills exported_names, exported_implementations and exported_manifests with the addons of the artifact.
# The manifest annotations override the index annotations one by one; the name is normalized so that
# legacy identities ('storage ceph') can be selected like current ones.
addon_import_read_layout() {
  local layout="$1" version schema entry digest name implementation manifest_name manifest_implementation manifest resolved
  exported_names=() exported_implementations=() exported_manifests=()

  if ! version="$(jq -er '.imageLayoutVersion | strings' "$layout/oci-layout" 2>/dev/null)"; then
    addon_import_error "invalid OCI artifact format: oci-layout is missing or invalid"
    return 1
  fi
  if [[ $version != "$ADDON_OCI_LAYOUT_VERSION" ]]; then
    addon_import_error "unsupported OCI image layout version '$version' (expected '$ADDON_OCI_LAYOUT_VERSION')"
    return 1
  fi

  blobs_dir="$layout/blobs/sha256"
  if [[ ! -d $blobs_dir ]]; then
    addon_import_error "invalid OCI artifact format: blobs/sha256 directory not found"
    return 1
  fi

  if ! schema="$(jq -r '.schemaVersion // 0' "$layout/index.json" 2>/dev/null)"; then
    addon_import_error "invalid OCI artifact format: index.json is missing or invalid"
    return 1
  fi
  if [[ $schema != 2 ]]; then
    addon_import_error "invalid OCI image index: schemaVersion must be 2, got $schema"
    return 1
  fi

  while IFS= read -r entry; do
    digest="$(jq -r '.digest // "" | tostring' <<<"$entry")"
    name="$(jq -r --arg key "$ADDON_OCI_NAME_ANNOTATION" '.annotations[$key]? // "" | tostring' <<<"$entry")"
    implementation="$(jq -r --arg key "$ADDON_OCI_IMPL_ANNOTATION" '.annotations[$key]? // "" | tostring' <<<"$entry")"

    manifest="$(addon_import_verified_blob "$digest")" || return 1
    if ! jq -e 'type == "object"' "$manifest" >/dev/null 2>&1; then
      addon_import_error "invalid addon manifest $digest: not a JSON object"
      return 1
    fi
    manifest_name="$(jq -r --arg key "$ADDON_OCI_NAME_ANNOTATION" '.annotations[$key]? // "" | tostring' "$manifest")"
    manifest_implementation="$(jq -r --arg key "$ADDON_OCI_IMPL_ANNOTATION" '.annotations[$key]? // "" | tostring' "$manifest")"
    if [[ -n $manifest_name ]]; then
      name="$manifest_name"
    fi
    if [[ -n $manifest_implementation ]]; then
      implementation="$manifest_implementation"
    fi
    if [[ -z $name ]]; then
      addon_import_error "invalid OCI artifact format: manifest $digest does not name an addon"
      return 1
    fi

    resolved="$(addon_import_resolve_path "$name" "$implementation")" || return 1
    exported_names+=("${resolved%%$'\t'*}")
    exported_implementations+=("$implementation")
    exported_manifests+=("$manifest")
  done < <(jq -c '(.manifests // [])[]' "$layout/index.json")

  if ((${#exported_names[@]} == 0)); then
    addon_import_error "invalid OCI artifact format: no addons found"
    return 1
  fi
}

# Fills selected_indices with the exported addons matching the requests. A request is a base addon
# ('ingress'), a quoted implementation ('ingress traefik'), two separate tokens ('ingress', 'traefik') or
# the flattened form ('ingress-traefik'). Without requests every addon is selected.
addon_import_select() {
  local -a requests=("$@") found=() parts=() matches=()
  local i j request requested_name requested_implementation next sorted
  selected_indices=()

  if ((${#requests[@]} == 0)); then
    selected_indices=("${!exported_names[@]}")
    return 0
  fi

  for ((i = 0; i < ${#requests[@]}; i++)); do
    request="${requests[i]}"
    requested_name="$request" requested_implementation=""
    parts=()
    read -r -a parts <<<"$request" || true
    found=()

    if ((${#parts[@]} > 1)); then
      requested_name="${parts[0]}"
      requested_implementation="$(addon_oci_join - "${parts[@]:1}")"
    elif ((i + 1 < ${#requests[@]})); then
      next="${requests[i + 1],,}"
      for j in "${!exported_names[@]}"; do
        if [[ ${exported_names[j],,} == "${request,,}" && ${exported_implementations[j],,} == "$next" ]]; then
          found+=("$j")
        fi
      done
      if ((${#found[@]} > 0)); then
        matches+=("${found[@]}")
        i=$((i + 1))
        continue
      fi
    fi

    for j in "${!exported_names[@]}"; do
      if [[ ${exported_names[j],,} == "${requested_name,,}" ]] &&
        [[ -z $requested_implementation || ${exported_implementations[j],,} == "${requested_implementation,,}" ]]; then
        found+=("$j")
      fi
    done
    if ((${#found[@]} == 0)) && [[ -z $requested_implementation ]]; then
      for j in "${!exported_names[@]}"; do
        if [[ "${exported_names[j],,}-${exported_implementations[j],,}" == "${requested_name,,}" ]]; then
          found+=("$j")
        fi
      done
    fi
    if ((${#found[@]} == 0)); then
      addon_import_error "addon '$request' not found in OCI artifact for import"
      return 1
    fi
    matches+=("${found[@]}")
  done

  # Sorted by key, keeping the first addon of each key.
  sorted="$(for j in "${matches[@]}"; do
    printf '%s\t%s\n' "$(addon_import_key "${exported_names[j]}" "${exported_implementations[j]}")" "$j"
  done | sort -s -t $'\t' -k1,1 | awk -F '\t' '!seen[$1]++ { print $2 }')"
  while IFS= read -r j; do
    [[ -n $j ]] && selected_indices+=("$j")
  done <<<"$sorted"
  return 0
}

# Appends the implementations of the imported manifest that the installed manifest does not know yet.
# Existing implementations stay untouched.
addon_import_merge_implementations() {
  local installed="$1" imported="$2" name
  local -a known=() added=()

  if ! yq -e '.spec.implementations | tag == "!!seq"' "$installed" >/dev/null 2>&1 ||
    ! yq -e '.spec.implementations | tag == "!!seq"' "$imported" >/dev/null 2>&1; then
    addon_import_error "merging $ADDON_IMPORT_MANIFEST: spec.implementations is missing"
    return 1
  fi

  mapfile -t known < <(yq '.spec.implementations[] | .name // ""' "$installed")
  while IFS= read -r name; do
    [[ -z $name || $name == null ]] && continue
    [[ " ${known[*]} " == *" $name "* ]] && continue
    added+=("$name")
  done < <(yq '.spec.implementations[] | .name // ""' "$imported")
  if ((${#added[@]} == 0)); then
    return 0
  fi

  for name in "${added[@]}"; do
    if ! IMPORTED="$imported" NAME="$name" yq -i '.spec.implementations += [load(strenv(IMPORTED)).spec.implementations[] | select(.name == strenv(NAME))]' "$installed"; then
      addon_import_error "merging $ADDON_IMPORT_MANIFEST failed"
      return 1
    fi
  done
  addon_import_log "Added implementations to $installed: $(addon_oci_join ', ' "${added[@]}")"
}

# Installs the content of the config layer: the addon manifest goes to the addon directory, all other
# configuration files to the implementation directory.
addon_import_stage_config() {
  local config="$1" destination="$2" implementation_path="$3" multi_implementation="$4" item
  local imported="$config/$ADDON_IMPORT_MANIFEST" installed="$destination/$ADDON_IMPORT_MANIFEST"

  if [[ ! -f $imported ]]; then
    addon_import_log "Warning: $ADDON_IMPORT_MANIFEST not found in the artifact for '$(basename "$destination")'"
  elif [[ -f $installed && $multi_implementation == true ]]; then
    addon_import_merge_implementations "$installed" "$imported" || return 1
  else
    install -m 0644 "$imported" "$installed" || return 1
  fi

  while IFS= read -r -d '' item; do
    [[ $item == "$imported" ]] && continue
    cp -R "$item" "$implementation_path/" || return 1
  done < <(find "$config" -mindepth 1 -maxdepth 1 -print0)
}

# Prints the enable flags with omittedImages as JSON. The manifest of the artifact is preferred; the
# installed manifest is the fallback, so that older artifacts can still be imported with --omit.
addon_import_omit_flags() {
  local implementation="$1" source manifest flags
  shift
  for source in "$@"; do
    [[ -n $source && -f $source ]] || continue
    manifest="$(yq -o=json 'select(document_index == 0)' "$source" 2>/dev/null)" || continue
    flags="$(addon_import_jq 'omit_flags($implementation)' -c --arg implementation "$implementation" <<<"$manifest" 2>/dev/null)" || continue
    if [[ -n $flags && $flags != null ]]; then
      addon_import_log_to_file "[Prune] Using omit options declared by $source"
      printf '%s\n' "$flags"
      return 0
    fi
  done
  printf '[]\n'
}

# Prints the images a flag's omittedImages block covers as JSON; relative files are resolved against
# the implementation directory.
addon_import_omitted_images() {
  local flag="$1" implementation_path="$2" file
  local -a images=()

  while IFS= read -r file; do
    [[ -z $file ]] && continue
    [[ $file == /* ]] || file="$implementation_path/$file"
    if [[ ! -f $file ]]; then
      addon_import_log_to_file "[Prune] WARNING: YAML file not found: $file"
      continue
    fi
    mapfile -t -O "${#images[@]}" images < <(addon_import_jq 'images_from_yaml[]' -rRs <"$file")
  done < <(jq -r '.fromFiles[]' <<<"$flag")
  mapfile -t -O "${#images[@]}" images < <(jq -r '.explicit[]' <<<"$flag")

  addon_import_jq '$ARGS.positional | clean_images' -nc --args "${images[@]}"
}

# Prints the names of the per-image archives of an images layer without unpacking them.
addon_import_list_image_archives() {
  local layer="$1" entry name
  local -a names=()
  while IFS= read -r entry; do
    name="${entry//\\//}"
    [[ $name == */ ]] && continue
    name="${name##*/}"
    if [[ $name == *.tar && " ${names[*]} " != *" $name "* ]]; then
      names+=("$name")
    fi
  done < <(tar -tf "$layer")
  if ((${#names[@]} > 0)); then
    printf '%s\n' "${names[@]}"
  fi
}

# Stages the files of one addon and records the entry for the image import.
addon_import_stage_addon() {
  local index="$1"
  local name="${exported_names[index]}" implementation="${exported_implementations[index]}" manifest="${exported_manifests[index]}"
  local key resolved base implementation_dir destination implementation_path config media_type digest blob kind
  local images_layer="" packages_dir="" artifact_manifest="" installed_copy="" multi_implementation=false flags flag images entry_flags="[]" files="[]"

  key="$(addon_import_key "$name" "$implementation")"
  addon_import_context="importing addon '$key'"
  resolved="$(addon_import_resolve_path "$name" "$implementation")" || return 1
  base="${resolved%%$'\t'*}" implementation_dir="${resolved#*$'\t'}"

  destination="$K2S_INSTALL_DIR/addons/$base"
  implementation_path="$destination${implementation_dir:+/$implementation_dir}"
  mkdir -p "$implementation_path" || return 1
  config="$(mktemp -d "$work_dir/config-XXXXXX")" || return 1

  while IFS=$'\t' read -r media_type digest; do
    [[ $media_type == "$ADDON_OCI_EMPTY_MEDIA_TYPE" ]] && continue
    # Order matters: it mirrors the first-match-wins media type matching of addons/Import.ps1.
    case "$media_type" in
      *configfiles*) kind=config ;;
      *manifests*) kind=manifests ;;
      *helm.chart*) kind=charts ;;
      *shared-scripts*) kind=shared-scripts ;;
      *scripts*) kind=scripts ;;
      *images-windows*)
        addon_import_log "Skipping Windows images of '$key': importing them is not supported on Linux hosts"
        continue
        ;;
      *image.layer*) kind=linux-images ;;
      *packages*) kind=packages ;;
      *) continue ;;
    esac

    blob="$(addon_import_verified_blob "$digest")" || return 1
    addon_import_context="importing addon '$key': extracting layer $digest"
    case "$kind" in
      config) addon_import_extract "$blob" "$config" gzip || return 1 ;;
      manifests) addon_import_extract "$blob" "$implementation_path/manifests" gzip || return 1 ;;
      charts) addon_import_extract "$blob" "$implementation_path/manifests/chart" gzip || return 1 ;;
      scripts) addon_import_extract "$blob" "$implementation_path" gzip || return 1 ;;
      shared-scripts) addon_import_extract "$blob" "$destination" gzip || return 1 ;;
      linux-images) images_layer="$blob" ;;
      packages)
        # Put in place after the images, like Import.ps1 does.
        packages_dir="$work_dir/packages-$index"
        addon_import_extract "$blob" "$packages_dir" gzip || return 1
        ;;
    esac
    addon_import_context="importing addon '$key'"
  done < <(jq -r '(.layers // [])[] | [(.mediaType // "" | tostring), (.digest // "" | tostring)] | @tsv' "$manifest")

  # Read before staging replaces it: artifacts exported before an omit option existed do not declare it.
  if [[ -f "$destination/$ADDON_IMPORT_MANIFEST" ]]; then
    installed_copy="$work_dir/installed-$index.yaml"
    cp "$destination/$ADDON_IMPORT_MANIFEST" "$installed_copy" || return 1
  fi

  if [[ -n $implementation_dir ]]; then
    multi_implementation=true
  fi
  addon_import_stage_config "$config" "$destination" "$implementation_path" "$multi_implementation" || return 1

  flags="$(addon_import_omit_flags "$implementation" "$config/$ADDON_IMPORT_MANIFEST" "$installed_copy")" || return 1
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$flags"; then
    addon_import_error "reading the omit options failed"
    return 1
  fi
  while IFS= read -r flag; do
    [[ -z $flag ]] && continue
    images="$(addon_import_omitted_images "$flag" "$implementation_path")" || return 1
    if ! entry_flags="$(jq -c --argjson images "$images" --argjson flag "$flag" '. + [{name: $flag.name, images: $images}]' <<<"$entry_flags" 2>/dev/null)"; then
      addon_import_error "resolving the images of omit option $(jq -r '.name' <<<"$flag") failed"
      return 1
    fi
  done < <(jq -c '.[]' <<<"$flags")
  # The packages to install are declared by the addon manifest of the artifact.
  if [[ -f "$config/$ADDON_IMPORT_MANIFEST" ]]; then
    artifact_manifest="$work_dir/artifact-$index.yaml"
    cp "$config/$ADDON_IMPORT_MANIFEST" "$artifact_manifest" || return 1
  fi
  rm -rf "$config"

  if [[ -n $images_layer ]]; then
    files="$(addon_import_list_image_archives "$images_layer" | jq -Rsc 'split("\n") | map(select(. != ""))')" || return 1
  fi

  if ! jq -nc --arg key "$key" --arg name "$name" --arg implementation "$implementation" \
    --argjson files "$files" --argjson flags "$entry_flags" \
    '{key: $key, name: $name, implementation: $implementation, files: $files, flags: $flags}' >>"$work_dir/entries.jsonl"; then
    addon_import_error "recording the images failed"
    return 1
  fi
  entry_keys+=("$key")
  entry_layers+=("$images_layer")
  entry_bases+=("$base")
  entry_implementations+=("$implementation")
  entry_packages+=("$packages_dir")
  entry_manifests+=("$artifact_manifest")
  addon_import_context=""
}

# Copies an image archive to an additional Linux worker and loads it there with buildah, like
# Invoke-LinuxNodeImageImport of the Windows image scripts. The copy is removed in every case, also
# after a failed or interrupted upload.
addon_import_image_on_worker() {
  local ip="$1" user="$2" archive="$3" remote transport output status=0 imported=false
  local -a options=(-i "$ssh_key" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=30)

  # A unique name keeps concurrent imports on the same node from overwriting each other's archive, and
  # /var/tmp is disk-backed, unlike the RAM-backed /tmp of Debian 13 that multi-GB images would exhaust.
  remote="/var/tmp/k2s-image-import-$(mktemp -u XXXXXXXXXXXXXXXXXXXXXXXXXX).tar"

  if ! output="$(scp "${options[@]}" -P "$ADDON_IMPORT_SSH_PORT" "$archive" "$user@$ip:$remote" 2>&1)"; then
    addon_import_log "Warning: copying the image archive failed: $output"
    status=1
  else
    for transport in oci-archive docker-archive; do
      if output="$(ssh "${options[@]}" -p "$ADDON_IMPORT_SSH_PORT" "$user@$ip" "sudo buildah pull $transport:$remote 2>&1" 2>&1)"; then
        imported=true
        break
      fi
    done
    if [[ $imported == false ]]; then
      addon_import_log "Warning: buildah pull failed: $output"
      status=1
    fi
  fi

  if ! output="$(ssh "${options[@]}" -p "$ADDON_IMPORT_SSH_PORT" "$user@$ip" "sudo rm -f $remote" 2>&1)"; then
    addon_import_log "Warning: removing the temporary image archive $remote failed: $output"
    status=1
  fi
  return "$status"
}

addon_import_image_on_local_host() {
  local archive="$1" script="$K2S_INSTALL_DIR/lib/scripts/linux/debian/host/image/Import-Image.sh"
  if [[ -f $script ]]; then
    bash "$script" -t "$archive"
  else
    ctr -n k8s.io images import "$archive"
  fi
}

# Runs a command on an additional Linux worker; stdin is passed on.
addon_import_worker_ssh() {
  local ip="$1" user="$2" command="$3"
  ssh -i "$ssh_key" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=30 -p "$ADDON_IMPORT_SSH_PORT" "$user@$ip" "$command"
}

addon_import_worker_copy() {
  local ip="$1" user="$2" source="$3" target="$4"
  scp -i "$ssh_key" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o ConnectTimeout=30 -P "$ADDON_IMPORT_SSH_PORT" "$source" "$user@$ip:$target"
}

# Puts the offline packages of an addon where its enable expects them, like Import.ps1: the debian
# packages replace ~/.<addon>, a linux package with an absolute destination is copied there on the
# control plane (this host), and one with a relative destination goes to ~/.<addon>/<destination>.
# Like Import.ps1, the packages go to the last selected node when it is an additional Linux worker,
# otherwise to this host. Windows packages are skipped; they are only of use on a Windows host.
addon_import_packages() {
  local key="$1" base="$2" implementation="$3" packages="$4" manifest="$5"
  local implementation_json last ip user node folder url destination file source output count
  [[ -n $packages && -d $packages ]] || return 0

  if [[ ! -f $manifest ]]; then
    addon_import_log "Warning: $ADDON_IMPORT_MANIFEST not found in the artifact for '$key' - its packages are not installed"
    return 0
  fi
  if [[ -n $implementation ]]; then
    implementation_json="$(IMPLEMENTATION="$implementation" yq -o=json -I=0 '(.spec.implementations // [])[] | select(.name == strenv(IMPLEMENTATION))' "$manifest" 2>/dev/null | head -n 1)" || implementation_json=""
  else
    implementation_json="$(yq -o=json -I=0 '(.spec.implementations // [])[0]' "$manifest" 2>/dev/null)" || implementation_json=""
  fi
  if [[ -z $implementation_json ]] || ! jq -e '.offline_usage != null' >/dev/null 2>&1 <<<"$implementation_json"; then
    return 0
  fi

  addon_import_log "Installing packages for addon $key"
  last=$((${#target_names[@]} - 1))
  node="${target_names[last]}" ip="${target_ips[last]}" user="${target_users[last]}"
  folder=".$base"

  if [[ -d "$packages/debianpackages" ]]; then
    if [[ -n $ip ]]; then
      addon_import_log "Copying debian packages for addon $key to node '$node' ($ip)"
      if ! output="$(addon_import_worker_ssh "$ip" "$user" "sudo rm -rf $folder && mkdir -p $folder" 2>&1)" ||
        ! output="$(tar -C "$packages/debianpackages" -cf - . | addon_import_worker_ssh "$ip" "$user" "tar -C $folder -xf -" 2>&1)"; then
        addon_import_log "Warning: copying the debian packages of addon $key to node '$node' failed: $output"
      fi
    else
      rm -rf "${HOME:?}/$folder"
      if ! mkdir -p "$HOME/$folder" || ! cp -R "$packages/debianpackages/." "$HOME/$folder/"; then
        addon_import_log "Warning: copying the debian packages of addon $key to $HOME/$folder failed"
      fi
    fi
  fi

  while IFS=$'\t' read -r url destination; do
    [[ -n $url ]] || continue
    file="$(addon_oci_url_file_name "$url")"
    source="$packages/linuxpackages/$file"
    [[ -f $source ]] || continue

    if [[ $destination == /* ]]; then
      # An absolute destination installs the binary system-wide on the control plane.
      cp "$source" "$destination" 2>/dev/null || addon_import_log "Warning: installing $file of addon $key to $destination failed"
      continue
    fi
    if [[ -z $destination || ${destination//\\//} =~ $ADDON_IMPORT_PARENT_SEGMENT_PATTERN ]]; then
      addon_import_log "Warning: destination '$destination' of $file of addon $key leaves ~/$folder - not installed"
      continue
    fi
    if [[ -n $ip ]]; then
      if ! output="$(addon_import_worker_ssh "$ip" "$user" "mkdir -p $(printf '%q' "$folder/$(dirname "$destination")")" 2>&1)" ||
        ! output="$(addon_import_worker_copy "$ip" "$user" "$source" "$folder/$destination" 2>&1)"; then
        addon_import_log "Warning: copying $file of addon $key to node '$node' failed: $output"
      fi
    elif ! mkdir -p "$(dirname "$HOME/$folder/$destination")" || ! cp "$source" "$HOME/$folder/$destination"; then
      addon_import_log "Warning: copying $file of addon $key to $HOME/$folder/$destination failed"
    fi
  done < <(jq -r '.offline_usage.linux.curl // [] | .[] | [(.url // "" | tostring), (.destination // "" | tostring)] | @tsv' <<<"$implementation_json")

  if [[ -d "$packages/windowspackages" ]]; then
    count="$(find "$packages/windowspackages" -type f | wc -l)"
    if ((count > 0)); then
      addon_import_log "Skipping $count Windows package(s) of addon $key: they are only used on Windows hosts"
    fi
  fi
}

# Loads one image archive into every target node; all nodes are tried and each failing one is reported.
addon_import_image() {
  local archive="$1" i status=0
  for i in "${!target_names[@]}"; do
    if [[ -z ${target_ips[i]} ]]; then
      addon_import_image_on_local_host "$archive" && continue
    else
      addon_import_log "Importing $(basename "$archive") on node '${target_names[i]}' (${target_ips[i]})"
      addon_import_image_on_worker "${target_ips[i]}" "${target_users[i]}" "$archive" && continue
    fi
    addon_import_log "Warning: importing image archive $(basename "$archive") failed on node '${target_names[i]}'"
    status=1
  done
  return "$status"
}

# Hands the per-image archives of an images layer to the importer one at a time, so only a single
# image is unpacked on disk at any moment. Archives listed in the skip file are not imported.
addon_import_image_layer() {
  local layer="$1" key="$2" skip="$3" entry name image_dir archive count=0
  local -a members=()

  while IFS= read -r entry; do
    name="${entry//\\//}"
    [[ $name == */ ]] && continue
    name="${name##*/}"
    if [[ $name == *.tar && " ${members[*]} " != *" $entry "* ]]; then
      members+=("$entry")
    fi
  done < <(tar -tf "$layer")

  for entry in "${members[@]}"; do
    name="${entry//\\//}"
    name="${name##*/}"
    count=$((count + 1))
    if grep -Fxq -- "$name" "$skip"; then
      addon_import_log "[Prune] Not importing '$name' for '$key'"
      continue
    fi

    addon_import_check_entry "$entry" || return 1
    image_dir="$(mktemp -d "$work_dir/image-XXXXXX")" || return 1
    archive="$image_dir/$entry"
    if ! tar -xf "$layer" -C "$image_dir" --no-same-owner --no-same-permissions --occurrence=1 -- "$entry" 2>/dev/null ||
      [[ ! -f $archive || -L $archive ]]; then
      # Links and special files are not images.
      rm -rf "$image_dir"
      count=$((count - 1))
      continue
    fi

    addon_import_log "Importing image archive $name"
    if ! addon_import_image "$archive"; then
      image_failures+=("$name of '$key'")
    fi
    rm -rf "$image_dir"
  done

  if ((count == 0)); then
    image_failures+=("no image archives in the Linux images layer of '$key'")
  fi
}

addon_import_require_tools() {
  local tool
  for tool in tar sha256sum jq yq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      addon_import_error "required command '$tool' is not available - install it and import again"
      return 1
    fi
  done
  if [[ $(yq --version 2>&1) != *mikefarah* ]]; then
    addon_import_error "yq from https://github.com/mikefarah/yq is required; $(command -v yq) is another implementation"
    return 1
  fi
}

addon_import_main() {
  local artifact_file="" nodes="" i key plan line
  local -a names=() omit=()
  config_dir="" ssh_key="" work_dir="" blobs_dir="" addon_import_context=""
  target_names=() target_ips=() target_users=()
  exported_names=() exported_implementations=() exported_manifests=() selected_indices=()
  entry_keys=() entry_layers=() entry_bases=() entry_implementations=() entry_packages=() entry_manifests=() image_failures=()

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        addon_import_usage
        return 0
        ;;
      -f | --file | -c | --config-dir | -a | --addon | -o | --omit | -n | --nodes | -k | --ssh-key)
        if (($# < 2)); then
          addon_import_error "option $1 requires a value"
          return 2
        fi
        case "$1" in
          -f | --file) artifact_file="$2" ;;
          -c | --config-dir) config_dir="$2" ;;
          -a | --addon) names+=("$2") ;;
          -o | --omit) omit+=("$2") ;;
          -n | --nodes) nodes="$2" ;;
          -k | --ssh-key) ssh_key="$2" ;;
        esac
        shift 2
        ;;
      *)
        addon_import_error "unknown option: $1"
        return 2
        ;;
    esac
  done
  if [[ -z $artifact_file ]]; then
    addon_import_error "no path to OCI artifact provided (-f)"
    return 2
  fi
  config_dir="${config_dir:-/var/lib/k2s}"

  addon_import_require_tools || return 1
  addon_import_resolve_targets "$nodes" || return 1
  for i in "${!target_ips[@]}"; do
    if [[ -n ${target_ips[i]} && -z $ssh_key ]]; then
      ssh_key="$(k2s_ssh_private_key)" || return 1
    fi
  done

  if [[ ${artifact_file,,} != *"$ADDON_OCI_ARTIFACT_SUFFIX" ]]; then
    addon_import_error "unknown artifact format of '$artifact_file'; supported formats: $ADDON_OCI_ARTIFACT_SUFFIX"
    return 1
  fi
  if [[ ! -f $artifact_file ]]; then
    addon_import_error "extracting OCI artifact: '$artifact_file' does not exist"
    return 1
  fi

  # /tmp is a RAM-backed tmpfs on Debian 13, which multi-GB image layers would exhaust.
  if [[ -d /var/tmp ]]; then
    work_dir="$(mktemp -d /var/tmp/k2s-addons-import-XXXXXX)"
  else
    work_dir="$(mktemp -d -t k2s-addons-import-XXXXXX)"
  fi
  trap 'rm -rf "$work_dir"' EXIT

  addon_import_log "Extracting artifact from $artifact_file"
  addon_import_context="extracting OCI artifact"
  addon_import_extract "$artifact_file" "$work_dir/layout" plain || return 1
  addon_import_context=""

  addon_import_read_layout "$work_dir/layout" || return 1
  addon_import_select "${names[@]}" || return 1

  # Phase 1: stage the files of every selected addon and collect the images each one carries.
  : >"$work_dir/entries.jsonl"
  for i in "${selected_indices[@]}"; do
    addon_import_log "Importing addon: $(addon_import_key "${exported_names[i]}" "${exported_implementations[i]}")"
    addon_import_stage_addon "$i" || return 1
  done

  # Phase 2: decide globally which images the omit options allow to skip.
  plan="$(jq -s '{entries: ., omit: $ARGS.positional}' --args "${omit[@]}" <"$work_dir/entries.jsonl" | addon_import_jq 'prune_plan' -c)"
  while IFS= read -r line; do
    addon_import_log "$line"
  done < <(addon_import_jq 'plan_log' -r <<<"$plan")

  # Phase 3: load the remaining images into the container runtime of every target node, then put the
  # packages of the addon in place.
  for i in "${!entry_keys[@]}"; do
    key="${entry_keys[i]}"
    if [[ -z ${entry_layers[i]} ]]; then
      addon_import_log "No Linux images layer found for '$key'"
    else
      jq -r --arg key "$key" '.skip[$key] // [] | .[]' <<<"$plan" >"$work_dir/skip"
      addon_import_context="importing images of addon '$key'"
      addon_import_image_layer "${entry_layers[i]}" "$key" "$work_dir/skip" || return 1
      addon_import_context=""
    fi
    addon_import_context="installing packages of addon '$key'"
    if ! addon_import_packages "$key" "${entry_bases[i]}" "${entry_implementations[i]}" "${entry_packages[i]}" "${entry_manifests[i]}"; then
      addon_import_error "installing the packages failed"
      return 1
    fi
    addon_import_context=""
  done

  if ((${#image_failures[@]} > 0)); then
    addon_import_error "addons '$(addon_oci_join ', ' "${entry_keys[@]}")' were imported with image import failures: $(addon_oci_join '; ' "${image_failures[@]}")"
    return 1
  fi

  addon_import_log "Addons '$(addon_oci_join ', ' "${entry_keys[@]}")' imported successfully from OCI artifact"
  while IFS= read -r line; do
    addon_import_log "$line"
  done < <(addon_import_jq 'plan_summary' -r <<<"$plan")
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  addon_import_main "$@"
fi
