# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

function Get-HeadlampManifestsDirectory {
    return "$PSScriptRoot\manifests\headlamp"
}

function Get-HeadlampChartDirectory {
    return "$PSScriptRoot\manifests\chart"
}

function Get-HeadlampChartPath {
    $chartDir = Get-HeadlampChartDirectory
    $charts = @(Get-ChildItem -Path $chartDir -Filter 'headlamp-*.tgz' -ErrorAction SilentlyContinue)
    if ($charts.Count -eq 0) {
        return $null
    }
    return $charts[0].FullName
}

function Install-HeadlampViaHelm {
    param ([string]$InfraNodeSelector = '')
    $selector = Get-AddonEffectiveInfrastructureSelector -Name 'dashboard' -Selector $InfraNodeSelector
    $chartDir = Get-HeadlampChartDirectory
    $chartPath = Get-HeadlampChartPath
    if ($null -eq $chartPath) {
        throw '[Dashboard] No headlamp Helm chart .tgz found in manifests/chart/'
    }
    $valuesPath = Join-Path $chartDir 'values.yaml'
    if (-not (Test-Path $valuesPath)) {
        throw "[Dashboard] values.yaml not found at '$valuesPath'"
    }

    $renderedValues = $null
    try {
    if (-not [string]::IsNullOrWhiteSpace($selector)) {
        $renderedValues = New-AddonPlacementManifest -AddonName 'dashboard' -ManifestDirectory $chartDir -Selector $selector
        $valuesPath = $renderedValues
    }
    $nsExists = (Invoke-Kubectl -Params 'get', 'namespace', 'dashboard', '--ignore-not-found').Output
    if (-not $nsExists) {
        Write-Log '[Dashboard] Creating dashboard namespace' -Console
        (Invoke-Kubectl -Params 'create', 'namespace', 'dashboard').Output | Write-Log
        (Invoke-Kubectl -Params 'label', 'namespace', 'dashboard', 'app.kubernetes.io/name=headlamp', '--overwrite').Output | Write-Log
    }

    Write-Log "[Dashboard] Installing Headlamp via Helm chart: $(Split-Path $chartPath -Leaf)" -Console
    $helmResult = Invoke-Helm -Params @(
        'upgrade', '--install', 'headlamp', $chartPath,
        '--namespace', 'dashboard',
        '--values', $valuesPath
    )
    $helmResult.Output | Write-Log
    if (-not $helmResult.Success) {
        throw '[Dashboard] helm upgrade --install failed. See log for details.'
    }
    }
    finally {
        if ($renderedValues) { Remove-Item -LiteralPath $renderedValues -Force -ErrorAction SilentlyContinue }
    }
}

function Uninstall-HeadlampViaHelm {
    $releaseExists = (Invoke-Helm -Params @('list', '-n', 'dashboard', '-q')).Output
    if ($releaseExists -match 'headlamp') {
        Write-Log '[Dashboard] Uninstalling Headlamp Helm release' -Console
        $helmResult = Invoke-Helm -Params @('uninstall', 'headlamp', '--namespace', 'dashboard', '--wait', '--timeout', '2m0s')
        $helmResult.Output | Write-Log
        if (-not $helmResult.Success) {
            Write-Log '[Dashboard] Warning: helm uninstall returned non-zero; continuing cleanup' -Console
        }
    }
    else {
        Write-Log '[Dashboard] No headlamp Helm release found; skipping helm uninstall' -Console
    }

    (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'headlamp-admin', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'namespace', 'dashboard', '--ignore-not-found').Output | Write-Log
}

function Enable-MetricsServer {
    &"$PSScriptRoot\..\metrics\Enable.ps1" -ShowLogs:$ShowLogs
}

