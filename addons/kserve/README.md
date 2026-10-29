<!--
SPDX-FileCopyrightText: (c) 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# KServe

Installs **KServe v0.21.0 in Standard mode** on a Windows-hosted K2s cluster.
The controller manages model-serving Deployments and Services. Knative, Istio,
Gateway API, external ingress and model workloads are **not** installed by default.
Native Linux host lifecycle is not supported; inference runs on Linux nodes.

## Enable

```console
k2s addons enable kserve
k2s addons status kserve
```

Requires Kubernetes 1.32 or newer and a Linux node. The addon manages its own
webhook CA and TLS Secret; it does not depend on cert-manager, ingress or security
addons, create a cluster-wide CA issuer, or change the Windows trust store.
It does not replace another KServe installation.

Enable first waits for CRDs, the webhook certificate, the controller rollout
and webhook CA configuration before installing the `k2s-llama-cpp-cpu` and `k2s-vllm`
ClusterServingRuntimes. These are templates, not running model servers.

### Webhook certificates

A short-lived addon-owned Job uses the pinned `kube-webhook-certgen` utility
already used by other K2s addons. It creates a private CA and a service-specific
certificate in `kserve-webhook-server-cert`. KServe sets the CA on every entry in
its mutating and validating webhook configurations. No issuer or ingress is involved.
The utility issues long-lived certificates (100 years). The addon's existing
`AfterStart` hook checks for missing certificates or certificates expiring within
30 days and replaces them as needed. No central renewal hook is added:
`k2s system certificate renew` does not rotate KServe's certificate.
To deliberately replace it, disable and re-enable the addon with the original
enable flags; the normal custom-workload safety checks still apply.

Renewal trusts old and new CAs together, updates the TLS Secret, waits for the
controller rollout, then removes the old trust. Interrupted rotations are resumed
on the next cluster start or enable retry. Certificate generation failures retain
the Job for diagnosis. This CA is separate from the optional model-download CA below.

### Optional CPU example

On a cluster where the addon is not already enabled:

```console
k2s addons enable kserve --model qwen-cpu
```

This explicitly starts `qwen-small-cpu` in namespace `kserve-models-cpu` and
downloads the public Qwen2.5 0.5B Instruct GGUF Q4_K_M file (~469 MiB).
The Hugging Face revision and llama.cpp CPU build b11977 release tag are pinned.
The tag was verified to resolve to manifest
`sha256:01c2bc28d51291536df2ccebe5c6af1cdec9ea9b2bd98ac59556408caf96d3f8`,
the same build used in the working CPU test. A versioned tag, rather than a
digest reference, is used because the K2s offline exporter matches repository:tag.
It exposes an OpenAI-compatible API, not the KServe V2 inference protocol.

The model requests **2 CPUs and 4 GiB RAM**, with limits of 4 CPUs and 8 GiB,
in addition to K2s and controller resources. Allocate sufficient VM/node memory
and CPU headroom first; the smallest default K2s VM may be insufficient.
Enable waits up to 30 minutes for model readiness.

In a separate terminal, keep this port-forward running:

```console
kubectl port-forward -n kserve-models-cpu service/qwen-small-cpu-predictor 8080:80
```

From the K2s installation directory:

```console
curl.exe --noproxy "*" -H "Content-Type: application/json" --data-binary "@addons\kserve\config\manifests\examples\qwen-cpu\chat-input.json" http://localhost:8080/v1/chat/completions
```

### Optional NVIDIA GPU example

```console
k2s addons enable kserve --model qwen-gpu
```

Starts `qwen-small` in namespace `kserve-models`, using vLLM v0.11.0 and
Qwen2.5 0.5B Instruct with pinned model revision. Requires a Linux amd64 node
exposing `nvidia.com/gpu`, a free GPU, compatible NVIDIA drivers, Container
Toolkit configured for K2s's container runtime, and a device plugin.
The addon checks the advertised GPU resource, but the scheduler determines
availability; it does not install drivers or enable GPU passthrough.
See the [gpu-node addon](../gpu-node/README.md) for supported K2s GPU setups.
Verify GPU architecture, driver and VRAM compatibility with vLLM separately.
This GPU example has not yet been validated on live K2s hardware.

Port-forward `service/qwen-small-predictor` in namespace `kserve-models`;
use `config\manifests\examples\qwen-gpu\chat-input.json` for the request.

## Download proxy and certificate trust

| Enable flag | Default | Meaning |
|---|---|---|
| `--model` | `none` | `none`, `qwen-cpu`, or `qwen-gpu`; examples explicitly authorize weight downloads |
| `--proxy` | `auto` | Use `http://<K2s switch IP>:8181` for storage-initializer downloads; `none` selects direct access |
| `--ca-bundle` | empty | Approved public root/intermediate CA certificates in PEM format |

```console
k2s addons enable kserve --model qwen-cpu --proxy http://proxy.example:81 --ca-bundle C:\certs\approved-ca.pem
```

