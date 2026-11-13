<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Diagnostics
## *K2s* System Status
To inspect the full *K2s* system status, run:
```console
k2s status -o wide
```

## Disruption in networking
When there is no internet access on the host machine or when container images cannot be pulled, it is recommended to restart the cluster networking in the following scenarios:

- The host machine is switched between networks (e.g. remote or office).
- The host machine experiences an unintended crash.
- After booting the host machine from hibernation, or following a reboot or shutdown.
- The VPN on the host machine is turned on or off (e.g., Zscaler).

```console
k2s stop
k2s start
```

## Log Files
To analyze the log files, browse the directory `<install-drive>\var\log`. The main log file is `k2s.log`.

The log root is configurable; see [Configuring the K2s Log Folder](../op-manual/log-folder.md) for how to relocate it.

## Dumping *K2s* Debug Information
To dump *K2s* system information, run:
```console
k2s system dump
```

The dump collects logs, configuration, and cluster state into a zip file at `C:\var\log\k2s-dump-<hostname>-<datetime>.zip`.

## Network Diagnostics Dump

A dedicated network diagnostics dump is also available. It collects network-specific information (adapter states, routes, HNS networks, firewall rules) separately from the general system dump. The network dump script is located at `lib\scripts\windows\host\system\dump\network_dump.ps1`.

## Packet Capture

For deep network troubleshooting, capture packet traces on the Windows host:

1. Navigate to the debug directory:
   ```console
   cd <installation-folder>\smallsetup\debug
   ```
2. Start capturing:
   ```console
   .\startpacketcapture.cmd
   ```
3. Reproduce the issue.
4. Stop capturing:
   ```console
   .\stoppacketcapture.cmd
   ```
5. Analyse the trace file at `C:\server.etl` using [Microsoft Network Monitor](https://www.microsoft.com/en-us/download/details.aspx?id=4865){target="_blank"} or [Wireshark](https://www.wireshark.org){target="_blank"} (with an ETL conversion tool).

## Debug Helper Scripts

Several PowerShell debug scripts are available in `smallsetup\helpers\` for diagnosing specific subsystems:

| Script | Purpose |
|--------|---------|
| `DebugFlannel.ps1` | Inspect flannel CNI state, subnet leases, and routing tables |
| `DebugKubelet.ps1` | Inspect kubelet logs and configuration on the Windows host |
| `DebugProxy.ps1` | Inspect kube-proxy state and service routing rules |
| `DebugLoopbackConnectionProfile.ps1` | Debug the loopback adapter connection profile (in `smallsetup\debug\`) |

### Usage

Run from an elevated PowerShell prompt:

```powershell
cd <installation-folder>\smallsetup\helpers
.\DebugFlannel.ps1
.\DebugKubelet.ps1
.\DebugProxy.ps1
```

## Network Repair Scripts

When networking issues persist after a restart, these helper scripts can restore connectivity:

| Script | Purpose |
|--------|---------|
| `RecreateRoutes.ps1` | Recreate pod/service network routes on the Windows host |
| `ResetNetwork.ps1` | Full network reset (adapters, routes, HNS networks) |
| `ResetSystem.ps1` | Full system reset (network + cluster state) |
| `RefreshEnv.ps1` | Refresh environment variables without restarting the shell |

!!! warning
    `ResetSystem.ps1` is destructive — it resets the entire *K2s* system state. Use it only as a last resort.

Alternatively, use the CLI for a network reset (requires a reboot):

```console
k2s system reset network
```

On Linux hosts, `k2s system reset network` performs the host-network cleanup path. It leaves the K2s runtime configuration in place; use `k2s system reset` when you also need to remove the installed Linux-only cluster state and persisted K2s install state.

## Listing ALL PVCs
Get the list of all mounted volumes, their size and their namespace:
```console
kg pv
```

Get the list of all mounted volume claims and their current usage:
```console
kg pvc -A
```
