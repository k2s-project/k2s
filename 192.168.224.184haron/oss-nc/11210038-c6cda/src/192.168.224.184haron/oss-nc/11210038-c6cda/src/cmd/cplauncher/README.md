<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

### Overview
`cplauncher` starts a target process in a specified Windows network compartment and (optionally) injects a helper DLL (`cphook.dll`) which can perform per-thread compartment switching logic.

### Building the helper DLL (`cphook.dll`) with MinGW-w64
Install toolchain (example using Chocolatey if allowed):
```
choco install -y mingw
```
Build DLL (from this directory):
```
g++ -shared -o ..\..\..\bin\cni\cphook.dll .\cphook\cphook.c -liphlpapi -Wl,--out-implib,libcphook.a
```
You may then copy `cphook.dll` next to `cplauncher.exe` if you want it discovered automatically (see below).

### Building `cplauncher`
Automated build (repository helper):
```
c:\ws\k2s\bin\bgo.cmd -ProjectDir "c:\ws\k2s\cmd\cplauncher" -ExeOutDir "c:\ws\k2s\bin\cni"
```
Ad-hoc local build:
```
go build -o cplauncher.exe .
```

### Flags
```
	-compartment <id>         Compartment ID (required unless -label is used)
	-label <selector>         Kubernetes label selector resolving to exactly one pod (alternative to -compartment)
	-namespace <ns>           Namespace scope for -label (omit for all namespaces)
	-label-timeout <dur>      Timeout for label resolution (default 10s, e.g. 5s, 30s, 1m)
	-dll <path>               Helper DLL path (optional if cphook.dll is beside the executable)
	-export <name>            Export name inside the DLL (default: SetTargetCompartmentId)
	-self-env                 Do not perform remote export call; only set env vars for target to self-configure
	-no-inject                Do not inject any DLL (useful with -self-env)
	-env-name <var>           Name of variable carrying compartment for self-env mode (default: COMPARTMENT_ID)
	-dry-run                  Print planned actions then exit (no process creation/injection)
	-verbosity <level>        Log verbosity (debug|info|warn|error or integer levels)
	-v <level>                Alias for -verbosity
	-logs-keep <n>            Max number of previous log files to retain (default 30)
	-log-max-age <dur>        Optional age threshold for log deletion (e.g. 24h, 7d); empty disables age based pruning
	-wait-tree                Wait for the entire descendant process tree (Windows Job) to exit before returning; ensures cleanup if launcher dies
	-legacy-inject            Use legacy CreateRemoteThread injection (may trigger Windows Defender); default uses stealthier NtCreateThreadEx
	-version                  Print version information
```

### Default DLL Discovery
If `-dll` is omitted and `-no-inject` is NOT specified, `cplauncher` attempts to use `cphook.dll` located in the same directory as `cplauncher.exe`. If not found, execution aborts with an error. If `-no-inject` is set, `-dll` is ignored / optional.

### Environment Variables Set
Always: `COMPARTMENT_ID_ATTACH=<id>` (consumed by the injected DLL for thread setup).
If `-self-env`: additionally `<env-name>=<id>` (default `COMPARTMENT_ID`). Your target process can then call `SetCurrentThreadCompartmentId` itself.

### Examples
Resolve compartment from a unique pod label in all namespaces:
```
cplauncher -label app=my-service -- myapp.exe
```

Label + namespace (more specific):
```
cplauncher -label app=my-service -namespace prod -- myapp.exe
```

Run with automatic DLL discovery (assuming `cphook.dll` is alongside the exe):
```
cplauncher -compartment 42 -- myapp.exe -arg1
```

Explicit DLL path:
```
cplauncher -compartment 42 -dll C:\k2s\cni\cphook.dll -- myapp.exe
```

Self-managed mode (no remote export invocation, still inject DLL for its other logic):
```
cplauncher -compartment 42 -self-env -- myapp.exe
```

Pure environment mode (no DLL at all):
```
cplauncher -compartment 42 -self-env -no-inject -- myapp.exe
```

Dry run (show what would happen, no process started):
```
cplauncher -compartment 42 -dry-run -dll C:\k2s\cni\cphook.dll -- myapp.exe
```

Dry run with label resolution:
```
cplauncher -label app=my-service -dry-run -- myapp.exe
```

### Logging
Logs are written to `<SystemDrive>\\var\\log\\cplauncher` using structured `slog`. Each execution creates a new file named `cplauncher-<pid>-<unixTs>.log`.
Retention: after starting, the tool prunes old logs keeping at most `-logs-keep` newest (excluding the current) and optionally any older than `-log-max-age`.
On fatal errors the tool now prints the most recent ERROR lines (or last lines) from the log file to stderr for quick triage.

