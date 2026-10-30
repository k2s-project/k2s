<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# monitoring

## Introduction

The `monitoring` addon provides a [Grafana web-based UI](https://github.com/grafana/grafana) for Kubernetes resource monitoring. It enables users to monitor cluster resources which are collected by Prometheus (e.g. node, pod and GPU resources). For this purpose, several predefined dashboards are provided.

### Windows Exporter compatibility

The shared Windows Exporter configuration supports 0.32.0 and does not enable
the removed `thermalzone` collector, which otherwise prevents exporter startup.
Custom collector configurations must follow the
[upstream 0.32 upgrade guide](https://github.com/prometheus-community/windows_exporter/blob/v0.32.0/docs/upgrade/0.32.md).
Temperature metrics are no longer collected by the shared configuration.

The Windows Exporter acceptance suite requires a successful ServiceMonitor scrape
for every Windows node, not merely a discovered target with `up=0`. On failure,
it records exporter configuration, pod status/logs, endpoints, and the exporter
targets' Prometheus scrape errors before addon cleanup.
Its CPU check and the bundled Grafana CPU queries use the 0.32 metric name
`windows_cpu_time_seconds_total`. Bundled dashboards do not query removed
`windows_thermalzone_*` metrics.

## Grafana License Compliance

K2s is licensed under the MIT License.

It interacts with Grafana (AGPLv3) solely through its standard, public APIs; no AGPL‑licensed code is incorporated or modified, and Grafana is deployed as an container. For this integration scenario, a copyleft assessment was performed with the conclusion that AGPLv3 copyleft obligations are not triggered for this specific scenario.

**Important:** The AGPLv3 terms continue to apply to Grafana itself. Users must independently assess whether the AGPLv3 is appropriate for their use case.

## Getting started

The monitoring addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable monitoring
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```
k2s addons backup monitoring
```

Restore from a backup zip:
```
k2s addons restore monitoring -f C:\Temp\k2s\Addons\monitoring_backup_YYYYMMDD_HHMMSS.zip
```

Notes:
- Backups are config-only (Kubernetes Secrets are not backed up or restored).
- Persistent volume data is not backed up or restored.
- Backups selectively capture user-relevant configuration (Grafana dashboards/datasources ConfigMaps, ingress objects, and non-Helm-managed Prometheus Operator custom resources).
- If no custom resources are present, the backup can be metadata-only (`files: []`); restore is then effectively a reinstall/repair.

During restore, Helm-managed resources (chart defaults) are skipped to avoid conflicts with the addon enable/reconcile process.

### Integration with ingress nginx and ingress traefik addons

The monitoring addon can be integrated with the ingress nginx, ingress nginx-gw, or ingress traefik addon so that it can be exposed outside the cluster.

For example, the monitoring addon can be enabled along with traefik addon using the following command:

```
k2s addons enable monitoring --ingress traefik
```

Or with nginx-gw addon using the following command:

```
k2s addons enable monitoring --ingress nginx-gw
```

_Note:_ The above command shall enable the ingress addon if it is not enabled.

## Accessing the monitoring dashboard

The monitoring dashboard UI can be accessed via the following methods.

### Access using ingress

To access monitoring dashboard via ingress, the ingress nginx, ingress nginx-gw, or ingress traefik addon has to be enabled.
Once the addons are enabled, then the monitoring dashboard UI can be accessed at the following URL: <https://k2s.cluster.local/monitoring>

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the hosts **k2s.cluster.local** as a proxy override.

### Access using port-forwarding

To access monitoring dashboard via port-forwarding, the following command can be executed:

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

In this case, the monitoring dashboard UI can be accessed at the following URL: <http://localhost:3000/monitoring>

### Login to monitoring dashboard

When the monitoring dashboard UI is opened in the browser, please use the following credentials for initial login:

```
username: admin
password: admin
```

_Note:_ Credentials can be changed after first login.

## Headless mode (without Grafana)

If you use an external monitoring UI such as **OpenLens**, **Lens**, or your own Grafana instance, you can deploy only Prometheus, Alertmanager, and exporters without the built-in Grafana:

```
k2s addons enable monitoring --omitGrafana
```

This deploys:
- Prometheus (metrics collection & storage)
- Alertmanager (alerting)
- Prometheus Operator
- Kube-state-metrics
- Node Exporter (Linux) and Windows Exporter

### Accessing Prometheus from external tools

Use port-forwarding to access Prometheus:

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Then connect your monitoring tool to `http://localhost:9090`.

## Disable monitoring

The monitoring addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable monitoring
```

_Note:_ The above command will only disable monitoring addon. If other addons were enabled while enabling the monitoring addon, they will not be disabled.

## Further Reading

- [Prometheus](https://prometheus.io/)
- [Grafana OSS](http://github.com/grafana/grafana)
