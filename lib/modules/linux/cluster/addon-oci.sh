#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# The OCI addon artifact format shared by Export-Addon.sh and Import-Addon.sh, the native Linux
# counterparts of addons/Export.ps1 and addons/Import.ps1 (see addons/oci.module.psm1).

if [[ -n ${K2S_ADDON_OCI_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_ADDON_OCI_SH_LOADED=1

readonly ADDON_OCI_LAYOUT_VERSION='1.0.0'
readonly ADDON_OCI_ARTIFACT_SUFFIX='.oci.tar'
readonly ADDON_OCI_ARTIFACT_TYPE='application/vnd.k2s.addon.v1'
readonly ADDON_OCI_MANIFEST_MEDIA_TYPE='application/vnd.oci.image.manifest.v1+json'
readonly ADDON_OCI_INDEX_MEDIA_TYPE='application/vnd.oci.image.index.v1+json'
readonly ADDON_OCI_EMPTY_MEDIA_TYPE='application/vnd.oci.empty.v1+json'
readonly ADDON_OCI_CONFIG_MEDIA_TYPE='application/vnd.k2s.addon.config.v1+json'
readonly ADDON_OCI_CONFIG_FILES_MEDIA_TYPE='application/vnd.k2s.addon.configfiles.v1.tar+gzip'
readonly ADDON_OCI_MANIFESTS_MEDIA_TYPE='application/vnd.k2s.addon.manifests.v1.tar+gzip'
readonly ADDON_OCI_CHARTS_MEDIA_TYPE='application/vnd.cncf.helm.chart.content.v1.tar+gzip'
readonly ADDON_OCI_SCRIPTS_MEDIA_TYPE='application/vnd.k2s.addon.scripts.v1.tar+gzip'
readonly ADDON_OCI_SHARED_SCRIPTS_MEDIA_TYPE='application/vnd.k2s.addon.shared-scripts.v1.tar+gzip'
readonly ADDON_OCI_LINUX_IMAGES_MEDIA_TYPE='application/vnd.oci.image.layer.v1.tar'
readonly ADDON_OCI_WINDOWS_IMAGES_MEDIA_TYPE='application/vnd.k2s.addon.images-windows.v1.tar'
readonly ADDON_OCI_PACKAGES_MEDIA_TYPE='application/vnd.k2s.addon.packages.v1.tar+gzip'
readonly ADDON_OCI_NAME_ANNOTATION='vnd.k2s.addon.name'
readonly ADDON_OCI_IMPL_ANNOTATION='vnd.k2s.addon.implementation'

# The jq functions for image references. Archive names follow ConvertTo-ImageTarFileName of
# addons/oci.module.psm1: ':' and '/' become '_' and other characters are dropped, so that the
# exporter and the importer can never disagree on the name of an image archive.
read -r -d '' ADDON_OCI_JQ_DEFS <<'JQ' || true
def trimspace: gsub("^\\s+|\\s+$"; "");
def trimchars($class): gsub("^[" + $class + "]+|[" + $class + "]+$"; "");
def lc: ascii_downcase;
def unique_in_order: reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);
def append_unique($key; $value): .[$key] = ((.[$key] // []) | if any(.[]; . == $value) then . else . + [$value] end);
def sanitize: gsub("[:/]"; "_") | gsub("[^a-zA-Z0-9_.-]"; "");
def archive_name: sanitize + ".tar";

# Extracts the 'image:' values and '--flag=repo/image:tag' arguments of a manifest, like
# Get-ImagesFromYaml of addons/addons.module.psm1.
def images_from_yaml:
  [ split("\n")[]
    | if test("^\\s*image:\\s*(.+)$"; "i") then
        capture("^\\s*image:\\s*(?<value>.+)$"; "i").value
        | split("#")[0] | trimspace | trimchars("\"") | trimchars("'")
        | select(. != "")
      elif test("--[a-zA-Z-]+=[a-zA-Z0-9.\\-_/]+/[a-zA-Z0-9.\\-_/]+:[a-zA-Z0-9.\\-_]+") then
        capture("--[a-zA-Z-]+=(?<value>[a-zA-Z0-9.\\-_/]+/[a-zA-Z0-9.\\-_/]+:[a-zA-Z0-9.\\-_]+)").value | trimspace
      else empty end ];

# Drops an image without tag when the same image is listed with a tag, like Remove-VersionlessImages.
def remove_versionless:
  def tagged: first(capture("^(?<repository>.+):(?<tag>.+)$") | select(.tag | trimspace | . != "")) // null;
  . as $images
  | [ $images[] | tagged | select(. != null) | .repository ] as $versioned
  | reduce $images[] as $image ([];
      ($image | tagged) as $match
      | if ($match != null or ($versioned | any(.[]; . == $image) | not)) and (any(.[]; . == $image) | not)
        then . + [$image] else . end);

def clean_images: [ .[] | trimspace | trimchars("\"'") | trimspace | select(. != "") ] | unique_in_order | remove_versionless;
JQ

addon_oci_join() {
  local separator="$1" result=""
  shift
  while (($# > 0)); do
    result+="${result:+$separator}$1"
    shift
  done
  printf '%s' "$result"
}

# Prints the file name of a package URL ('https://host/a/tool?raw=true' -> 'tool'), under which the
# exporter stores the package and the importer finds it.
addon_oci_url_file_name() {
  local url="${1%%[?#]*}"
  printf '%s\n' "${url##*/}"
}
