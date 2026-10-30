# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\dashboard.module.psm1" -PassThru -Force).Name
}

Describe 'Get-HeadlampManifestsDirectory' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'returns a path ending with manifests\headlamp' {
        InModuleScope $moduleName {
            $result = Get-HeadlampManifestsDirectory
            $result | Should -BeLike '*\manifests\headlamp'
        }
    }
}

Describe 'Get-HeadlampChartDirectory' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'returns a path ending with manifests\chart' {
        InModuleScope $moduleName {
            $result = Get-HeadlampChartDirectory
            $result | Should -BeLike '*\manifests\chart'
        }
    }
}

Describe 'Get-HeadlampChartPath' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'chart tgz file exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            New-Item -ItemType Directory -Path 'TestDrive:\chart' -Force | Out-Null
            New-Item -ItemType File -Path 'TestDrive:\chart\headlamp-0.40.1.tgz' -Force | Out-Null
        }

        It 'returns the full path to the chart tgz' {
            InModuleScope $moduleName {
                $result = Get-HeadlampChartPath
                $result | Should -Not -BeNullOrEmpty
                $result | Should -BeLike '*headlamp-*.tgz'
            }
        }
    }

    Context 'no chart tgz file exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\emptychart' }
            New-Item -ItemType Directory -Path 'TestDrive:\emptychart' -Force | Out-Null
        }

        It 'returns null when no chart file found' {
            InModuleScope $moduleName {
                $result = Get-HeadlampChartPath
                $result | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Install-HeadlampViaHelm' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    BeforeAll {
        Mock -ModuleName $moduleName Get-AddonEffectiveInfrastructureSelector { return $Selector }
    }
    Context 'saved placement is set' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonEffectiveInfrastructureSelector { return 'kubernetes.io/hostname=kubemaster' }
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName New-AddonPlacementManifest { return 'TestDrive:\headlamp-placement.yaml' }
            Mock -ModuleName $moduleName Remove-Item { }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'namespace/dashboard' } }
            Mock -ModuleName $moduleName Invoke-Helm { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'passes merged owning values into the initial Helm upgrade' {
            Install-HeadlampViaHelm
            Should -Invoke -ModuleName $moduleName New-AddonPlacementManifest -Times 1 -Scope It -ParameterFilter { $AddonName -eq 'dashboard' -and $Selector -eq 'kubernetes.io/hostname=kubemaster' }
            Should -Invoke -ModuleName $moduleName Invoke-Helm -Times 1 -Scope It -ParameterFilter { $Params -contains 'TestDrive:\headlamp-placement.yaml' -and $Params -contains '--install' }
        }
    }
    Context 'chart and values file exist, helm succeeds' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'namespace/dashboard configured' } }
            Mock -ModuleName $moduleName Invoke-Helm { return [pscustomobject]@{ Success = $true; Output = 'Release "headlamp" has been upgraded. Happy Helming!' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Split-Path { return 'headlamp-0.40.1.tgz' }
        }

        It 'calls Invoke-Helm with upgrade --install' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Not -Throw
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'upgrade' -and $Params -contains '--install' -and $Params -contains 'headlamp'
                }
            }
        }

        It 'passes the namespace dashboard to helm' {
            InModuleScope $moduleName {
                Install-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--namespace' -and $Params -contains 'dashboard'
                }
            }
        }

        It 'passes the values file to helm' {
            InModuleScope $moduleName {
                Install-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--values'
                }
            }
        }
    }

    Context 'no chart tgz found' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return $null }
        }

        It 'throws when no chart file is found' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*No headlamp Helm chart .tgz found*'
            }
        }
    }

    Context 'values.yaml missing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Test-Path { return $false }
        }

        It 'throws when values.yaml is missing' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*values.yaml not found*'
            }
        }
    }

    Context 'helm install fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-HeadlampChartDirectory { return 'TestDrive:\chart' }
            Mock -ModuleName $moduleName Get-HeadlampChartPath { return 'TestDrive:\chart\headlamp-0.40.1.tgz' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Invoke-Helm { return [pscustomobject]@{ Success = $false; Output = 'Error: INSTALLATION FAILED' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Split-Path { return 'headlamp-0.40.1.tgz' }
        }

        It 'throws when helm install fails' {
            InModuleScope $moduleName {
                { Install-HeadlampViaHelm } | Should -Throw '*helm upgrade --install failed*'
            }
        }
    }
}

