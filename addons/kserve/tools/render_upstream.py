# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-FileCopyrightText: (c) 2026 Siemens Healthineers AG
# SPDX-License-Identifier: Apache-2.0 AND MIT

"""Vendor KServe v0.21.0 without contacting a cluster.

Use --source with an upstream v0.21.0 checkout and --kubectl with a kubectl
executable containing Kustomize. --rendered accepts previously rendered upstream
files instead. Requires PyYAML. Local patches are maintained separately.
"""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

import yaml


VERSION = "v0.21.0"
HEADER = (
    "# SPDX-FileCopyrightText: The KServe Authors\n"
    "# SPDX-License-Identifier: Apache-2.0\n"
    f"# Generated from kserve/kserve {VERSION}; see tools/render_upstream.py.\n"
    "# Do not edit: use the controller Kustomization for local changes.\n"
)


def normalize(value):
    if isinstance(value, dict):
        result = {key: normalize(item) for key, item in value.items()}
        if isinstance(result.get("image"), str):
            result["imagePullPolicy"] = "IfNotPresent"
        return result
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, str):
        value = re.sub(
            r"\b(?:docker.io/)?kserve/([\w-]+):latest\b",
            rf"docker.io/kserve/\1:{VERSION}",
            value,
        )
        value = value.replace('"kserve/art-explainer"', '"docker.io/kserve/art-explainer"')
        value = value.replace('"defaultImageVersion": "latest"', f'"defaultImageVersion": "{VERSION}"')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--source", type=Path)
    source.add_argument("--rendered", type=Path, nargs="+")
    parser.add_argument("--kubectl", default="kubectl")
    parser.add_argument("--license", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.source:
        rendered = subprocess.run(
            [args.kubectl, "kustomize", str(args.source / "config" / "overlays" / "standalone" / "kserve")],
            check=True, capture_output=True, text=True, encoding="utf-8",
        ).stdout
        license_path = args.source / "LICENSE"
    else:
        rendered = "\n---\n".join(path.read_text(encoding="utf-8-sig") for path in args.rendered)
        if not args.license:
            parser.error("--license is required with --rendered")
        license_path = args.license
    crds, platform = [], []
    for doc in yaml.safe_load_all(rendered):
        if not doc or doc["kind"] in ("Namespace", "Certificate", "Issuer"):
            continue
        if doc["kind"] == "Secret" and doc["metadata"]["name"] in (
            "kserve-webhook-server-cert", "kserve-webhook-server-secret"
        ):
            continue
        doc = normalize(doc)
        metadata = doc["metadata"]
        metadata.pop("creationTimestamp", None)
        annotations = metadata.get("annotations", {})
        for key in list(annotations):
            if key.startswith(("argocd.argoproj.io/", "cert-manager.io/")):
                del annotations[key]
        if not annotations:
            metadata.pop("annotations", None)
        metadata.setdefault("labels", {})["app.kubernetes.io/managed-by"] = "k2s-kserve"
        if doc["kind"] in ("CustomResourceDefinition", "ClusterStorageContainer"):
            metadata.pop("namespace", None)
        if doc["kind"] == "ConfigMap":
            for name, value in doc["data"].items():
                if name != "_example":
                    json.loads(value)
        (crds if doc["kind"] == "CustomResourceDefinition" else platform).append(doc)
    if len(crds) != 6 or not any(doc["kind"] == "Deployment" for doc in platform):
        raise ValueError("Unexpected upstream standalone resource set")
    for relative, docs in (
        ("crds/kserve-crds.yaml", crds), ("controller/kserve.yaml", platform),
    ):
        output = root / "config" / "manifests" / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        # CRD schemas contain image: properties, not images; skip the legacy export scanner.
        export_marker = "# ## exclude-from-export\n" if relative.startswith("crds/") else ""
        output.write_text(
            HEADER + export_marker + "---\n" + yaml.safe_dump_all(docs, sort_keys=False, width=1000),
            encoding="utf-8", newline="\n",
        )
    shutil.copyfile(license_path, root / "kserve.license")
    print(f"Vendored {len(crds)} CRDs and {len(platform)} platform resources from {VERSION}.")


if __name__ == "__main__":
    main()
