<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# ClusterIP Webhook

The ClusterIP webhook is a Kubernetes mutating admission webhook that assigns ClusterIPs from OS-specific subnets (Linux vs Windows) to Services created in the K2s cluster.

## Building the Container Image

The webhook runs as a container inside the Kubernetes cluster. The image is built from the `Dockerfile` in this directory.

### Prerequisites

- A running K2s cluster

### Build

From the repository root:

```console
k2s image build --input-folder . --dockerfile cmd/clusterip-webhook/Dockerfile --image-name shsk2s.azurecr.io/clusterip-webhook --image-tag <version>
```

### Push to registry

To push the built image to the container registry:

```console
k2s image push -n shsk2s.azurecr.io/clusterip-webhook:<version>
```

### Version Bump Checklist

When changing the webhook code, update the image tag in:

1. `lib/manifests/clusterip-webhook/deployment.yaml` — both `init-cert` and `webhook` containers
2. `lib/modules/windows/node/k2s.node.module/linuxnode/distros/common-setup.module.psm1` — image pull during cluster setup

## Operating Modes

The webhook binary supports two modes:

### Webhook Server (default)

Runs the admission webhook server:

```
/clusterip-webhook --addr=:8443 --health-addr=:8080 --tls-cert=/certs/tls.crt --tls-key=/certs/tls.key \
    --client-ca-file=/client-ca/ca.crt
```

- `--addr` serves the admission endpoints `/mutate` and `/mutate-workload`. A caller must present a client certificate that chains to a CA in `--client-ca-file`, otherwise the TLS handshake fails and no request is processed.
- `--client-ca-file` must contain nothing but valid CA certificates. The webhook exits if the file is missing or invalid.
- `--health-addr` serves `/healthz` over plain HTTP for the kubelet probes, which cannot present a client certificate.

### Certificate Init (`--init-cert`)

Generates a self-signed TLS certificate and patches the webhook configuration. Used as an init container:

```
/clusterip-webhook --init-cert --tls-cert=/certs/tls.crt --tls-key=/certs/tls.key \
    --service-name=clusterip-webhook --namespace=k2s-webhook --webhook-name=k2s-webhook
```

This mode:
- Generates a CA certificate and server certificate (ECDSA P-256, 1-year validity)
- Writes `tls.crt` and `tls.key` to the shared emptyDir volume
- Patches the `caBundle` field in the MutatingWebhookConfiguration
- Exits after completion

## Architecture

- The Deployment uses an **emptyDir** volume for `/certs`, avoiding a dependency on a pre-existing Secret
- The **init container** generates fresh TLS certificates on every Pod creation
- The Deployment mounts the ConfigMap `clusterip-webhook-client-ca` (key `ca.crt`) for `--client-ca-file`. It holds the public certificate of the CA that issues the client certificate of the kube-apiserver. This CA is separate from the serving CA of the init container. The ConfigMap is not optional, so the Pod does not start without it
- Certificate renewal is triggered by recreating the Pod (e.g., `kubectl rollout restart`)
- `k2s system certificate renew` includes the webhook in its renewal flow
- The webhook uses `failurePolicy: Ignore` so cluster operations continue if the webhook is temporarily unavailable