Describe 'Uninstall-HeadlampViaHelm' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'helm release exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'clusterrolebinding.rbac.authorization.k8s.io "headlamp-admin" deleted' } }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'list' } {
                return [pscustomobject]@{ Success = $true; Output = 'headlamp' }
            }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'uninstall' } {
                return [pscustomobject]@{ Success = $true; Output = 'release "headlamp" uninstalled' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls helm uninstall' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'uninstall' -and $Params -contains 'headlamp'
                }
            }
        }

        It 'deletes the headlamp-admin ClusterRoleBinding' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'clusterrolebinding' -and $Params -contains 'headlamp-admin'
                }
            }
        }

        It 'deletes the dashboard namespace' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'namespace' -and $Params -contains 'dashboard'
                }
            }
        }
    }

    Context 'no helm release found' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Invoke-Helm -ParameterFilter { $Params -contains 'list' } {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'skips helm uninstall when no release found' {
            InModuleScope $moduleName {
                Uninstall-HeadlampViaHelm
                Should -Invoke Invoke-Helm -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'uninstall'
                }
            }
        }
    }
}

Describe 'Wait-ForHeadlampAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    Context 'headlamp pod becomes ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $true }
        }

        It 'returns true' {
            InModuleScope $moduleName {
                $result = Wait-ForHeadlampAvailable
                $result | Should -Be $true
            }
        }

        It 'calls Wait-ForPodCondition with correct label namespace and timeout' {
            InModuleScope $moduleName {
                Wait-ForHeadlampAvailable
                Should -Invoke Wait-ForPodCondition -Times 1 -Scope Context -ParameterFilter {
                    $Label -eq 'app.kubernetes.io/name=headlamp' -and
                    $Namespace -eq 'dashboard' -and
                    $Condition -eq 'Ready' -and
                    $TimeoutSeconds -eq 300
                }
            }
        }
    }

    Context 'headlamp pod does not become ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForPodCondition { return $false }
        }

        It 'returns false' {
            InModuleScope $moduleName {
                $result = Wait-ForHeadlampAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Write-HeadlampUsageForUser' -Tag 'unit', 'ci', 'addon', 'dashboard' {

    BeforeEach {
        Mock -ModuleName $moduleName Write-Log { }
    }

    It 'writes multiple log messages' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It
        }
    }

    It 'mentions Headlamp in usage notes' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'Headlamp'
            }
        }
    }

    It 'mentions the correct port-forward service and port 4466' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'svc/headlamp'
            }
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match '4466'
            }
        }
    }

    It 'mentions the correct port-forward URL including /dashboard/ path' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'localhost:4466/dashboard'
            }
        }
    }

    It 'mentions that the token login screen is expected' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'token login screen'
            }
        }
    }

    It 'does not mention old kubernetes-dashboard or kong-proxy or port 8443' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'kubernetes-dashboard'
            }
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'kong-proxy'
            }
            Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match '8443'
            }
        }
    }

    It 'mentions the dashboard ingress URL' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'k2s\.cluster\.local/dashboard'
            }
        }
    }

    It 'mentions token creation command for headlamp SA' {
        InModuleScope $moduleName {
            Write-HeadlampUsageForUser
            Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                ($Messages -join ' ') -match 'create token headlamp'
            }
        }
    }
}

Describe 'Module exports correct public functions' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'exports Get-HeadlampManifestsDirectory' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampManifestsDirectory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-HeadlampChartDirectory' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampChartDirectory' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-HeadlampChartPath' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-HeadlampChartPath' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Install-HeadlampViaHelm' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Install-HeadlampViaHelm' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Uninstall-HeadlampViaHelm' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Uninstall-HeadlampViaHelm' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Wait-ForHeadlampAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Wait-ForHeadlampAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Write-HeadlampUsageForUser' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Write-HeadlampUsageForUser' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports New-PluginInitContainer' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'New-PluginInitContainer' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Apply-HeadlampPluginPatch' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Apply-HeadlampPluginPatch' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Remove-HeadlampPluginPatch' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Remove-HeadlampPluginPatch' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Sync-HeadlampPlugins' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Sync-HeadlampPlugins' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-RegisteredHeadlampPlugins' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Get-RegisteredHeadlampPlugins' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Test-FluxCapabilityAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-FluxCapabilityAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Test-CertManagerCapabilityAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-CertManagerCapabilityAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Test-PrometheusCapabilityAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-PrometheusCapabilityAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Test-KedaCapabilityAvailable' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-KedaCapabilityAvailable' -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
        }
    }


    It 'does not export the removed Test-SecurityAddonAvailability' {
        InModuleScope $moduleName {
            $fn = Get-Command -Module $moduleName -Name 'Test-SecurityAddonAvailability' -ErrorAction SilentlyContinue
            $fn | Should -BeNullOrEmpty
        }
    }

    It 'does not export internal helper Build-PluginPatchJson' {
        # Test from outside InModuleScope so only exported functions are visible
        $fn = Get-Command -Module $moduleName -Name 'Build-PluginPatchJson' -ErrorAction SilentlyContinue
        $fn | Should -BeNullOrEmpty
    }

    It 'does not export internal helper Get-CurrentPluginInitContainers' {
        $fn = Get-Command -Module $moduleName -Name 'Get-CurrentPluginInitContainers' -ErrorAction SilentlyContinue
        $fn | Should -BeNullOrEmpty
    }
}

