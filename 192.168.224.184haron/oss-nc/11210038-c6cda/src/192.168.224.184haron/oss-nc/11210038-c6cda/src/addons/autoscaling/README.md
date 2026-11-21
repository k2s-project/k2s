<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# autoscaling

## Introduction

The `autoscaling` addon provides the possibility to horizontally scale workloads based on external events or triggers with [KEDA](https://github.com/kedacore/keda) (Kubernetes Event-Driven Autoscaling). 

KEDA serves as a Kubernetes Metrics Server and allows users to define autoscaling rules using a dedicated Kubernetes custom resource definition.

## Getting started

The autoscaling addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable autoscaling
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```
k2s addons backup autoscaling
```

Restore from a backup zip:
```
k2s addons restore autoscaling -f C:\Temp\k2s\Addons\autoscaling_backup_YYYYMMDD_HHMMSS.zip
```

The backup includes:
- Addon-owned ConfigMaps in the `autoscaling` namespace (excluding the auto-generated `kube-root-ca.crt`).

If no addon-owned ConfigMaps exist, the backup is metadata-only. In that case, restore will only reinstall/repair autoscaling by re-enabling the addon.

## Scaling
KEDA supports a wide range of [scalers](https://keda.sh/docs/latest/scalers/) e.g. [CPU](https://keda.sh/docs/latest/scalers/cpu/) or [Memory](https://keda.sh/docs/latest/scalers/memory/). KEDA scalers can both detect if a deployment should be activated or deactivated, and feed custom metrics for a specific event source.

## Disable autoscaling

The autoscaling addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable autoscaling
```

## Further Reading 

- [KEDA](https://keda.sh/)
