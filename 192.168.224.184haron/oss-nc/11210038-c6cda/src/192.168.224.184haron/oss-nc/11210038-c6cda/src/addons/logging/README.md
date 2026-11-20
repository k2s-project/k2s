<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# logging

## Introduction

The `logging` addon provides an [OpenSearch Dashboards web-based UI](https://github.com/opensearch-project/OpenSearch-Dashboards) for Kubernetes logging. It enables users to analyze container logs from k2s cluster supporting full-text search.

## Getting started

The logging addon can be enabled using the k2s CLI by running the following command:
```console
k2s addons enable logging
```

### Integration with ingress nginx and ingress traefik addons

The logging addon can be integrated with ingress controllers (nginx, nginx-gw, or traefik) to expose the dashboard outside the cluster.

For example, the logging addon can be enabled along with traefik addon using the following command:
```console
k2s addons enable logging --ingress traefik
```

Or with nginx Gateway Fabric:
```console
k2s addons enable logging --ingress nginx-gw
```

_Note:_ The above command shall enable the specified ingress addon if it is not already enabled.

## Accessing the logging dashboard

The logging dashboard UI can be accessed via the following methods.

### Access using ingress

To access logging dashboard via ingress, one of the ingress addons (nginx, nginx-gw, or traefik) must be enabled.
Once the addons are enabled, the logging dashboard UI can be accessed at the following URL: <https://k2s.cluster.local/logging>

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the hosts **k2s.cluster.local** as a proxy override.

### Access using port-forwarding

To access logging dashboard via port-forwarding, the following command can be executed:
```console
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
```
In this case, the logging dashboard UI can be accessed at the following URL: <http://localhost:5601/logging>

Once the `Home` section appears, navigate to `Menu -> Discover`. Now logs can be searched and analyzed.

## OpenTelemetry

The OpenTelemetry input plugin of the logging addon allows receiving data as per the OTLP specification. The following endpoint can be used to send logs to the logging addon:

```
http://otel.logging.svc.cluster.local:4318/v1/logs
```

Those logs are added to the same index like all other logs and are visible under the `Discover` section.

## Disable logging

The logging addon can be disabled using the k2s CLI by running the following command:
```console
k2s addons disable logging
```

_Note:_ The above command will only disable logging addon. If other addons were enabled while enabling the logging addon, they will not be disabled.

## Deploying without OpenSearch (Fluent-bit only mode)

The `--omitOpensearch` flag deploys only the Fluent-bit DaemonSet(s), skipping OpenSearch and OpenSearch Dashboards. This is useful for consuming logs from an external pipeline.

```console
k2s addons enable logging --omitOpensearch
```

### Viewing logs

```console
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit
```

**Important notes:**

- No OpenSearch dashboard is available in this mode
- Fluent-bit outputs logs to stdout in JSON format
- The `--ingress` flag is ignored when `--omitOpensearch` is set
- To forward to an external OTEL collector, replace the generated ConfigMap after enabling

### Disabling

```console
k2s addons disable logging
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```console
k2s addons backup logging
```

Restore from a backup zip:
```console
k2s addons restore logging -f C:\Temp\k2s\Addons\logging_backup_YYYYMMDD_HHMMSS.zip
```

What is backed up:
- Selected ConfigMaps (best-effort) for OpenSearch and Fluent Bit.

Notes:
- Backup/restore does not include OpenSearch data (historical logs).
- Restore applies config and triggers best-effort rollout restarts.

## Further Reading
- [fluentbit](https://github.com/fluent/fluent-bit)
- [opensearch](https://github.com/opensearch-project/OpenSearch)