Describe 'Linkerd annotation null-safety logic (Update.ps1 guard pattern)' -Tag 'unit', 'ci', 'addon', 'dashboard' {

    It 'handles deployment with no annotations object — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'handles deployment with null annotations — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":null}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'detects linkerd inject annotation when set to enabled' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled"}}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            $linkerdAnnotation | Should -Be 'enabled'
        }
    }

    It 'handles deployment with empty annotations object — hasNoAnnotation is true' {
        InModuleScope $moduleName {
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{}}}}}'
            $deploymentObj = $deploymentJson | ConvertFrom-Json

            $linkerdAnnotation = $null
            if ($null -ne $deploymentObj.spec.template.metadata.annotations) {
                $linkerdAnnotation = $deploymentObj.spec.template.metadata.annotations.'linkerd.io/inject'
            }
            ($null -eq $linkerdAnnotation) | Should -Be $true
        }
    }

    It 'else-branch skip condition: annotation already null means no patch needed' {
        InModuleScope $moduleName {
            # Simulate Update.ps1 else-branch: check current annotation before patching.
            # If annotation is already null, skip the patch entirely.
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{}}}}}'
            $currentDeployment = $deploymentJson | ConvertFrom-Json

            $currentAnnotation = $null
            if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
                $currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
            }

            # When annotation is already absent, skip-patch condition is true
            ($null -eq $currentAnnotation) | Should -Be $true
        }
    }

    It 'else-branch patch condition: annotation set to enabled means patch is required to remove it' {
        InModuleScope $moduleName {
            # Simulate Update.ps1 else-branch: annotation was previously set (Linkerd was active).
            # The patch must run to remove it.
            $deploymentJson = '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled"}}}}}'
            $currentDeployment = $deploymentJson | ConvertFrom-Json

            $currentAnnotation = $null
            if ($null -ne $currentDeployment.spec.template.metadata.annotations) {
                $currentAnnotation = $currentDeployment.spec.template.metadata.annotations.'linkerd.io/inject'
            }

            # When annotation is present, patch is required
            ($null -ne $currentAnnotation) | Should -Be $true
        }
    }
}

# ── Headlamp Plugin Framework Tests ───────────────────────────────────────────

Describe 'Get-RegisteredHeadlampPlugins' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    It 'returns exactly 4 plugins' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result.Count | Should -Be 4
        }
    }

    It 'includes a flux-plugin registration' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | Where-Object { $_.Name -eq 'flux-plugin' } | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes a cert-manager-plugin registration' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | Where-Object { $_.Name -eq 'cert-manager-plugin' } | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes a prometheus-plugin registration' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | Where-Object { $_.Name -eq 'prometheus-plugin' } | Should -Not -BeNullOrEmpty
        }
    }

    It 'includes a keda-plugin registration' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | Where-Object { $_.Name -eq 'keda-plugin' } | Should -Not -BeNullOrEmpty
        }
    }


    It 'every registration has a non-empty Image' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | ForEach-Object { $_.Image | Should -Not -BeNullOrEmpty }
        }
    }

    It 'every registration has a Detector scriptblock' {
        InModuleScope $moduleName {
            $result = @(Get-RegisteredHeadlampPlugins)
            $result | ForEach-Object { $_.Detector | Should -BeOfType [scriptblock] }
        }
    }
}