function Wait-ForHeadlampAvailable {
    # 300s (not 200s) so a slow first-time pull of the Headlamp base image
    # (ghcr.io/headlamp-k8s/headlamp) on cold/offline/proxied nodes cannot trip the
    # readiness wait right at the boundary. This mirrors Wait-ForHeadlampRollout's
    # 300s budget, which absorbs plugin init-container image pulls for the same reason.
    return (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=headlamp' -Namespace 'dashboard' -TimeoutSeconds 300)
}

function Write-HeadlampUsageForUser {
    @"
                DASHBOARD ADDON (Headlamp) - USAGE NOTES
 To open the Headlamp dashboard, please use one of the options:

 Option 1: Access via ingress
 Please install either ingress nginx, ingress traefik, or ingress nginx gateway addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dashboard
 k2s addons enable dashboard
 The Headlamp dashboard will be accessible on the following URL: https://k2s.cluster.local/dashboard/

 Option 2: Port-forwarding
 Use port-forwarding to the headlamp service using the command below:
 kubectl port-forward svc/headlamp -n dashboard 4466:4466

 In this case, the Headlamp dashboard will be accessible on the following URL: http://localhost:4466/dashboard/
 It is not necessary to use port 4466. Please feel free to use a port number of your choice.

 NOTE: Headlamp will show a token login screen - this is expected and normal.
 To log in, generate a ServiceAccount token with the command below and paste it into the login screen:
    kubectl -n dashboard create token headlamp --duration 24h

 Read more: https://headlamp.dev/docs/latest/
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

# ── Headlamp Plugin Framework ──────────────────────────────────────────────────
# Offline-first, bidirectional Headlamp plugin injection via Kubernetes
# init-containers.
#
# Activation is driven by *capability detection* (actual cluster state), not
# addon ownership, so plugins activate correctly regardless of which installer
# provided the capability (ingress/nginx, ingress/traefik, security, or a
# third-party tool).
#
# Registry: Get-RegisteredHeadlampPlugins — add new plugins here.
# Detectors: Test-*CapabilityAvailable — one per plugin, private to this module.
# Sync entry point: Sync-HeadlampPlugins — called from every addon
#   Enable.ps1 / Disable.ps1 that can affect a registered capability.
# ──────────────────────────────────────────────────────────────────────────────

# ── Capability Detectors ──────────────────────────────────────────────────────

function Test-NamespaceActive {
    <#
    .SYNOPSIS
    Returns $true only when the given namespace exists AND is in the 'Active' phase.

    .DESCRIPTION
    A namespace that is being torn down lingers in the 'Terminating' phase (its
    deletion is asynchronous and finalizer-driven). Capability detectors must NOT
    treat a Terminating namespace as a live capability: doing so makes plugin removal
    non-deterministic when Sync-HeadlampPlugins runs immediately after an addon's
    uninstall step (e.g. security Disable.ps1 -> Uninstall-CertManager -> Sync).
    Keying on the phase makes removal deterministic on the first sync.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string] $Name
    )
    $phase = (Invoke-Kubectl -Params 'get', 'namespace', $Name, '-o', 'jsonpath={.status.phase}', '--ignore-not-found').Output
    return ($phase -eq 'Active')
}

function Test-FluxCapabilityAvailable {
    <#
    .SYNOPSIS
    Returns $true when Flux CD is present in the cluster, regardless of how it was installed.
    Detection checks: flux-system namespace (Active), then Flux kustomization CRD.
    #>
    Write-Log '[Dashboard][Plugin] Checking Flux capability'
    if (Test-NamespaceActive -Name 'flux-system') {
        Write-Log '[Dashboard][Plugin] Flux: flux-system namespace found'
        return $true
    }
    $crd = (Invoke-Kubectl -Params 'get', 'crd', 'kustomizations.kustomize.toolkit.fluxcd.io', '--ignore-not-found').Output
    if ($crd) {
        Write-Log '[Dashboard][Plugin] Flux: Flux kustomization CRD found'
        return $true
    }
    Write-Log '[Dashboard][Plugin] Flux capability not detected'
    return $false
}

function Test-CertManagerCapabilityAvailable {
    <#
    .SYNOPSIS
    Returns $true when cert-manager is present in the cluster, regardless of which addon
    installed it (ingress/nginx, ingress/traefik, ingress/nginx-gw, security, or other).
    Detection checks: cert-manager namespace (Active), then certificates.cert-manager.io CRD.
    #>
    Write-Log '[Dashboard][Plugin] Checking cert-manager capability'
    if (Test-NamespaceActive -Name 'cert-manager') {
        Write-Log '[Dashboard][Plugin] cert-manager: namespace found'
        return $true
    }
    $crd = (Invoke-Kubectl -Params 'get', 'crd', 'certificates.cert-manager.io', '--ignore-not-found').Output
    if ($crd) {
        Write-Log '[Dashboard][Plugin] cert-manager: certificates CRD found'
        return $true
    }
    Write-Log '[Dashboard][Plugin] cert-manager capability not detected'
    return $false
}

