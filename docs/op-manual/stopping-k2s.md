<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Stopping *K2s*
To stop the *K8s* cluster and all accompanying services, run:
```console
k2s stop
```

On Windows, the shared Hyper-V stop helper gives stop-job waiting and the
optional Off-state confirmation a combined 360-second budget. A failed or
stalled stop is reported with the VM identity, job state, and elapsed time
instead of synchronously waiting inside `Stop-VM`. The existing `Stop-VM -Force`
shutdown policy is preserved; there is no additional `-TurnOff` fallback.
Unfinished jobs are logged and retained in the calling PowerShell session
because forcibly removing them can itself block. Hyper-V may still be
processing a shutdown after a timeout, so check the VM state and Hyper-V
events before retrying.

!!! danger
    It is **highly recommended to stop K2s before (shutting down | suspending | hibernating) the Windows host system** to avoid *Windows* networking issues on the next host system startup!

    This is a known root cause for issues occurring while running *Windows*-based workloads after *K8s* cluster start.