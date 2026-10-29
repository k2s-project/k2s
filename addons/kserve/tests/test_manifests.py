# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

"""Offline tests: python -m unittest discover -s addons\\kserve\\tests -v.

Requires PyYAML, jsonschema and kubectl (or KUBECTL pointing to its executable).
No Kubernetes API calls, downloads, image pulls or model execution.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import unittest

import jsonschema
from referencing import Registry, Resource
import yaml


ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = ROOT / "config" / "manifests"
KUBECTL = os.environ.get("KUBECTL", "kubectl")


def render(folder):
    output = subprocess.run(
        [KUBECTL, "kustomize", str(MANIFESTS / folder)],
        check=True, capture_output=True, encoding="utf-8",
    ).stdout
    return list(yaml.safe_load_all(output))


class KserveManifests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.crds = render("crds")
        cls.controller = render("controller")
        cls.runtimes = render("runtimes")
        cls.cpu = render("examples/qwen-cpu")
        cls.gpu = render("examples/qwen-gpu")
        cls.certificates = render("certificates")
        cls.config = next(doc["data"] for doc in cls.controller if doc["kind"] == "ConfigMap")

    def test_addon_manifest_and_script_mappings(self):
        schema = json.loads((ROOT.parent / "addon.manifest.schema.json").read_text())
        registry = Registry().with_resources(
            (definition["$id"], Resource.from_contents(definition))
            for definition in schema["$defs"].values()
        )
        manifest = yaml.safe_load((ROOT / "addon.manifest.yaml").read_text())
        jsonschema.Draft202012Validator(schema, registry=registry).validate(manifest)
        commands = manifest["spec"]["implementations"][0]["commands"]
        flags = commands["enable"]["cli"]["flags"]
        self.assertEqual(next(flag["default"] for flag in flags if flag["name"] == "model"), "none")
        mappings = commands["enable"]["script"]["parameterMappings"]
        self.assertEqual({flag["name"] for flag in flags}, {item["cliFlagName"] for item in mappings})
        for command in commands.values():
            self.assertTrue((ROOT / command["script"]["subPath"]).is_file())

    def test_vendored_crds_and_resources_are_owned(self):
        self.assertEqual(len(self.crds), 6)
        for doc in self.crds + self.controller + self.runtimes + self.cpu + self.gpu:
            self.assertEqual(doc["metadata"]["labels"]["app.kubernetes.io/managed-by"], "k2s-kserve")
            self.assertFalse(any(key.startswith("argocd.") for key in doc["metadata"].get("annotations", {})))
        self.assertNotIn("Namespace", {doc["kind"] for doc in self.controller})

    def test_all_custom_resources_match_vendored_schemas(self):
        schemas = {}
        for crd in self.crds:
            spec = crd["spec"]
            for version in spec["versions"]:
                schemas[(spec["group"] + "/" + version["name"], spec["names"]["kind"])] = version["schema"]["openAPIV3Schema"]
                jsonschema.Draft4Validator.check_schema(version["schema"]["openAPIV3Schema"])
        for doc in self.controller + self.runtimes + self.cpu + self.gpu:
            schema = schemas.get((doc["apiVersion"], doc["kind"]))
            if schema:
                jsonschema.Draft4Validator(schema).validate(doc)

    def test_standard_mode_has_required_legacy_gateway_without_installing_it(self):
        self.assertEqual(json.loads(self.config["deploy"])["defaultDeploymentMode"], "Standard")
        ingress = json.loads(self.config["ingress"])
        self.assertTrue(ingress["ingressGateway"])
        self.assertFalse(ingress["enableGatewayApi"])
        self.assertTrue(ingress["disableIngressCreation"])
        self.assertTrue(ingress["disableIstioVirtualHost"])
        self.assertFalse(json.loads(self.config["security"])["autoMountServiceAccountToken"])
        for value in self.config.values():
            if value != self.config.get("_example"):
                json.loads(value)

    def test_linux_controller_and_certificates(self):
        namespace = yaml.safe_load((MANIFESTS / "namespace.yaml").read_text())
        self.assertEqual(namespace["metadata"]["labels"]["control-plane"], "kserve-controller-manager")
        deployment = next(doc for doc in self.controller if doc["kind"] == "Deployment")
        pod = deployment["spec"]["template"]["spec"]
        self.assertEqual(pod["nodeSelector"]["kubernetes.io/os"], "linux")
        self.assertEqual(deployment["spec"]["replicas"], 1)
        for container in pod["containers"]:
            self.assertEqual(container["imagePullPolicy"], "IfNotPresent")
            self.assertIn("resources", container)
        self.assertFalse({"Certificate", "Issuer", "Secret"} & {doc["kind"] for doc in self.controller})
        for doc in self.controller:
            self.assertFalse(any(key.startswith("cert-manager.io/") for key in doc["metadata"].get("annotations", {})))
        job = yaml.safe_load((MANIFESTS / "certificates" / "job.yaml").read_text())
        spec = job["spec"]["template"]["spec"]
        container = spec["containers"][0]
        self.assertEqual(container["image"], "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9")
        self.assertEqual(spec["nodeSelector"]["kubernetes.io/os"], "linux")
        self.assertIn("--secret-name=k2s-kserve-webhook-next", container["args"])
        self.assertIn("--cert-name=tls.crt", container["args"])
        host_arg = next(arg for arg in container["args"] if arg.startswith("--host="))
        self.assertIn("kserve-webhook-server-service.kserve.svc", host_arg.split("=", 1)[1].split(","))
        role = next(doc for doc in self.certificates if doc["kind"] == "Role")
        self.assertEqual(role["rules"][0]["resourceNames"], ["k2s-kserve-webhook-next"])
        self.assertEqual({verb for rule in role["rules"] for verb in rule["verbs"]}, {"get", "create"})
        self.assertNotIn("Job", {doc["kind"] for doc in self.certificates})

    def test_cpu_uses_pinned_weights_and_versioned_cpu_image(self):
        service = next(doc for doc in self.cpu if doc["kind"] == "InferenceService")
        model = service["spec"]["predictor"]["model"]
        self.assertRegex(model["storageUri"], r"/resolve/[0-9a-f]{40}/qwen2.5-0.5b-instruct-q4_k_m.gguf$")
        container = self.runtimes[0]["spec"]["containers"][0]
        self.assertEqual(container["image"], "ghcr.io/ggml-org/llama.cpp:server-b11977")
        self.assertIn("--offline", container["args"])
        self.assertIn("--n-gpu-layers", container["args"])
        self.assertEqual(model["runtime"], self.runtimes[0]["metadata"]["name"])
        self.assertNotIn("nvidia.com/gpu", model["resources"]["limits"])

    def test_gpu_is_explicit_and_models_are_not_controller_resources(self):
        service = next(doc for doc in self.gpu if doc["kind"] == "InferenceService")
        predictor = service["spec"]["predictor"]
        self.assertEqual(predictor["model"]["resources"]["limits"]["nvidia.com/gpu"], "1")
        self.assertRegex(predictor["model"]["storageUri"], r"^hf://Qwen/Qwen2.5-0.5B-Instruct:[0-9a-f]{40}$")
        for docs in (self.cpu, self.gpu):
            service = next(doc for doc in docs if doc["kind"] == "InferenceService")
            self.assertNotEqual(service["metadata"]["namespace"], "kserve")
            self.assertEqual(service["spec"]["predictor"]["nodeSelector"]["kubernetes.io/os"], "linux")
        self.assertFalse(any(doc["kind"] == "InferenceService" for doc in self.controller + self.runtimes))

    def test_ca_is_optional_and_no_corporate_configuration_is_embedded(self):
        storage = json.loads(self.config["storageInitializer"])
        self.assertEqual(storage["caBundleConfigMapName"], "")
        self.assertEqual(storage["image"], "docker.io/kserve/storage-initializer:v0.21.0")
        for path in MANIFESTS.rglob("*"):
            if path.suffix in (".yaml", ".json"):
                text = path.read_text()
                self.assertNotIn("10.81.32.99", text)
                self.assertNotIn("ZScalerRootCA", text)
                self.assertNotIn("CERT_NONE", text)

    def test_offline_image_inputs_exist_and_cover_runtime_images(self):
        manifest = yaml.safe_load((ROOT / "addon.manifest.yaml").read_text())
        offline = manifest["spec"]["implementations"][0]["offline_usage"]["linux"]
        images = set(offline["additionalImages"])
        for relative in offline["additionalImagesFiles"]:
            path = ROOT / relative
            self.assertTrue(path.is_file(), str(path))
            images.update(re.findall(r"^\s*image:\s*(\S+)", path.read_text(), re.MULTILINE))
        for docs in (self.controller, self.runtimes):
            for doc in docs:
                if doc["kind"] == "Deployment":
                    containers = doc["spec"]["template"]["spec"]["containers"]
                elif doc["kind"] == "ClusterServingRuntime":
                    containers = doc["spec"]["containers"]
                elif doc["kind"] == "ClusterStorageContainer":
                    containers = [doc["spec"]["container"]]
                else:
                    continue
                for container in containers:
                    self.assertIn(container["image"], images)
                    self.assertNotIn(":latest", container["image"])
        self.assertTrue((ROOT / "kserve.license").is_file())
        self.assertIn("registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9", images)
        self.assertFalse(any("cert-manager" in image for image in images))

    def test_legacy_export_scanner_skips_crd_schemas_and_accepts_all_images(self):
        crds = (MANIFESTS / "crds" / "kserve-crds.yaml").read_text()
        self.assertIn("## exclude-from-export", crds)
        for path in ROOT.rglob("*.yaml"):
            text = path.read_text()
            if "## exclude-from-export" in text:
                continue
            for line in text.splitlines():
                if "image:" not in line or line.lstrip().startswith("#"):
                    continue
                self.assertIn("image: ", line, f"{path}: {line}")
                image = line.split("image: ", 1)[1].split("#")[0].strip().strip("\"'")
                # Export.ps1 selects stored images by repository:tag, not digest.
                self.assertNotIn("@", image)
                self.assertRegex(image, r"^[^:\s]+:[^:\s]+$")

    def test_native_linux_cannot_recursively_apply_or_delete_staged_resources(self):
        self.assertFalse((ROOT / "manifests").exists())
        self.assertTrue(MANIFESTS.is_dir())
        # The existing exporter/importer carries config/ recursively.
        assets = [path for path in MANIFESTS.rglob("*") if path.is_file()]
        self.assertTrue(assets)
        for path in assets:
            relative = path.relative_to(ROOT)
            self.assertEqual(relative.parts[0], "config")
        for script, expected in (
            ("Kserve.Helpers.ps1", "'config\\manifests'"),
            ("Kserve.Certificates.ps1", "'config\\manifests\\certificates'"),
        ):
            self.assertIn(expected, (ROOT / script).read_text())


if __name__ == "__main__":
    unittest.main()
