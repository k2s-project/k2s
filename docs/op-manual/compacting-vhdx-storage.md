<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Compacting VHDX Storage

The Kubemaster VM uses a dynamically expanding VHDX. It grows when data is written but **does not shrink** when data is deleted (the "High Water Mark" issue). Use `k2s system compact` to reclaim wasted space after operations like importing/deleting container images or downloading large files.

!!! note "Supported setups"
    `k2s system compact` works with **standard k2s** and **Linux-only** setups.
    It is **not available** for WSL-based or build-only installations (no Hyper-V VHDX present).

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

## Troubleshooting

**VHDX locked / still mounted:**

```powershell
Dismount-VHD -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\KubeMaster.vhdx"
```

**No space saved:** The VHDX may already be compacted or contain mostly active data.
