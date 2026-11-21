<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# metrics

## Introduction

The `metrics` addon provides a metrics server which is a scalable, efficient source of container resource metrics for Kubernetes built-in autoscaling pipelines.

Metrics Server collects resource metrics from Kubelets and exposes them in Kubernetes apiserver through [Metrics API]. Metrics API can also be accessed by `kubectl top`,
making it easier to debug autoscaling pipelines.

[Metrics API]: https://github.com/kubernetes/metrics

## Getting started

The metrics server addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable metrics
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```
k2s addons backup metrics
```

Restore from a backup zip:
```
k2s addons restore metrics -f C:\Temp\k2s\Addons\metrics_backup_YYYYMMDD_HHMMSS.zip
```

What is backed up:
- Metrics Server configuration (Deployment + APIService).
- Windows exporter configuration/resources installed by this addon (ConfigMap/DaemonSet/Service, and ServiceMonitor if present).

Notes:
- This is a configuration-only backup/restore; it does not include historical metric data.

## Further Reading 

- [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server/blob/master/README.md)
