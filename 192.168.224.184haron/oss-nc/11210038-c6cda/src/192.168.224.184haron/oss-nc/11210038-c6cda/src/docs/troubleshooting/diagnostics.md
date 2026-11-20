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

## Running Health Checks
To check the host and the cluster for known causes of problems, run:
```console
k2s system check
```

Each check prints `pass`, `warn`, `fail` or `skip` (when it does not apply to the setup) together with a hint on how to fix the problem. The command does not change anything on the system and exits with a non-zero exit code if at least one check fails, so it can also be used in scripts. Use `k2s system check -o json` for machine-readable output.

| Check | Host | Description |
|-------|------|-------------|
| `host-disk-space` | *Windows*, *Linux* | Fails below 10 GiB and warns below 20 GiB of free space on the drives used by *K2s* (see [Disk Pressure](known-issues.md#disk-pressure)) |
| `apipa-address` | *Windows* | Warns if an active network adapter has an APIPA address (`169.254.x.x`) (see [Microsoft APIPA / Link-Local Address](known-issues.md#microsoft-apipa-link-local-address)); skipped for *Linux*-only and build-only setups |
| `hyperv-vmms` | *Windows* | Fails if the *Hyper-V* Virtual Machine Management service is not running; skipped for *WSL* setups |
| `cluster-certificates` | *Windows*, *Linux* | Fails if the cluster CA, the client certificate in the kubeconfig or the API server certificate has expired and warns if one expires within 30 days (renew them with [`k2s system certificate renew --force`](../user-guide/k2s-cli.md#system-certificate-renew)); skipped for build-only setups |

The API server certificate can only be checked while the cluster is running.

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
