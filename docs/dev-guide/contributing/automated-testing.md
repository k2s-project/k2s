<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Automated Testing
## Automate Everything
The ultimate goal is to automate every test case and type, i.e.:

- Unit tests
- Integration Tests
- e2e tests / system tests / acceptance tests / executable specifications (BDD-style, see also [*K2s* Acceptance Testing](#k2s-acceptance-testing))

!!! info
    Acceptance tests might require a running *K2s* cluster.

### Provisioning Hostname Checks

The provisioning hostname query allows up to four SSH attempts, with a
three-second delay between failed attempts. This retries only the read-only
`hostname` command, not installation or role-assignment operations. A failed
query is reported as an SSH failure; hostname validation runs only after a
successful query. The regression cases are in
`common-setup.module.unit.tests.ps1` under the Windows Linux-node distro module.

### Windows Workload Readiness Diagnostics

If the core acceptance suite exhausts its Windows HTTP readiness retries, it
collects evidence without changing the readiness criteria. The suite probes
Service DNS, Service ClusterIPs, and EndpointSlice Pod IPs from both the host
and the Linux curl pod. It also captures Kubernetes resources, forwarding
logs, and Windows adapter, route, and HNS state. These observations help
distinguish DNS, Service forwarding, and direct endpoint failures; they do
not identify the failing component on their own.

Diagnostic commands have a ten-second timeout and share a four-minute
collection budget. Query and probe failures are recorded without replacing
the original readiness failure or preventing independent probes.

### Cross-Node Communication Diagnostics

The node acceptance suite preserves curl error output (`-sS`) for pod
communication checks. On failure, it probes the same destination's Service IP
and direct Pod IP from the failing source container, without DNS or proxy use.
The generated node workloads use port 80 for both paths.

Failure-only collection also records the Service, EndpointSlices, pods, nodes,
Flannel/kube-proxy logs, and Windows routes/HNS state. For participating Linux
nodes with known SSH configuration, it collects host routes, route lookups,
and iptables counters using the existing key and strict host-key checking.
Missing tools, SSH access, and diagnostic failures are reported without
replacing the original assertion failure. Collection has a two-minute overall
budget and a ten-second limit per command; it does not retry the test or
change network state. Evidence appears under `NODE-NET DIAG` in test output.

## Prerequisites
[Install *Pester*](#install-pester) and [Install *Ginkgo*](https://onsi.github.io/ginkgo/#installing-ginkgo){target="_blank"}.

!!! tip
    When running the [Main Script: execute_all_tests.ps1](#main-script-execute_all_testsps1) for the first time, those prerequisites are installed automatically in the correct version.

## Windows Cluster GitHub Actions Workflow

The **CI - Windows Cluster** workflow (`.github/workflows/ci-windows-cluster.yml`)
builds all ten Windows executables, runs `k2s install`, verifies that both the
Linux control plane and Windows worker are Ready, and runs the existing
`test/e2e/cluster/core` acceptance suite. The suite deploys Linux and Windows
workloads and checks DNS, Service forwarding, cross-node connectivity and
internet access. This is a core cluster test, not the complete addon or
lifecycle test matrix.

### Provision the Runner Before Dispatch

Use a **dedicated, disposable x64 Windows Server 2022 or 2025 runner VM** with
labels `self-hosted`, `Windows`, `X64`, and `k2s-hyperv`. Do not assume that
`windows-latest` or an arbitrary larger runner exposes nested virtualization.
The workflow requires at least 8 logical CPUs, 16 GiB RAM (32 GiB recommended),
10 GiB free RAM and 100 GiB free disk space on the `C:` system drive. The
control-plane VM receives 6 CPUs, 6 GiB static memory and a 50 GiB disk.

If the runner itself is a VM, expose virtualization extensions **on the outer
hypervisor while the runner VM is powered off**, not inside the workflow:

```powershell
Set-VMProcessor -VMName '<runner-vm>' -ExposeVirtualizationExtensions $true
Set-VMMemory -VMName '<runner-vm>' -DynamicMemoryEnabled $false
```

For Azure or another cloud, select a VM family/size and security configuration
that explicitly supports nested Hyper-V; enabling Windows features alone does
not provide this capability. For physical runners, enable virtualization in
firmware. The workflow creates, starts and removes a diskless probe VM to
verify actual VM startup, rather than relying only on CPU flags.

Enable these features in an elevated Windows PowerShell session, then **reboot
before registering/starting the runner**:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName @(
    'Microsoft-Hyper-V',
    'Microsoft-Hyper-V-Management-PowerShell',
    'Containers',
    'VirtualMachinePlatform'
) -All -NoRestart
Set-ExecutionPolicy RemoteSigned -Force
Restart-Computer
```

Install the Microsoft Visual C++ v14 **x64** redistributable, `curl.exe`
>= 7.71.0, OpenSSH >= 8, and Git. Run the Actions runner with an elevated local
administrator token and a usable profile; the job uses Windows PowerShell 5.1.
Go is installed by `actions/setup-go`, using the version from `go.mod`.
No preinstalled `k2s.exe`, Ginkgo or Pester is needed.

Stop Docker Desktop/Engine. Start with no existing K2s installation, Hyper-V
VMs, external virtual switches or `C:\k2s-ci` staging folder. Allow downloads
and registry access from the host and nested VM, including the configured
`shsk2s.azurecr.io` registry. Ensure host/VPN/cloud networks do not overlap the
subnets in `cfg/config.json` (by default `172.19.1.0/24`, `172.20.0.0/16`,
`172.21.0.0/16` and `172.22.1.0/24`). Preserve GitHub runner connectivity when
K2s creates switches and changes DNS/routing. K2s uses internal switches/NAT;
do not create an external switch on the runner to provide nested networking.
Leave `HTTP_PROXY`/`HTTPS_PROXY` unset in the runner environment; configure
any required proxy through Windows as described in the installation guide.

### Dispatch, Results and Runner Disposal

Create the `k2s-windows-e2e` GitHub environment with required reviewers and
deployment branch restrictions, and restrict the runner group to trusted
repositories/workflows. Under **Actions > CI - Windows Cluster > Run workflow**,
select a reviewed branch. To test a PR, dispatch its reviewed head branch
within this repository; do not execute untrusted fork code on this runner.
There are deliberately no `pull_request` or `pull_request_target` triggers.
Runs are serialized and do not cancel an active installation.

Source (including credential-free Git metadata for build version information)
is staged at `C:\k2s-ci` because installation on the system drive is recommended.
The workflow uses the repository's `BuildGoExe.ps1 -BuildAll` helper before:

```console
C:\k2s-ci\k2s.exe install --master-cpus 6 --master-memory 6GB --master-disk 50GB --output
```

Ginkgo is invoked through `go run` at the version pinned in `go.mod`, with one
process and `--fail-on-empty`. JUnit results, failure-only Kubernetes/Hyper-V
diagnostics and `k2s.log` are retained for seven days. Logs may contain internal
network information; review them before sharing. Kubeconfigs, SSH keys and
full system dumps are not uploaded.

The job attempts `k2s uninstall --output` even after installation/test failure,
and uploads evidence first. **Discard/reimage the runner VM after every run**,
including success, cancellation or timeout. Register it as an ephemeral
runner (`config.cmd --ephemeral`) and arrange infrastructure-side disposal;
ephemeral registration alone does not delete the VM. Uninstall cannot restore
all machine changes: installation modifies networking, Windows services,
registry settings and Defender settings. Partial installs may also leave
provisioning VMs. Never reuse this runner for unrelated jobs or treat workflow
cleanup as a substitute for VM disposal.
  
## Main Script: execute_all_tests.ps1
The main entry point for automated testing is the script `execute_all_tests.ps1`, whether being executed locally or in CI/CD workflows. It is not mandatory, but recommended to use this script instead of running *Pester* or *Ginkgo* commands directly due to the following features of the `execute_all_tests.ps1` script:

- Run all test suites in this repository (*PowerShell*- or *Go*-based tests)
- Automatic installation of the required testing frameworks on-the-fly when they do not exist in the required version (i.e. *Pester* and *Ginkgo*)
- Tags/labels filtering that applies both to *PowerShell* and *Go*
- Options to exclude either *PowerShell* or *Go* tests
- Unified test execution report

!!! example
    ```powershell
    <repo>\test\execute_all_tests.ps1 -Tags unit -ExcludeGoTests
    ```

The preceding example would execute all *PowerShell*-based tests tagged with `unit`.

!!! tip
    Inspect the [execute_all_tests.ps1](https://github.com/k2s-project/k2s/blob/main/test/execute_all_tests.ps1){target="_blank"} script for further parameter details and descriptions.<br/>
    See [Commonly Used Tags](tags-labels.md#commonly-used-tags) for commonly used labels/tags.
    
## Automated Testing with Pester
!!! note
    For a quick start and command overview, see [Pester Quick Start](https://pester.dev/docs/quick-start){target="_blank"}.
### Install Pester
!!! info
    [Pester](https://github.com/pester/Pester){target="_blank"} comes pre-installed on Win 10 or later.

To check the installed version, run:
```PowerShell
Import-Module Pester -Passthru
```

This output will be similar to:
``` title="Output"
ModuleType Version    Name    ExportedCommands
---------- -------    ----    ----------------
Script     3.4.0      Pester  {AfterAll, AfterEach, Assert-MockCalled, Assert-VerifiableMocks...}
```
!!! tip
    It is highly recommended to update Pester to the latest version to have a consistent set of test APIs.
 
### Update Pester
If Pester was not installed explicitly yet (i.e., the version shipped with Windows is installed), run:
```PowerShell
Install-Module Pester -Force -SkipPublisherCheck
```

For subsequent updates, run:
```PowerShell
Update-Module -Name Pester
```

### Run Pester
To start test discovery and execution, run:
```PowerShell
Invoke-Pester .\<test file>.tests.ps1
```
!!! info
    Pester discovers test files via naming convention **\*.\[T|t\]ests.ps1**

To see detailed output, run:
```PowerShell
Invoke-Pester -Output Detailed .\<test file>.Tests.ps1
```
To include/exclude tests by tags, run:
```PowerShell
Invoke-Pester -Tag "acceptance" -ExcludeTag "slow", "linuxOnly" .\<test file>.Tests.ps1
```

#### Code Coverage
To calculate the code coverage of a test run, additionally specify the file(s) under test:
```PowerShell
Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1
```

To export the code coverage results as [JaCoCo](https://www.jacoco.org/){target="_blank"} XML file, specify the output file:
```PowerShell
Invoke-Pester .\<test file>.Tests.ps1 -CodeCoverage .\<file-under-test>.ps1 -CodeCoverageOutputFile <some dir>\coverage.xml
```

!!! note
    See [Pester Code Coverage](https://pester.dev/docs/usage/code-coverage/){target="_blank"} for more options.

### Log Output Redirection
When executing *K2s* scripts inside *Pester* test functions, it is recommended to execute these scripts in a separate *PowerShell* session, so that the called scripts still log to the *K2s* log files due to the current logging implementation.

#### Don't
```PowerShell
# ...
$enableScript = "$PSScriptRoot\Enable.ps1"
# ...
It 'does not log to log file :-(' {
    $output = $(&$enableScript -ShowLogs) *>&1 # output redirect, but no log file entries
    # ...
}
# ...
```

#### Do
```PowerShell
# ...
$enableScript = "$PSScriptRoot\Enable.ps1"
# ...
It 'logs to log file :-)' {
    $output = powershell -Command "$enableScript -ShowLogs" *>&1 # output redirect and log file entries
    # ...
}
# ...
```

### Suppress Code Analysis
*Pester* requires a certain test code structure that can lead to code analyzer warnings, e.g. in this case:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```
The analyzer would complain:
!!! quote
    The variable 'moduleName' is assigned but never used. *PSScriptAnalyzer(PSUseDeclaredVarsMoreThanAssignments)*

To mitigate this, suppress this warning like the following:
```PowerShell
BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}
```

## Automated Testing with Ginkgo/Gomega
### Log Output Redirection
For diagnostic logging, *k2s* CLI uses [slog](https://pkg.go.dev/log/slog){target="_blank"}. To redirect the log output to *Ginkgo*, set the *Ginkgo* logger as follows (*Ginkgo* uses [logr](https://github.com/go-logr/logr/){target="_blank"} internally):
```go
var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})
```

This enables control over *slog* output, i.e. the output can be enabled when running *Ginkgo* in verbose mode (`ginkog -v`) and be omitted in non-verbose mode.

### *K2s* Acceptance Testing
!!! info
    **The acceptance tests focus on testing *K2s* from a user's point of view** in an automated, repeatable and reproduceable fashion. They are intended to cover all available features across the various [Supported OS Versions](../../op-manual/os-support.md). They are not intended to cover all the edge and corner cases, though (Unit Tests might be a better fit there).

**To mark acceptance tests as such** and provide additional information about test prerequisites (e.g. a running *K2s* cluster, internet connectivity, etc.), **use [Tags/Labels](tags-labels.md)**.

#### Tech Stack
The tech stack mostly comprises the [*Go* testing package](https://pkg.go.dev/testing){target="_blank"}, [*Ginkgo*](https://onsi.github.io/ginkgo/#top){target="_blank"}/[*Gomega*](https://onsi.github.io/gomega/#top){target="_blank"} and the *[K2s Testing Framework](https://github.com/k2s-project/k2s/blob/main/k2s/test/framework/README.md){target="_blank"}* to write acceptance tests in an efficient way without having to write boilerplate code repeatedly. The levels of abstraction are depicted in the following:

```mermaid
flowchart TD
    A(K2s Testing Framework) --> |utilizes|B(Ginkgo/Gomega)
    B --> |utilizes|C(Go Testing Package)
```

#### Implementing Tests/Specs
See [*K2s* Acceptance Tests/Specs](https://github.com/k2s-project/k2s/blob/main/k2s/test/README.md){target="_blank"}.

#### Executing Tests/Specs
Multiple options exist to run *Go*-based test specs:

- [Main Script: execute_all_tests.ps1](#main-script-execute_all_testsps1) - Recommended, provides most flexibility
- Running *Ginkgo*:
    ```console
    ginkgo <dir-with-test-specs>
    ```
- Running `go test`:
    ```console
    cd <dir-with-test-specs>
    go test 
    ```

!!! tip "Ginkgo and go test"
    Use `-v` flag to enable verbose test execution output.
    
    Use `-r` or `./...` to scan for and execute tests recursively starting in the given directory.

!!! tip "Optimizing Test Execution Speed"
    When executing *Go*-based tests, the packages containing the test specs will get built right before test execution. This compilation is rather time-consuming compared to the actual test runs, especially when executing short-running unit tests.

    To optimize the overall execution speed, the packages containing test specs can be build before hand, either through `ginkgo build` or `go test -c`.