### Exit Codes
`0` success; non-zero indicates failure in process creation, DLL injection, export invocation, or resume.

### Troubleshooting
| Symptom | Hint |
|---------|------|
| "dll not specified...default not found" | Place `cphook.dll` beside the exe or pass `-dll` explicitly. |
| Remote export call fails | Verify export name (`-export`), ensure DLL exports undecorated function. |
| Access denied | Run elevated if required for compartment operations. |
| Compartment effects not visible | Target threads may need explicit calls when using `-self-env`. |
| Label selector matches multiple pods | Refine with `-namespace` or a more specific selector; tool now fails instead of picking first. |
| Pod has no IP yet | Wait until pod is Running; relaunch with same `-label`. |
| ipconfig scan failed for ip ... | Ensure `ipconfig /allcompartments` lists the pod IP; if not, wait until networking initializes. |

<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

### Build the cphook.dll with mingw
## choco install -y mingw (install if not available)
g++ -shared -o ..\..\..\bin\cni\cphook.dll .\cphook\cphook.c -liphlpapi -Wl,--out-implib,libcphook.a

## build compartment launcher
c:\ws\k2s\bin\bgo.cmd -ProjectDir "c:\ws\k2s\cmd\cplauncher" -ExeOutDir "c:\ws\k2s\bin\cni"
# or for testing
go build -o cplauncher.exe .

## How to test manually
# setup buildonly setup (without K8s)
k2s install buildonly
# build a windows container somehwer to initialize also the docker daemon
k2s image build -w ...
# run a windows container in order to create a separate compartment
docker run --rm -it --name nano --network nat mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd
# start an external executable with cplaucher in the compartment of the container
c:\ws\k2s\bin\cni\cplauncher.exe -compartment 2 -- c:\ws\s\examples\albums-golang-win\albumswin.exe
c:\ws\k2s\bin\cni\cplauncher.exe -label app=albums-win1 -namespace k2s -- c:\ws\s\examples\albums-golang-win\albumswin.exe

### Windows Defender Considerations
⚠️ **IMPORTANT**: The DLL injection technique (creating a suspended process, allocating remote memory, and creating remote threads) **WILL** trigger behavioral detection in Windows Defender Real-time Protection, even with the stealth mode enabled.

**Symptoms**: `cplauncher` crashes sporadically after the "dll injected successfully" or "export offset computed" log entry, with no error message. This indicates Windows Defender is terminating the process.

**Required Solution - Add Windows Defender Exclusion** (requires administrator privileges on the test/deployment machine):
```powershell
# RECOMMENDED: Exclude the entire cplauncher directory (most reliable)
Add-MpPreference -ExclusionPath "C:\ws\k2s\bin\cni"

# If you need to exclude just the specific executable, use FULL PATH:
Add-MpPreference -ExclusionPath "C:\ws\k2s\bin\cni\cplauncher.exe"

# Process-based exclusion (less reliable, may not work in all cases):
Add-MpPreference -ExclusionProcess "cplauncher.exe"
```

**IMPORTANT**: If you used process-based exclusion (`-ExclusionProcess`) and still see crashes, **remove it and use path-based exclusion instead**:
```powershell
# Remove process exclusion
Remove-MpPreference -ExclusionProcess "cplauncher.exe"

# Add path exclusion (more reliable)
Add-MpPreference -ExclusionPath "C:\ws\k2s\bin\cni"
```

**Verify exclusion was added:**
```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
Get-MpPreference | Select-Object -ExpandProperty ExclusionProcess
```

**Alternative approaches**:

1. **Use legacy injection mode** (if you want to test different behavior):
   ```
   cplauncher -legacy-inject -compartment 42 -- myapp.exe
   ```
   Note: Both stealth and legacy modes require the Defender exclusion; the stealth mode just uses less common APIs.

2. **For production deployment**: Code-sign the `cplauncher.exe` binary with a trusted certificate to reduce antivirus sensitivity.

3. **If you cannot add exclusions**: The only workaround is to disable Windows Defender Real-time Protection entirely (not recommended for production systems):
   ```powershell
   Set-MpPreference -DisableRealtimeMonitoring $true
   ```

**Default behavior**: `cplauncher` uses a stealthier injection method (`NtCreateThreadEx` with timing delays) by default, but this is **NOT sufficient** to bypass Windows Defender - the exclusion is still required.


