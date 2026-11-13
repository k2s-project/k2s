<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Hook System

*K2s* supports custom **hook scripts** that run automatically during lifecycle operations. Hooks let you extend the built-in behaviour — for example, backing up external resources before an upgrade or configuring third-party tools after cluster start.

## How Hooks Work

The hook system scans two directories for matching PowerShell scripts:

1. **Default directory:** `<k2s-install-dir>\bin\LocalHooks\`
2. **Additional directory:** specified via the `--additional-hooks-dir` CLI flag or the `env.additionalHooksDir` config file option

When a lifecycle operation reaches a hook point, all `.ps1` files whose names end with the hook name are executed in filesystem order.

## Naming Convention

Hook scripts must follow the pattern:

```
*<HookName>.ps1
```

The file name can have any prefix, but must end with the exact hook name followed by `.ps1`. For example, for a hook point called `AfterStart`:

| File Name | Matches? |
|-----------|----------|
| `MyApp.AfterStart.ps1` | Yes |
| `99-cleanup.AfterStart.ps1` | Yes |
| `AfterStart.ps1` | Yes |
| `AfterStartup.ps1` | No (different suffix) |
| `afterstart.ps1` | Depends on filesystem case sensitivity |

## Available Hook Points

Hooks are invoked during these lifecycle operations:

| Operation | CLI Command | Hook Points |
|-----------|------------|-------------|
| Install | `k2s install` | Hooks run at defined points during installation |
| Uninstall | `k2s uninstall` | Hooks run during uninstallation |
| Start | `k2s start` | Hooks run during cluster start |
| Stop | `k2s stop` | Hooks run during cluster stop |
| System Backup | `k2s system backup` | Hooks run during backup |
| System Restore | `k2s system restore` | Hooks run during restore |
| Full Upgrade | `k2s system upgrade` | Backup and Restore hooks (see below) |

!!! note
    Hooks are **not executed during delta updates**. Delta updates perform in-place file replacement without uninstalling/reinstalling the cluster.

### Upgrade Hooks

The full upgrade process supports two specific hook types:

| Hook Name | When Executed | Purpose |
|-----------|---------------|---------|
| `Backup` | Before the old cluster is uninstalled | Save custom resources, external configs, SMB shares |
| `Restore` | After the new cluster is installed | Restore previously saved resources |

Each upgrade hook script receives the following parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `-BackupDir` | string | Directory where backup data should be stored or retrieved |
| `-ShowLogs` | switch | Whether to display verbose logging |

## Usage

### Via CLI Flag

Pass a custom hooks directory to any supported command:

```console
k2s install --additional-hooks-dir "C:\MyHooks"
k2s system upgrade --additional-hooks-dir "C:\MyHooks"
k2s start --additional-hooks-dir "C:\MyHooks"
```

### Via Config File

Set the hooks directory in the install config YAML:

```yaml
env:
  additionalHooksDir: C:\MyHooks
```

### Placing Hooks in the Default Directory

Copy hook scripts directly into `<k2s-install-dir>\bin\LocalHooks\`:

```
C:\k\bin\LocalHooks\
  ├── MyApp.Backup.ps1
  └── MyApp.Restore.ps1
```

## Example: Upgrade Hook for SMB Shares

```powershell
# SMBBackup.Backup.ps1
# Backs up SMB share mappings before upgrade
param(
    [string]$BackupDir,
    [switch]$ShowLogs
)

$backupPath = Join-Path $BackupDir "smb-shares"
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

if ($ShowLogs) {
    Write-Host "Backing up SMB share configuration..."
}

Get-SmbShare | Where-Object { $_.Special -eq $false } |
    Export-Clixml -Path (Join-Path $backupPath "shares.xml")
```

```powershell
# SMBBackup.Restore.ps1
# Restores SMB share mappings after upgrade
param(
    [string]$BackupDir,
    [switch]$ShowLogs
)

$backupPath = Join-Path $BackupDir "smb-shares"
$sharesFile = Join-Path $backupPath "shares.xml"

if (Test-Path $sharesFile) {
    if ($ShowLogs) {
        Write-Host "Restoring SMB share configuration..."
    }
    $shares = Import-Clixml -Path $sharesFile
    foreach ($share in $shares) {
        New-SmbShare -Name $share.Name -Path $share.Path -ErrorAction SilentlyContinue
    }
}
```

## Execution Details

- Hook scripts are discovered using `Get-ChildItem -Filter "*<HookName>.ps1"`.
- Both the default and additional directories are scanned.
- Execution order follows the filesystem sort order within each directory (default directory first, then additional directory).
- If no matching hook scripts are found, the lifecycle operation proceeds normally — no error is raised.
- Hook script failures may cause the parent operation to fail, depending on the operation.

## See Also

- [Configuration Reference](configuration-reference.md) — `env.additionalHooksDir` in install config
- [Upgrading K2s](upgrading-k2s.md) — upgrade hooks with backup/restore parameters