Describe 'New-PluginInitContainer' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    BeforeEach {
        Mock -ModuleName $moduleName Write-Log { }
    }

    It 'returns an object with the correct Name property' {
        InModuleScope $moduleName {
            $result = New-PluginInitContainer -Name 'flux-plugin' -Image 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0'
            $result.Name | Should -Be 'flux-plugin'
        }
    }

    It 'returns an object with the correct Image property' {
        InModuleScope $moduleName {
            $result = New-PluginInitContainer -Name 'flux-plugin' -Image 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0'
            $result.Image | Should -Be 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0'
        }
    }

    It 'returns a PSCustomObject (not null)' {
        InModuleScope $moduleName {
            $result = New-PluginInitContainer -Name 'test' -Image 'img:latest'
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Test-FluxCapabilityAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'flux-system namespace exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'Active' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns true when the flux-system namespace is found' {
            InModuleScope $moduleName {
                $result = Test-FluxCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'flux-system namespace absent but Flux CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:fluxKubectlCall++
                # First call = namespace check (empty), second call = CRD check (found)
                if ($script:fluxKubectlCall -eq 1) {
                    return [pscustomobject]@{ Success = $true; Output = '' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'kustomizations.kustomize.toolkit.fluxcd.io   2023-01-01' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            # Reset in the test-file script scope — the same scope the mock closure
            # increments. Resetting inside InModuleScope would target the module's
            # script scope instead, leaving this counter stale across It blocks.
            $script:fluxKubectlCall = 0
        }

        It 'returns true when the Flux CRD is found' {
            InModuleScope $moduleName {
                $result = Test-FluxCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'neither namespace nor CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns false when no Flux indicators are found' {
            InModuleScope $moduleName {
                $result = Test-FluxCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Test-CertManagerCapabilityAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'cert-manager namespace exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'Active' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns true when the cert-manager namespace is found' {
            InModuleScope $moduleName {
                $result = Test-CertManagerCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'cert-manager namespace absent but CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:cmKubectlCall++
                if ($script:cmKubectlCall -eq 1) {
                    return [pscustomobject]@{ Success = $true; Output = '' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'certificates.cert-manager.io   2023-01-01' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            # Reset in the test-file script scope — the same scope the mock closure
            # increments (see Flux context for rationale).
            $script:cmKubectlCall = 0
        }

        It 'returns true when the certificates CRD is found' {
            InModuleScope $moduleName {
                $result = Test-CertManagerCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'neither namespace nor CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns false when no cert-manager indicators are found' {
            InModuleScope $moduleName {
                $result = Test-CertManagerCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }

    Context 'cert-manager installed by ingress/nginx (no security addon)' {
        BeforeAll {
            # cert-manager namespace exists (installed by nginx, not security)
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'Active' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns true regardless of who installed cert-manager' {
            InModuleScope $moduleName {
                $result = Test-CertManagerCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'cert-manager namespace is Terminating and CRD already gone' {
        BeforeAll {
            # Regression guard: a namespace lingering in 'Terminating' after Uninstall-CertManager
            # must NOT count as a live capability, otherwise Sync-HeadlampPlugins would retain the
            # cert-manager plugin init-container after the security/ingress addon was disabled.
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:cmTermKubectlCall++
                if ($script:cmTermKubectlCall -eq 1) {
                    # namespace phase check
                    return [pscustomobject]@{ Success = $true; Output = 'Terminating' }
                }
                # CRD check (already deleted)
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            $script:cmTermKubectlCall = 0
        }

        It 'returns false when the namespace is only Terminating' {
            InModuleScope $moduleName {
                $result = Test-CertManagerCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Test-PrometheusCapabilityAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'monitoring namespace is Active' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'Active' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns true when the monitoring namespace is found' {
            InModuleScope $moduleName {
                $result = Test-PrometheusCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'namespace absent but prometheuses CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:promKubectlCall++
                # First call = namespace phase (empty), second call = CRD check (found)
                if ($script:promKubectlCall -eq 1) {
                    return [pscustomobject]@{ Success = $true; Output = '' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'prometheuses.monitoring.coreos.com   2023-01-01' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            $script:promKubectlCall = 0
        }

        It 'returns true when the prometheuses CRD is found' {
            InModuleScope $moduleName {
                $result = Test-PrometheusCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'namespace and CRD absent but prometheus-operated service present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:promKubectlCall++
                # 1 = namespace phase (empty), 2 = CRD (empty), 3 = service (found)
                if ($script:promKubectlCall -le 2) {
                    return [pscustomobject]@{ Success = $true; Output = '' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'prometheus-operated   ClusterIP   None' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            # Reset in the test-file script scope — the same scope the mock closure
            # increments (see Flux context for rationale).
            $script:promKubectlCall = 0
        }

        It 'returns true when the prometheus-operated service is found' {
            InModuleScope $moduleName {
                $result = Test-PrometheusCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'monitoring namespace is Terminating and CRD/service already gone' {
        BeforeAll {
            # Regression guard: a namespace lingering in 'Terminating' after the monitoring
            # addon is disabled must NOT count as a live capability, otherwise
            # Sync-HeadlampPlugins would retain the prometheus plugin init-container.
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:promKubectlCall++
                if ($script:promKubectlCall -eq 1) {
                    # namespace phase check
                    return [pscustomobject]@{ Success = $true; Output = 'Terminating' }
                }
                # CRD + service checks (already deleted)
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            $script:promKubectlCall = 0
        }

        It 'returns false when the namespace is only Terminating' {
            InModuleScope $moduleName {
                $result = Test-PrometheusCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }

    Context 'neither namespace, CRD nor service present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns false when no Prometheus indicators are found' {
            InModuleScope $moduleName {
                $result = Test-PrometheusCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Test-KedaCapabilityAvailable' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'autoscaling namespace exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = 'Active' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns true when the autoscaling namespace is found' {
            InModuleScope $moduleName {
                $result = Test-KedaCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'autoscaling namespace absent but KEDA CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:kedaKubectlCall++
                # First call = namespace check (empty), second call = CRD check (found)
                if ($script:kedaKubectlCall -eq 1) {
                    return [pscustomobject]@{ Success = $true; Output = '' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'scaledobjects.keda.sh   2023-01-01' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        BeforeEach {
            # Reset in the test-file script scope — the same scope the mock closure
            # increments (see Flux context for rationale).
            $script:kedaKubectlCall = 0
        }

        It 'returns true when the scaledobjects CRD is found' {
            InModuleScope $moduleName {
                $result = Test-KedaCapabilityAvailable
                $result | Should -Be $true
            }
        }
    }

    Context 'neither namespace nor CRD present' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'returns false when no KEDA indicators are found' {
            InModuleScope $moduleName {
                $result = Test-KedaCapabilityAvailable
                $result | Should -Be $false
            }
        }
    }
}

Describe 'Build-PluginPatchJson' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    It 'returns null for empty K2sInitContainers and empty NamesToRemove' {
        InModuleScope $moduleName {
            $result = Build-PluginPatchJson -K2sInitContainers @() -NamesToRemove @()
            $result | Should -BeNullOrEmpty
        }
    }

    It 'contains the container name when a plugin is being added' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match 'flux-plugin'
        }
    }

    It 'contains the image reference when a plugin is being added' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match 'headlamp-plugin-flux'
        }
    }

    It 'uses the correct plugins directory /tmp/headlamp/plugins' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'test-plugin'; Image = 'img:1.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match '/tmp/headlamp/plugins'
            $result | Should -Not -Match '"/headlamp/plugins"'
        }
    }

    It 'includes the headlamp-plugins volume definition when plugins are active' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'test-plugin'; Image = 'img:1.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match 'headlamp-plugins'
            $result | Should -Match 'emptyDir'
        }
    }

    It 'includes the main headlamp container volumeMount when plugins are active' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'test-plugin'; Image = 'img:1.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match 'headlamp'
            $result | Should -Match 'volumeMounts'
            $result | Should -Match 'containers'
        }
    }

    It 'includes both container names when two plugins are being added' {
        InModuleScope $moduleName {
            $ic1 = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img-a:1.0' }
            $ic2 = [pscustomobject]@{ Name = 'prometheus-plugin'; Image = 'img-b:1.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic1, $ic2)
            $result | Should -Match 'flux-plugin'
            $result | Should -Match 'prometheus-plugin'
        }
    }

    It 'emits a $patch:delete directive for each name in NamesToRemove' {
        InModuleScope $moduleName {
            $result = Build-PluginPatchJson -K2sInitContainers @() -NamesToRemove @('flux-plugin', 'cert-manager-plugin')
            $result | Should -Match 'flux-plugin'
            $result | Should -Match 'cert-manager-plugin'
            $result | Should -Match '\$patch.*delete'
        }
    }

    It 'emits a volume delete directive when only removals are requested' {
        InModuleScope $moduleName {
            $result = Build-PluginPatchJson -K2sInitContainers @() -NamesToRemove @('flux-plugin')
            $result | Should -Match 'headlamp-plugins'
            $result | Should -Match '\$patch.*delete'
        }
    }

    It 'contains the spec.template.spec path in the JSON' {
        InModuleScope $moduleName {
            $ic = [pscustomobject]@{ Name = 'test'; Image = 'img:1.0' }
            $result = Build-PluginPatchJson -K2sInitContainers @($ic)
            $result | Should -Match 'spec'
            $result | Should -Match 'template'
        }
    }
}

Describe 'Apply-HeadlampPluginPatch' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'fast path — registry empty and none desired (hypothetical; future-proof)' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins { return @() }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call kubectl when registry is empty and InitContainers is empty' {
            InModuleScope $moduleName {
                Apply-HeadlampPluginPatch -InitContainers @()
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It
            }
        }

        It 'returns $false on the fast-path no-op (registry empty, none desired)' {
            InModuleScope $moduleName {
                $result = Apply-HeadlampPluginPatch -InitContainers @()
                $result | Should -Be $false
            }
        }
    }

    # ── Scenario 1: same name, same image → no patch ──────────────────────────
    Context 'Scenario 1: same name AND same image — no change needed' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @([pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0'; Detector = { $true } })
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @([pscustomobject]@{ name = 'flux-plugin'; image = 'img:0.6.0' })
            }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call kubectl patch when name and image are identical' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'returns $false when no patch is required (no-op)' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0' }
                $result = Apply-HeadlampPluginPatch -InitContainers @($ic)
                $result | Should -Be $false
            }
        }
    }

    # ── Scenario 2: same name, different image tag → patch required ───────────
    Context 'Scenario 2: same name but different image tag (version bump)' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @([pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0'; Detector = { $true } })
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                # Deployment has the OLD image tag
                return @([pscustomobject]@{ name = 'flux-plugin'; image = 'img:0.6.0' })
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-upgrade-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch when the image tag has changed' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'passes the new-image init-container to Build-PluginPatchJson' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($K2sInitContainers)[0].Image -eq 'img:0.7.0'
                }
            }
        }

        It 'does not include the plugin in NamesToRemove for an upgrade (update in place)' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($NamesToRemove).Count -eq 0
                }
            }
        }

        It 'uses --type=strategic for the kubectl patch' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--type=strategic'
                }
            }
        }

        It 'returns $true when a patch is actually issued' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.7.0' }
                $result = Apply-HeadlampPluginPatch -InitContainers @($ic)
                $result | Should -Be $true
            }
        }
    }

    # ── Scenario 3: plugin removed → patch required ───────────────────────────
    Context 'Scenario 3: plugin present in deployment but no longer desired' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @([pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0'; Detector = { $true } })
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @([pscustomobject]@{ name = 'flux-plugin'; image = 'img:0.6.0' })
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-remove-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch when the desired list is empty (plugin removed)' {
            InModuleScope $moduleName {
                Apply-HeadlampPluginPatch -InitContainers @()
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'includes the removed plugin name in NamesToRemove' {
            InModuleScope $moduleName {
                Apply-HeadlampPluginPatch -InitContainers @()
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($NamesToRemove) -contains 'flux-plugin'
                }
            }
        }
    }

    # ── Scenario 4: plugin added → patch required ─────────────────────────────
    Context 'Scenario 4: plugin desired but not yet in the deployment' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @([pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0'; Detector = { $true } })
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers { return @() }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-add-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch when a new plugin needs to be added' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'passes the new plugin to Build-PluginPatchJson with an empty NamesToRemove' {
            InModuleScope $moduleName {
                $ic = [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0' }
                Apply-HeadlampPluginPatch -InitContainers @($ic)
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($K2sInitContainers).Count -eq 1 -and @($NamesToRemove).Count -eq 0
                }
            }
        }
    }

    # ── Scenario 5: multiple plugins with mixed changes ───────────────────────
    Context 'Scenario 5a: two plugins — one unchanged, one upgraded — patch required' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';       Image = 'img-flux:0.6.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';  Image = 'img-prom:0.9.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @(
                    [pscustomobject]@{ name = 'flux-plugin';      image = 'img-flux:0.6.0' },  # unchanged
                    [pscustomobject]@{ name = 'prometheus-plugin'; image = 'img-prom:0.8.2' }  # OLD tag
                )
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-mixed-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch because one plugin image has changed' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';      Image = 'img-flux:0.6.0' },
                    [pscustomobject]@{ Name = 'prometheus-plugin'; Image = 'img-prom:0.9.0' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'passes both desired plugins to Build-PluginPatchJson with empty NamesToRemove' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';      Image = 'img-flux:0.6.0' },
                    [pscustomobject]@{ Name = 'prometheus-plugin'; Image = 'img-prom:0.9.0' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($K2sInitContainers).Count -eq 2 -and @($NamesToRemove).Count -eq 0
                }
            }
        }
    }

    Context 'Scenario 5b: two plugins — all identical — no patch' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';      Image = 'img-flux:0.6.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'prometheus-plugin'; Image = 'img-prom:0.8.2'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @(
                    [pscustomobject]@{ name = 'flux-plugin';      image = 'img-flux:0.6.0' },
                    [pscustomobject]@{ name = 'prometheus-plugin'; image = 'img-prom:0.8.2' }
                )
            }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call kubectl patch when all plugin names and images match' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';      Image = 'img-flux:0.6.0' },
                    [pscustomobject]@{ Name = 'prometheus-plugin'; Image = 'img-prom:0.8.2' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }
    }

    Context 'Scenario 5c: three plugins — one added, one removed, one image-upgraded' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:0.7.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin';  Image = 'img-cm:0.1.0';  Detector = { $true } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';    Image = 'img-prom:0.9.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @(
                    [pscustomobject]@{ name = 'flux-plugin';        image = 'img-flux:0.6.0' },  # upgrade
                    [pscustomobject]@{ name = 'prometheus-plugin';  image = 'img-prom:0.9.0' }   # unchanged, cert-manager absent
                )
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-complex-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch for the complex mixed-change scenario' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';        Image = 'img-flux:0.7.0' },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:0.1.0' },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:0.9.0' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'passes all 3 desired plugins to Build-PluginPatchJson with empty NamesToRemove' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';        Image = 'img-flux:0.7.0' },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:0.1.0' },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:0.9.0' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    @($K2sInitContainers).Count -eq 3 -and @($NamesToRemove).Count -eq 0
                }
            }
        }
    }

    Context 'passes only K2s init-containers to Build-PluginPatchJson (non-K2s untouched by strategic merge)' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:0.6.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:0.1.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @(
                    [pscustomobject]@{ name = 'chart-init';    image = 'chart-img:1.0' },  # non-K2s, must not appear in patch
                    [pscustomobject]@{ name = 'flux-plugin';   image = 'img:0.6.0' }        # K2s, unchanged
                )
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not include chart-init (non-K2s) in the K2sInitContainers patch payload' {
            InModuleScope $moduleName {
                $desired = @(
                    [pscustomobject]@{ Name = 'flux-plugin';        Image = 'img:0.6.0' },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:0.1.0' }
                )
                Apply-HeadlampPluginPatch -InitContainers $desired
                Should -Invoke Build-PluginPatchJson -Times 1 -Scope It -ParameterFilter {
                    -not ($K2sInitContainers | Where-Object { $_.Name -eq 'chart-init' })
                }
            }
        }
    }
}