function Test-PrometheusCapabilityAvailable {
    <#
    .SYNOPSIS
    Returns $true when Prometheus is present in the cluster, regardless of how it was installed.
    Detection checks: monitoring namespace (Active), then prometheuses.monitoring.coreos.com CRD,
    then prometheus-operated service.
    #>
    Write-Log '[Dashboard][Plugin] Checking Prometheus capability'
    if (Test-NamespaceActive -Name 'monitoring') {
        Write-Log '[Dashboard][Plugin] Prometheus: monitoring namespace found'
        return $true
    }
    $crd = (Invoke-Kubectl -Params 'get', 'crd', 'prometheuses.monitoring.coreos.com', '--ignore-not-found').Output
    if ($crd) {
        Write-Log '[Dashboard][Plugin] Prometheus: prometheuses CRD found'
        return $true
    }
    $svc = (Invoke-Kubectl -Params 'get', 'service', 'prometheus-operated', '-n', 'monitoring', '--ignore-not-found').Output
    if ($svc) {
        Write-Log '[Dashboard][Plugin] Prometheus: prometheus-operated service found'
        return $true
    }
    Write-Log '[Dashboard][Plugin] Prometheus capability not detected'
    return $false
}

function Test-KedaCapabilityAvailable {
    <#
    .SYNOPSIS
    Returns $true when KEDA (Kubernetes Event-Driven Autoscaling) is present in the cluster,
    regardless of how it was installed (the K2s 'autoscaling' addon or an external KEDA install).
    Detection checks: autoscaling namespace (Active), then scaledobjects.keda.sh CRD.
    Deliberately does NOT key on built-in HorizontalPodAutoscaler (autoscaling/v2), which is
    present on every cluster and would make the plugin always-on.
    #>
    Write-Log '[Dashboard][Plugin] Checking KEDA capability'
    if (Test-NamespaceActive -Name 'autoscaling') {
        Write-Log '[Dashboard][Plugin] KEDA: autoscaling namespace found'
        return $true
    }
    $crd = (Invoke-Kubectl -Params 'get', 'crd', 'scaledobjects.keda.sh', '--ignore-not-found').Output
    if ($crd) {
        Write-Log '[Dashboard][Plugin] KEDA: scaledobjects CRD found'
        return $true
    }
    Write-Log '[Dashboard][Plugin] KEDA capability not detected'
    return $false
}


# ── Plugin Registry ───────────────────────────────────────────────────────────

function Get-RegisteredHeadlampPlugins {
    <#
    .SYNOPSIS
    Returns all K2s Headlamp plugin registrations.

    .DESCRIPTION
    Each registration is a PSCustomObject with:
      - Name     : init-container name, unique key (e.g. 'flux-plugin')
      - Image    : OCI image reference (must be present in the offline package)
      - Detector : ScriptBlock that returns $true when the capability is live in the cluster

    Activation is capability-based (not addon-state-based), so plugins activate
    whenever the underlying technology is present — regardless of which K2s addon
    or external tool installed it.
    #>
    return @(
        [pscustomobject]@{
            Name     = 'flux-plugin'
            Image    = 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0'
            Detector = { Test-FluxCapabilityAvailable }
        },
        [pscustomobject]@{
            Name     = 'cert-manager-plugin'
            Image    = 'shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.1'
            Detector = { Test-CertManagerCapabilityAvailable }
        },
        [pscustomobject]@{
            Name     = 'prometheus-plugin'
            Image    = 'shsk2s.azurecr.io/headlamp-plugin-prometheus:0.9.1'
            Detector = { Test-PrometheusCapabilityAvailable }
        },
        [pscustomobject]@{
            Name     = 'keda-plugin'
            Image    = 'shsk2s.azurecr.io/headlamp-plugin-keda:0.1.2'
            Detector = { Test-KedaCapabilityAvailable }
        }
    )
}

