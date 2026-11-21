<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Configuring the K2s Log Folder

By default *K2s* writes all log files under `<SystemDrive>:\var\log` (typically `C:\var\log`). The log root can be relocated to any directory writable by the *Local System* account.

## Resolution Order

Both the *PowerShell* and *Go* code paths resolve the log root through the same fallback chain (first hit wins):

1. **Environment variable `K2S_LOG_ROOT`** — highest precedence; intended for short-lived overrides (test runs, install sessions).
2. **`%ProgramData%\K2s\setup.json` → `LogRoot`** — written automatically during `k2s install` from the resolved value below; consumed at runtime by services and CNI plugins.
3. **`cfg/config.json` → `configDir.logs`** — build-time / install-time default in the *K2s* installation tree.
4. **`<SystemDrive>:\var\log`** — legacy fallback when none of the above is set.

After resolution, environment variables (`%ProgramData%`, `%USERPROFILE%`, …) and a leading `~` are expanded, and the directory is created if missing.

## Changing the Default

Edit the value in `cfg/config.json` **before** `k2s install`:

```jsonc
"configDir": {
    "ssh":    "~/.ssh",
    "kube":   "~/.kube",
    "docker": "~/.docker",
    "k2s":    "C:\\ProgramData\\K2s",
    "logs":   "D:\\K2s-Logs"   // absolute path or env-var pattern
}
```

Or set the override at install time:

```console
$env:K2S_LOG_ROOT = "D:\K2s-Logs"
k2s install
```

The installer persists the resolved value into `setup.json` so subsequent service starts and Go-based CNI plugins (`bridge.exe`, `vfprules.exe`, `l4proxy.exe`, `cplauncher.exe`) read it without re-parsing `cfg/config.json`.

## Affected Producers

The configured root contains the following subfolders (created on demand):

| Subfolder            | Producer                                                 |
|----------------------|----------------------------------------------------------|
| `k2s.log`            | *K2s* orchestrator log (PowerShell + Go)                  |
| `containerd\`        | `containerd.exe` NSSM service                            |
| `kubelet\`           | `kubelet.exe` NSSM service                               |
| `kubeproxy\`         | `kube-proxy.exe` NSSM service                            |
| `flanneld\`          | `flanneld.exe` NSSM service                              |
| `dnsproxy\`          | `dnsproxy.exe` NSSM service                              |
| `httpproxy\`         | `httpproxy.exe` NSSM service                             |
| `windows_exporter\`  | `windows_exporter.exe` NSSM service                      |
| `containers\`, `pods\` | kubelet pod log redirection                            |
| `bridge\`, `vfprules\` | *K2s* CNI helpers (Go)                                  |

In current behavior, `pods` and `containers` may still be written under `<SystemDrive>:\var\log` even after log-root redirection, because their location is controlled by kubelet/container runtime behavior rather than only by K2s service wrapper paths.

> ⚠️  Kubelet writes a small number of paths unconditionally to `<SystemDrive>:\var\lib\kubelet\device-plugins`. That tree is **not** moved by this setting; only the log root is configurable.

## Uninstall Behavior

`k2s uninstall` removes:

1. The currently-configured log directory (resolved via the fallback chain).
2. The legacy `<SystemDrive>:\var` tree (only when it still contains the active log root).

If you relocated the logs *after* installing, the original `\var\log` may remain on disk and can be deleted manually.

## Troubleshooting

See [Diagnostics](../troubleshooting/diagnostics.md) for log inspection. The diagnostics page references `<install-drive>\var\log` as the default; substitute the resolved root from this page if you reconfigured it.