Image pulling uses the **node's** proxy and certificate trust. Model downloading
uses the **storage-initializer container's** separate proxy and CA configuration;
successful image pulls do not prove that Hugging Face HTTPS is trusted inside it.
Allow Hugging Face and its redirected CDN endpoints through the network.
Credential-bearing proxy URLs and private keys in the CA bundle are rejected.

TLS verification stays enabled. KServe combines the supplied CA with its normal
public roots, replicating it to model namespaces as `global-ca-bundle`.
The source ConfigMap `k2s-kserve-ca` is retained across disable/re-enable.
Its public PEM content is also saved in addon configuration for cluster restore;
the original local file is not required again. No corporate CA or proxy is bundled.
Replacing it requires supplying `--ca-bundle` on the next enable.
To remove an obsolete CA, disable the addon, remove ConfigMap `k2s-kserve-ca`
in namespace `kserve`, and re-enable without `--ca-bundle`.

## Disable and retry

```console
k2s addons disable kserve
```

Deletes addon-owned example InferenceServices **before** removing their controller,
then removes runtime definitions, controller, RBAC, webhook configurations and its
serving certificate. CRDs, namespaces, service accounts, PVCs, the approved CA
bundle remain. The certificate Job, its RBAC and its TLS Secrets are removed.
No namespace or model volume is deleted. Other addons and their certificates
are unaffected.

Disable refuses to proceed if custom InferenceServices, InferenceGraphs,
TrainedModels or namespaced ServingRuntimes still exist anywhere in the cluster.
Remove them while the controller is running so their finalizers can finish;
export their definitions first if needed. Retained CRDs can only be removed
manually after checking that no custom resources or consumers remain.

Enabled configuration is saved only after readiness succeeds. A failed enable
leaves resources for diagnosis: fix the reported problem and retry the **same**
enable command. It does not forcibly adopt resources or strip finalizers.
To change model selection or download settings after successful installation,
disable and re-enable with the desired flags.

## Offline use and custom models

```console
k2s addons export kserve -d C:\exports
k2s addons import kserve -f C:\exports\<exported-archive>
k2s addons enable kserve
```

Export/import includes vendored manifests, controller, storage-initializer,
both runtime images and the certificate-generation image. The vLLM image is large,
even if only the CPU example will be used. **Model weights are not included.**
The default `--model none` starts no model downloader. The optional examples
require explicit online access and download weights again after pod replacement.

For disconnected serving, enable without an example. Copy a provided example
into your own manifest, use your own namespace, name and ownership labels, and
replace `spec.predictor.model.storageUri` with `pvc://<claim>/<model-directory>`
on a pre-populated claim in that namespace. Keep the CPU GGUF basename matching
the `--model /mnt/models/...` argument. Apply your custom manifest only after
the addon is ready. Custom runtimes and optional KServe features may require
additional preloaded images. Back up custom resources and model/PVC data separately;
addon configuration restore does not back up model weights or custom workloads.

## Troubleshooting

```console
kubectl get pods -n kserve
kubectl logs -n kserve deployment/kserve-controller-manager -c manager
kubectl describe secret kserve-webhook-server-cert -n kserve
kubectl logs -n kserve job/k2s-kserve-certgen
kubectl get inferenceservices -A
kubectl get events -n kserve-models-cpu --sort-by=.lastTimestamp
kubectl logs -n kserve-models-cpu deployment/qwen-small-cpu-predictor -c storage-initializer
```

The certificate-generation Job is deleted after success; its logs are available
only when generation was left for diagnosis.

`Pending` usually requires inspecting scheduling events (CPU, RAM or GPU).
`Init:CrashLoopBackOff` usually requires checking the download proxy, allowed
Hugging Face/CDN endpoints, TLS trust and available ephemeral disk space.
An internal Service is created for each model; an advertised InferenceService
URL does not imply public DNS or an installed ingress route.

## Maintenance and offline checks

Staged Kubernetes assets deliberately live under `config\manifests`, not the
addon-root `manifests` directory. The generic native Linux provider therefore
cannot recursively apply optional models or delete retained CRDs. Windows
lifecycle scripts select each stage explicitly, and existing addon export/import
already preserves the `config` directory. No provider changes are required.

Upstream resources come from the v0.21.0 standalone Kustomize overlay:
<https://github.com/kserve/kserve/tree/v0.21.0/config/overlays/standalone/kserve>.
The source archive SHA256 used for initial rendering was
`a5b1b4974893559a1960adfb08e2a0524bd7f7e4dd34f66bd150ea5b38f66004`.
The upstream Apache-2.0 license is retained in `kserve.license`.
Runtime/example adaptations retain the K2sSupport MIT attribution and notice
in `support-examples.license`.

From a local upstream checkout with PyYAML installed, regenerate with:

```console
python addons\kserve\tools\render_upstream.py --source C:\src\kserve --kubectl C:\k2s\bin\kube\kubectl.exe
python -m unittest discover -s addons\kserve\tests -v
```

The Python checks need PyYAML, jsonschema and `kubectl` on PATH (or the `KUBECTL`
environment variable). `Kserve.Helpers.unit.tests.ps1` provides mocked Pester
lifecycle checks. Neither test suite contacts a cluster or downloads models.