function New-PluginInitContainer {
    <#
    .SYNOPSIS
    Creates a plugin init-container configuration object.

    .DESCRIPTION
    The returned object describes one Kubernetes init-container that copies compiled
    plugin files from the OCI image into the shared Headlamp plugins emptyDir volume.

    .PARAMETER Name
    The init-container name.  Used as the plugin sub-directory under the plugins dir.

    .PARAMETER Image
    The OCI image reference.  The image must expose compiled plugin files at /plugins/<Name>/.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Image
    )
    Write-Log "[Dashboard][Plugin] Building init-container config: name='$Name' image='$Image'"
    return [pscustomobject]@{
        Name  = $Name
        Image = $Image
    }
}

# Headlamp's plugins directory as configured in values.yaml (pluginsDir).
# MUST match the value in addons/dashboard/manifests/chart/values.yaml.
$script:HeadlampPluginsDir  = '/tmp/headlamp/plugins'
$script:HeadlampPluginsVol  = 'headlamp-plugins'
$script:HeadlampContainerName = 'headlamp'

function Build-PluginPatchJson {
    <#
    .SYNOPSIS
    Builds the escaped JSON string for a kubectl --type=strategic patch of the headlamp
    Deployment.  The patch covers initContainers, the shared emptyDir volume, and the
    volumeMount on the main headlamp container.

    .PARAMETER K2sInitContainers
    The complete desired set of K2s plugin init-containers (Name + Image objects).
    Strategic merge adds/updates entries by name; existing non-K2s init-containers
    are left untouched.

    .PARAMETER NamesToRemove
    K2s init-container names that should be removed from the Deployment.
    Each entry produces a strategic-merge $patch:delete directive.
    #>
    param (
        [array] $K2sInitContainers = @(),
        [array] $NamesToRemove     = @()
    )

    $pluginsDir = $script:HeadlampPluginsDir
    $volName    = $script:HeadlampPluginsVol
    $ctrName    = $script:HeadlampContainerName

    # Nothing to patch
    if ($K2sInitContainers.Count -eq 0 -and $NamesToRemove.Count -eq 0) {
        return $null
    }

    # ── Init-containers section ────────────────────────────────────────────────
    $icParts = @()

    # Entries to add / update (by name merge key)
    foreach ($ic in $K2sInitContainers) {
        $n   = $ic.Name
        $img = $ic.Image
        $cp  = 'mkdir -p ' + $pluginsDir + '/' + $n + ' && cp -r /plugins/' + $n + '/. ' + $pluginsDir + '/' + $n + '/'
        $icParts += '{\"name\":\"' + $n + '\",\"image\":\"' + $img + '\",' +
                    '\"command\":[\"sh\",\"-c\",\"' + $cp + '\"],' +
                    '\"volumeMounts\":[{\"name\":\"' + $volName + '\",\"mountPath\":\"' + $pluginsDir + '\"}]}'
    }

    # Entries to delete
    foreach ($name in $NamesToRemove) {
        $icParts += '{\"name\":\"' + $name + '\",\"$patch\":\"delete\"}'
    }

    $icJson = $icParts -join ','

    # ── Volume + main-container mount section ─────────────────────────────────
    if ($K2sInitContainers.Count -gt 0) {
        # Plugins active: ensure the shared volume and the main-container mount exist.
        # Strategic merge adds them by name if absent; no-ops if already present.
        $volJson  = '{\"name\":\"' + $volName + '\",\"emptyDir\":{}}'
        $mntJson  = '{\"name\":\"' + $volName + '\",\"mountPath\":\"' + $pluginsDir + '\"}'
        $ctrJson  = '{\"name\":\"' + $ctrName + '\",\"volumeMounts\":[' + $mntJson + ']}'
    }
    else {
        # No plugins active: delete the shared volume and the main-container mount.
        # Strategic merge $patch:delete is a no-op when the element is already absent.
        $volJson  = '{\"name\":\"' + $volName + '\",\"$patch\":\"delete\"}'
        $mntJson  = '{\"mountPath\":\"' + $pluginsDir + '\",\"$patch\":\"delete\"}'
        $ctrJson  = '{\"name\":\"' + $ctrName + '\",\"volumeMounts\":[' + $mntJson + ']}'
    }

    return '{\"spec\":{\"template\":{\"spec\":{' +
           '\"volumes\":[' + $volJson + '],' +
           '\"initContainers\":[' + $icJson + '],' +
           '\"containers\":[' + $ctrJson + ']' +
           '}}}}'
}

