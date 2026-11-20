<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Kube-Prometheus-Stack
## Generate manifests
1. helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
2. helm repo update
3. helm fetch prometheus-community/kube-prometheus-stack --untar
4. mkdir output\kube-prometheus-stack\crds
5. helm template -n monitoring kube-prometheus-stack . --output-dir .\output --include-crds --debug --skip-tests
6. Merge manifests under output\kube-prometheus-stack to existing structure like in addons/monitoring/manifests
7. Copy and overide manifests to addons/monitoring/manifests
8. Update kustomization.yaml

## Keep following files
- grafana/ingress.yaml
- grafana/traefik.yaml
- grafana/dashboards-1.14/gpu.yaml
- grafana/dashboards-1.14/windows-node-1.yaml
- grafana/dashboards-1.14/windows-node-2.yaml
- grafana/configmaps-datasources.yaml
- prometheus/additionalScrapeConfigs.yaml

## Modify following files
- grafana/configmap.yaml:

```
    [server]
    # these settings needed to make it work with Ingress
    root_url = https://k2s.cluster.local/monitoring
    serve_from_sub_path = true
    domain = k2s.cluster.local

```

- grafana/secret.yaml
```
  admin-user: "YWRtaW4=" #admin
  admin-password: "YWRtaW4=" #admin
```

- prometheus/prometheus.yaml

```
  additionalScrapeConfigs:
    name: kube-prometheus-stack-prometheus-scrape-confg
    key: additional-scrape-configs.yaml
```

# License Considerations

Grafana OSS (Open Source Software) is licensed under **AGPL-3.0**. This project uses the official Grafana OSS Docker images from the [grafana/grafana](https://github.com/grafana/grafana) repository, which are provided under the AGPL-3.0 license.

**Important Notes:**
- We use **Grafana OSS only** (not Grafana Enterprise).
- Docker image: `grafana/grafana` (official OSS builds).
- AGPL-3.0 requires that any modifications to Grafana itself be disclosed if the service is made available over a network. Since K2s deploys unmodified Grafana OSS container images, no additional AGPL compliance steps are required beyond including this notice.

For full license details, see: https://github.com/grafana/grafana/blob/main/LICENSE
