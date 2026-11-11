<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: MIT
-->

# Compacting VHDX Storage

The Kubemaster VM uses a dynamically expanding VHDX. It grows when data is written but **does not shrink** when data is deleted (the "High Water Mark" issue). Use `k2s system compact` to reclaim wasted space after operations like importing/deleting container images or downloading large files.

!!! note "Supported setups"
    `k2s system compact` works with **standard k2s** and **Linux-only** setups.
    It is **not available** for WSL-based or build-only installations (no Hyper-V VHDX present).
    On a [Linux host](#linux-host-qcow2), it compacts the QCOW2 disk of the managed *Windows* worker instead.

## How It Works

1. **fstrim** – Runs inside the VM (if running) to notify Hyper-V which blocks are free.
2. **Stop** – Cluster is stopped for compaction.
3. **Optimize-VHD** – Physically shrinks the VHDX file on the Windows host.
4. **Restart** – Cluster is restarted by default (skip with `--no-restart`).

## Usage

```console
k2s system compact
```

Skip confirmation prompts:

```console
k2s system compact --yes
```

Compact but keep cluster stopped afterwards:

```console
k2s system compact --no-restart
k2s start
```

## Linux Host (QCOW2)

On a native *Linux* host, the control plane runs directly on the host, so the only VM disk is the QCOW2 overlay of the K2s-managed *Windows* worker (`/var/lib/libvirt/images/k2s/k2s-win-worker.qcow2`). The overlay grows the same way when data is written inside the worker. Run the same command with elevated privileges:

```console
sudo k2s system compact
```

1. **Trim** – Runs `Optimize-Volume -ReTrim` inside the worker (if running), so freed blocks are discarded from the QCOW2 overlay.
2. **Stop** – Cluster is stopped for compaction.
3. **qemu-img convert** – Rewrites the overlay without unused clusters. The overlay stays backed by the cached base image (`WindowsWorker-Base.qcow2`), which is not modified.
4. **Restart** – Cluster is restarted by default (skip with `--no-restart`).

The compacted copy is created next to the original disk and only replaces it after `qemu-img check` succeeds, so the host needs at least as much free space as the overlay currently uses. Compaction is refused while the worker has libvirt or QCOW2 snapshots, because rewriting the disk would discard them.

`k2s system compact` is **not available** for *Linux-only* setups on a *Linux* host, which have no VM disk.

## Troubleshooting

**VHDX locked / still mounted:**

```powershell
Dismount-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\KubeMaster.vhdx"
```

**No space saved:** The VHDX may already be compacted or contain mostly active data.

**Snapshots on the Linux-host Windows worker:**

```console
sudo virsh snapshot-list k2s-win-worker
sudo virsh snapshot-delete k2s-win-worker <snapshot-name>
```
