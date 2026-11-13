<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Starting *K2s*
To start the *K8s* cluster and all accompanying services, run:
```console
k2s start
```

!!! note
    *K2s* will start automatically after the installation has finished.

### Windows Hyper-V startup failures

If the control-plane VM fails to start during installation or `k2s start`,
K2s logs the original Hyper-V error, VM identity, and attempt number for each
of its four start attempts. The final failure includes the last Hyper-V error.
Memory diagnostic failures are logged separately and do not replace that error.
Use the reported error and the Hyper-V VMMS/Worker Admin event logs to
investigate the cause; a failed VM start alone does not establish insufficient
memory.

### Windows reboot recovery and SSH

Windows startup recovery uses SSH to inspect and restore control-plane routes.
*K2s* restricts its private SSH key to the built-in Administrators group and
LOCAL SYSTEM, with inheritance disabled, so both elevated CLI commands and
the startup service can use it. Existing keys are secured before SSH or SCP
access without regenerating the key.

If the key cannot be secured or SSH authentication fails, recovery logs the
failure instead of treating it as a missing route. Resolve the reported SSH
error before retrying `k2s start`; restarting flannel cannot repair an
authentication failure.
### Windows Default Switch validation

On Windows, startup validates the Hyper-V Default Switch against the configured
K2s subnets before starting networking. If an existing switch's IPv4 address is
initially missing, startup observes it for up to 120 seconds to allow Windows
networking to initialize. Windows client hosts also observe an initially absent
switch because Windows can create it asynchronously during boot. Windows Server
hosts without a Default Switch skip this wait.
A conflicting switch is removed and revalidated before K2s networking starts.
If the switch remains absent, startup can continue; an existing switch without
an IPv4 address fails validation because its subnet cannot be checked.

During reboot recovery, startup also validates the switch after Windows network
reconstruction, before repairing Linux routes. K2s networking services are stopped
and confirmed stopped before removing a conflicting Default Switch. Startup then
starts flannel and waits for the Windows bridge endpoint and routes to become
ready. If Windows creates another conflicting switch during this phase, recovery
retries up to three times. It removes only the conflicting Default Switch, not
unrelated HNS networks. Service, bridge, or Linux route recovery failures are
reported instead of allowing incomplete recovery to appear successful.

Startup checks again before reporting success. This final check remains read-only;
a conflict appearing after recovery still fails startup. The already-running
early-return path uses only the initial validation. If recovery fails, allow
Windows networking to settle and retry `k2s start`.

### WSL network validation

When `k2s start` restarts the WSL control plane, K2s checks the actual WSL HNS
subnets before changing the host adapter address. A conflicting, missing, or
invalid subnet stops startup rather than allowing unverified networking.
The check does not remove or renumber shared WSL networks. See
[WSL installation](installing-k2s.md#wsl) for conflict handling.

### Additional Options

#### Skip Starting if Already Running
To skip starting the *K2s* cluster if it is already running, use the `--ignore-if-running` flag or its shortcut `-i`:
```console
k2s start --ignore-if-running
```
or
```console
k2s start -i
```

!!! note
    This option is useful to avoid unnecessary restarts of the cluster when it is already running.  