function Get-CurrentPluginInitContainers {
    <#
    .SYNOPSIS
    Reads the current initContainers from the running headlamp Deployment.
    Returns an empty array when the Deployment does not exist or has no initContainers.
    #>
    $result = Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'json', '--ignore-not-found'
    if (-not $result.Output) {
        return @()
    }
    try {
        $deployment     = $result.Output | ConvertFrom-Json
        $initContainers = $deployment.spec.template.spec.initContainers
        if ($null -eq $initContainers) { return @() }
        return @($initContainers)
    }
    catch {
        Write-Log "[Dashboard][Plugin] Warning: could not parse deployment JSON when reading initContainers: $_"
        return @()
    }
}

function Apply-HeadlampPluginPatch {
    <#
    .SYNOPSIS
    Applies (or removes) K2s Headlamp plugin init-containers on the headlamp Deployment.

    .DESCRIPTION
    Compares the desired set of K2s plugin init-containers against the live Deployment
    by both init-container NAME and IMAGE.  A name match with a different image tag is
    treated as drift and triggers a patch.

    Issues a single kubectl --type=strategic patch only when there is a real difference.

    The strategic merge patch:
    - Adds the headlamp-plugins emptyDir volume when plugins are active.
    - Adds the volumeMount on the main headlamp container when plugins are active.
    - Adds or updates K2s init-containers by name (non-K2s init-containers are untouched).
    - Removes volume, mount, and init-containers when no K2s plugins are desired.

    .PARAMETER InitContainers
    The complete desired set of K2s plugin init-containers produced by New-PluginInitContainer.
    Pass an empty array (default) to remove all K2s-managed plugin init-containers.

    .OUTPUTS
    [bool] $true when a kubectl patch was actually issued (a rollout will follow);
    $false when no change was required (no-op). Callers use this to decide whether to
    wait for a rollout.
    #>
    param (
        [array] $InitContainers = @()
    )
    $registeredNames = @(Get-RegisteredHeadlampPlugins | ForEach-Object { $_.Name })

    # Fast path: no plugins registered and none desired — nothing to manage
    if ($registeredNames.Count -eq 0 -and $InitContainers.Count -eq 0) {
        Write-Log '[Dashboard][Plugin] No Headlamp plugins registered; skipping init-container patch'
        return $false
    }

    # Read current K2s init-container state (non-K2s containers untouched by strategic merge).
    # Build a name→image map for the K2s-managed slice.
    $current       = Get-CurrentPluginInitContainers
    $currentK2sMap = @{}
    foreach ($ic in $current) {
        if ($ic.name -in $registeredNames) {
            $currentK2sMap[$ic.name] = $ic.image
        }
    }

    # Build a name→image map for the desired slice.
    $desiredMap = @{}
    foreach ($ic in $InitContainers) {
        $desiredMap[$ic.Name] = $ic.Image
    }

    # Plugins to remove: currently active K2s names not present in the desired set.
    $toRemove = @($currentK2sMap.Keys | Where-Object { -not $desiredMap.ContainsKey($_) })

    # Plugins to add or update: desired names that are absent OR whose image has changed.
    $toAddOrUpdate = @($desiredMap.Keys | Where-Object {
        -not $currentK2sMap.ContainsKey($_) -or ($currentK2sMap[$_] -ne $desiredMap[$_])
    })

    if ($toAddOrUpdate.Count -eq 0 -and $toRemove.Count -eq 0) {
        Write-Log '[Dashboard][Plugin] Plugin init-containers already up to date; no patch required'
        return $false
    }

    Write-Log "[Dashboard][Plugin] Patching headlamp deployment: $($toAddOrUpdate.Count) add/update, $($toRemove.Count) remove" -Console

    $patchJson = Build-PluginPatchJson -K2sInitContainers $InitContainers -NamesToRemove $toRemove

    if (-not $patchJson) {
        Write-Log '[Dashboard][Plugin] Nothing to patch (no additions, updates, or removals needed)'
        return $false
    }

    # Build-PluginPatchJson emits backslash-escaped quotes (\") for legacy inline use.
    # Passing that inline via -p is unsafe: under PowerShell 5.1 native-argument quoting
    # the single patch argument gets re-tokenized because the init-container command
    # contains spaces and flag-like tokens (e.g. 'cp -r'), which kubectl then parses as
    # its own flags ("unknown shorthand flag: 'r'"). Write clean JSON to a temp file and
    # use --patch-file, which sidesteps native-argument quoting entirely.
    $cleanJson = $patchJson -replace '\\"', '"'
    $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) ("headlamp-plugin-patch-{0}.json" -f ([System.Guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($patchFile, $cleanJson, (New-Object System.Text.UTF8Encoding($false)))

        $patchResult = Invoke-Kubectl -Params 'patch', 'deployment', 'headlamp', '-n', 'dashboard', '--type=strategic', '--patch-file', $patchFile
        $patchResult.Output | Write-Log

        if (-not $patchResult.Success) {
            $msg = "[Dashboard][Plugin] Failed to patch headlamp deployment: $($patchResult.Output)"
            Write-Log $msg -Error
            throw $msg
        }

        Write-Log "[Dashboard][Plugin] Headlamp plugin patch applied: $($InitContainers.Count) K2s plugin(s) active" -Console
        return $true
    }
    finally {
        if (Test-Path $patchFile) { Remove-Item $patchFile -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-HeadlampPluginPatch {
    <#
    .SYNOPSIS
    Removes all K2s-managed Headlamp plugin init-containers from the headlamp Deployment.
    Called when the dashboard addon is being disabled.
    #>
    Write-Log '[Dashboard][Plugin] Removing all K2s Headlamp plugin init-containers' -Console
    $null = Apply-HeadlampPluginPatch -InitContainers @()
}

function Wait-ForHeadlampRollout {
    <#
    .SYNOPSIS
    Waits for the headlamp Deployment rollout to complete after a plugin sync and
    surfaces diagnostics if it stalls.

    .DESCRIPTION
    Pure observability helper — it does NOT change plugin behavior, capability
    detection, plugin selection, patch generation, image references, or init-container
    logic. It simply gives operators visibility into rollout progress so a temporarily
    stuck image pull (kubelet -> CRI) is not mistaken for a missing plugin.

    On timeout or failure it logs (but does not throw) the deployment status, pod
    status, and per-pod init-container state, then returns. Enable/sync flow continues
    regardless, because the desired state has already been applied.

    .PARAMETER TimeoutSeconds
    Maximum time to wait for the rollout to complete. Default 300s (see rationale in
    the module change notes): enough to absorb plugin init-container image pulls in
    offline/ACR environments without hanging 'enable' indefinitely.
    #>
    param (
        [int] $TimeoutSeconds = 300
    )

    Write-Log '[Dashboard][Plugin] Waiting for Headlamp rollout after plugin sync...' -Console

    $rollout = Invoke-Kubectl -Params 'rollout', 'status', 'deployment/headlamp', '-n', 'dashboard', "--timeout=${TimeoutSeconds}s"
    if ($rollout.Success -eq $true) {
        Write-Log '[Dashboard][Plugin] Headlamp rollout completed successfully.' -Console
        return $true
    }

    # Distinguish timeout from other failures for clearer operator messaging.
    $rolloutText = "$($rollout.Output)"
    if ($rolloutText -match 'timed out') {
        Write-Log "[Dashboard][Plugin] Headlamp rollout timed out after ${TimeoutSeconds}s." -Console
    }
    else {
        Write-Log '[Dashboard][Plugin] Headlamp rollout failed.' -Console
    }
    Write-Log "[Dashboard][Plugin] rollout status output: $rolloutText"

    # Surface diagnostics so the operator can see WHERE the rollout is stuck
    # (e.g. a plugin init-container waiting on an image pull) without re-running kubectl.
    $deployStatus = (Invoke-Kubectl -Params 'get', 'deployment', 'headlamp', '-n', 'dashboard', '-o', 'wide').Output
    Write-Log "[Dashboard][Plugin] Deployment status:`n$deployStatus" -Console

    $podStatus = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'dashboard', '-l', 'app.kubernetes.io/name=headlamp', '-o', 'wide').Output
    Write-Log "[Dashboard][Plugin] Pod status:`n$podStatus" -Console

    # Per-init-container state (best-effort). Two quote-free, space-free jsonpath
    # expressions are used deliberately: jsonpath string literals containing quotes or
    # spaces are stripped/re-tokenized at the PowerShell 5.1 native-argument boundary
    # (the same hazard documented in Build-PluginPatchJson). The pod STATUS column above
    # already shows the coarse phase (e.g. Init:0/2); these add which init-containers are
    # still waiting and why (e.g. PodInitializing / ImagePullBackOff).
    $initNames = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'dashboard', '-l', 'app.kubernetes.io/name=headlamp', '-o=jsonpath={.items[*].status.initContainerStatuses[*].name}').Output
    $initReasons = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'dashboard', '-l', 'app.kubernetes.io/name=headlamp', '-o=jsonpath={.items[*].status.initContainerStatuses[*].state.waiting.reason}').Output
    if ($initNames) {
        Write-Log "[Dashboard][Plugin] Init-containers: $initNames" -Console
        if ($initReasons) {
            Write-Log "[Dashboard][Plugin] Init-containers still waiting (reasons): $initReasons" -Console
        }
    }

    $events = (Invoke-Kubectl -Params 'get', 'events', '-n', 'dashboard', '--sort-by=.lastTimestamp').Output
    if ($events) {
        $eventTail = (@($events -split "`n") | Select-Object -Last 15) -join "`n"
        Write-Log "[Dashboard][Plugin] Recent dashboard events:`n$eventTail" -Console
    }

    Write-Log '[Dashboard][Plugin] Plugin desired state was applied; rollout will continue in the background. Re-run status checks or refresh the Headlamp UI once the new pod is Running.' -Console
    return $false
}

function Sync-HeadlampPlugins {
    <#
    .SYNOPSIS
    Reconciles Headlamp plugin init-containers to match actual cluster capabilities.

    .DESCRIPTION
    Iterates the plugin registry (Get-RegisteredHeadlampPlugins), invokes each plugin's
    Detector scriptblock to check live cluster state, builds the desired init-container
    set, and delegates to Apply-HeadlampPluginPatch.

    This function is idempotent and safe to call from Enable.ps1, Disable.ps1, or
    Update.ps1 of any addon that can install or remove a registered capability.

    Skips silently when the dashboard addon is not enabled.
    #>
    param ([switch]$SkipReadiness)
    Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins' -Console

    if (-not (Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'dashboard' }))) {
        Write-Log '[Dashboard][Plugin] Dashboard addon is not enabled; skipping plugin sync'
        return
    }

    $initContainers = @()
    foreach ($plugin in Get-RegisteredHeadlampPlugins) {
        $isAvailable = & $plugin.Detector
        if ($isAvailable) {
            Write-Log "[Dashboard][Plugin] Capability '$($plugin.Name)' detected; activating plugin"
            $initContainers += New-PluginInitContainer -Name $plugin.Name -Image $plugin.Image
        }
    }

    Write-Log "[Dashboard][Plugin] Plugin sync: $($initContainers.Count) plugin(s) to activate"
    $patched = Apply-HeadlampPluginPatch -InitContainers $initContainers

    # Observability only: wait for the rollout ONLY when a patch was actually issued, so
    # steady-state addon operations (the common case where plugin state is already
    # converged) don't block the caller or emit a misleading "Waiting for rollout" log.
    # Non-fatal by design.
    if ($patched -and -not $SkipReadiness) {
        Wait-ForHeadlampRollout | Out-Null
    }

    Write-Log '[Dashboard][Plugin] Headlamp plugin sync complete' -Console
}

Export-ModuleMember -Function Get-HeadlampManifestsDirectory, Get-HeadlampChartDirectory, Get-HeadlampChartPath, `
    Install-HeadlampViaHelm, Uninstall-HeadlampViaHelm, Enable-MetricsServer, Wait-ForHeadlampAvailable, `
    Write-HeadlampUsageForUser, Get-RegisteredHeadlampPlugins, `
    Test-FluxCapabilityAvailable, Test-CertManagerCapabilityAvailable, Test-PrometheusCapabilityAvailable, `
    Test-KedaCapabilityAvailable, `
    New-PluginInitContainer, Apply-HeadlampPluginPatch, Remove-HeadlampPluginPatch, Sync-HeadlampPlugins, Wait-ForHeadlampRollout