Describe 'Remove-HeadlampPluginPatch' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    Context 'registry is empty (fast path; no plugins to remove)' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins { return @() }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call kubectl patch when the plugin registry is empty' {
            InModuleScope $moduleName {
                Remove-HeadlampPluginPatch
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }
    }

    Context 'plugins registered and one is currently active' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @([pscustomobject]@{ Name = 'flux-plugin'; Image = 'img:1.0'; Detector = { $true } })
            }
            Mock -ModuleName $moduleName Get-CurrentPluginInitContainers {
                return @([pscustomobject]@{ name = 'flux-plugin'; image = 'img:1.0' })
            }
            Mock -ModuleName $moduleName Build-PluginPatchJson { return 'mock-json' }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls kubectl patch to remove all plugin init-containers' {
            InModuleScope $moduleName {
                Remove-HeadlampPluginPatch
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'patch'
                }
            }
        }

        It 'passes --type=strategic to kubectl' {
            InModuleScope $moduleName {
                Remove-HeadlampPluginPatch
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains '--type=strategic'
                }
            }
        }
    }
}

Describe 'Sync-HeadlampPlugins' -Tag 'unit', 'ci', 'addon', 'dashboard', 'plugin' {
    It 'applies desired plugins while Pending without waiting for rollout' {
        Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
        Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins { return @() }
        Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { return $true }
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Wait-ForHeadlampRollout { throw 'must not wait while Pending' }
        Sync-HeadlampPlugins -SkipReadiness
        Should -Invoke -ModuleName $moduleName Apply-HeadlampPluginPatch -Times 1 -Scope It
        Should -Invoke -ModuleName $moduleName Wait-ForHeadlampRollout -Times 0 -Scope It
    }
    BeforeAll {
        # Sync-HeadlampPlugins ends with 'Wait-ForHeadlampRollout | Out-Null' (rollout
        # observability). That helper shells out to kubectl, so stub it here to keep these
        # unit tests hermetic and focused on plugin selection / Apply-HeadlampPluginPatch.
        Mock -ModuleName $moduleName Wait-ForHeadlampRollout { }
    }

    Context 'dashboard addon is not enabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call Apply-HeadlampPluginPatch when dashboard is not enabled' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 0 -Scope It
            }
        }
    }

    Context 'dashboard enabled; no capabilities detected' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:1.0'; Detector = { $false } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:1.0';   Detector = { $false } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:1.0'; Detector = { $false } }
                )
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls Apply-HeadlampPluginPatch with an empty list when no capabilities are detected' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 0
                }
            }
        }
    }

    Context 'dashboard enabled; all 3 capabilities detected' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:1.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:1.0';   Detector = { $true } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:1.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls Apply-HeadlampPluginPatch with 3 init-containers' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 3
                }
            }
        }
    }

    Context 'dashboard enabled; only Flux capability detected' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:1.0'; Detector = { $true } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:1.0';   Detector = { $false } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:1.0'; Detector = { $false } }
                )
            }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls Apply-HeadlampPluginPatch with only the flux-plugin init-container' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 1 -and @($InitContainers)[0].Name -eq 'flux-plugin'
                }
            }
        }
    }

    Context 'dashboard enabled; cert-manager capability detected (regardless of who installed it)' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:1.0'; Detector = { $false } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:1.0';   Detector = { $true } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:1.0'; Detector = { $false } }
                )
            }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'activates cert-manager-plugin regardless of which addon installed cert-manager' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 1 -and @($InitContainers)[0].Name -eq 'cert-manager-plugin'
                }
            }
        }
    }

    Context 'dashboard enabled; only Prometheus capability detected' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin';         Image = 'img-flux:1.0'; Detector = { $false } },
                    [pscustomobject]@{ Name = 'cert-manager-plugin'; Image = 'img-cm:1.0';   Detector = { $false } },
                    [pscustomobject]@{ Name = 'prometheus-plugin';   Image = 'img-prom:1.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'calls Apply-HeadlampPluginPatch with only the prometheus-plugin init-container' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 1 -and @($InitContainers)[0].Name -eq 'prometheus-plugin'
                }
            }
        }
    }

    Context 'dashboard enabled; uses real capability detectors via detector scriptblocks' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            # Use real registry — detector scriptblocks call the real capability functions
            Mock -ModuleName $moduleName Test-FluxCapabilityAvailable         { return $true }
            Mock -ModuleName $moduleName Test-CertManagerCapabilityAvailable  { return $false }
            Mock -ModuleName $moduleName Test-PrometheusCapabilityAvailable   { return $true }
            Mock -ModuleName $moduleName Test-KedaCapabilityAvailable         { return $false }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Apply-HeadlampPluginPatch { }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'activates only flux and prometheus plugins when only those capabilities are present' {
            InModuleScope $moduleName {
                Sync-HeadlampPlugins
                Should -Invoke Apply-HeadlampPluginPatch -Times 1 -Scope It -ParameterFilter {
                    @($InitContainers).Count -eq 2
                }
            }
        }
    }

    Context 'rollout wait is gated on whether a patch was issued' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true }
            Mock -ModuleName $moduleName Get-RegisteredHeadlampPlugins {
                return @(
                    [pscustomobject]@{ Name = 'flux-plugin'; Image = 'img-flux:1.0'; Detector = { $true } }
                )
            }
            Mock -ModuleName $moduleName New-PluginInitContainer {
                param ($Name, $Image)
                return [pscustomobject]@{ Name = $Name; Image = $Image }
            }
            Mock -ModuleName $moduleName Write-Log { }
        }

        It 'does not call Wait-ForHeadlampRollout when Apply-HeadlampPluginPatch reports no patch ($false)' {
            InModuleScope $moduleName {
                Mock Apply-HeadlampPluginPatch { return $false }
                Sync-HeadlampPlugins
                Should -Invoke Wait-ForHeadlampRollout -Times 0 -Scope It
            }
        }

        It 'calls Wait-ForHeadlampRollout when Apply-HeadlampPluginPatch reports a patch ($true)' {
            InModuleScope $moduleName {
                Mock Apply-HeadlampPluginPatch { return $true }
                Sync-HeadlampPlugins
                Should -Invoke Wait-ForHeadlampRollout -Times 1 -Scope It
            }
        }
    }
}


Describe 'Dashboard Enable.ps1 selector with side-effect addons' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $enableAst = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Enable.ps1", [ref]$tokens, [ref]$parseErrors)
        $trapAst = $enableAst.EndBlock.Traps[0]
        $guardAst = $enableAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match 'throw' } | Select-Object -First 1
        $firstSideEffectOffset = ($enableAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Test-SystemAvailability', 'Enable-IngressAddon', 'Enable-MetricsServer') }, $true) | Measure-Object -Property { $_.Extent.StartOffset } -Minimum).Minimum
        $guardOffset = $guardAst.Extent.StartOffset
        $probe = [scriptblock]::Create($enableAst.ParamBlock.Extent.Text + "`n" + $trapAst.Extent.Text + "`n" + $guardAst.Extent.Text + "`n'continued'")
        $guardOnlyProbe = [scriptblock]::Create($enableAst.ParamBlock.Extent.Text + "`n" + $guardAst.Extent.Text + "`n'continued'")
    }

    BeforeEach {
        $script:cliMessages = [System.Collections.Generic.List[object]]::new()
        function Send-ToCli { param($MessageType, $Message) $script:cliMessages.Add($Message) }
        function New-Error { param($Code, $Message) [pscustomobject]@{ Code = $Code; Message = $Message } }
        function Get-ErrCodeAddonEnableFailed { 'addon-enable-failed' }
    }

    It 'places the guard before cluster checks and nested addon enablement' {
        $guardAst | Should -Not -BeNull
        $guardOffset | Should -BeLessThan $firstSideEffectOffset
    }

    It 'rejects a selector combined with <Case> before continuing' -ForEach @(
        @{ Case = 'ingress'; Arguments = @{ InfraNodeSelector = 'pool=infra'; Ingress = 'nginx' } }
        @{ Case = 'metrics server'; Arguments = @{ InfraNodeSelector = 'pool=infra'; EnableMetricsServer = $true } }
    ) {
        $arguments = $Arguments
        { & $guardOnlyProbe @arguments } | Should -Throw '*separately before enabling dashboard with infrastructure placement*'
    }

    It 'encodes the rejection as a structured error' {
        $output = & $probe -InfraNodeSelector 'pool=infra' -Ingress 'traefik' -EncodeStructuredOutput -MessageType 'CmdResult'
        $output | Should -BeNullOrEmpty
        $script:cliMessages.Count | Should -Be 1
        $script:cliMessages[0].Error.Code | Should -Be 'addon-enable-failed'
        $script:cliMessages[0].Error.Message | Should -BeLike '*separately*'
    }

    It 'allows a selector alone and the side-effect options without a selector' -ForEach @(
        @{ Arguments = @{ InfraNodeSelector = 'pool=infra' } }
        @{ Arguments = @{ Ingress = 'nginx'; EnableMetricsServer = $true } }
        @{ Arguments = @{ InfraNodeSelector = ' '; Ingress = 'nginx' } }
    ) {
        $arguments = $Arguments
        & $probe @arguments | Should -Be 'continued'
    }
}
