# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\k8s-api.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Confirm-ApiVersionIsValid' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'API version is valid' {
        It 'does not throw' {
            InModuleScope $moduleName {
                { Confirm-ApiVersionIsValid -Version $supportedApiVersion } | Should -Not -Throw
            }
        }
    }

    Context 'API version is invalid' {
        It 'throws' {
            InModuleScope $moduleName {
                { Confirm-ApiVersionIsValid -Version 'v1.2.3_test' } | Should -Throw
            }
        }
    }

    Context 'Version param not set' {
        It 'throws' {
            InModuleScope $moduleName {
                { Confirm-ApiVersionIsValid } | Should -Throw
            }
        }
    }
}

Describe 'Get-Age' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'timestamp is in the past' {
        BeforeEach {
            $now = [datetime]::SpecifyKind([datetime]::new(2023, 1, 2), [System.DateTimeKind]::Utc)
            $then = [datetime]::SpecifyKind([datetime]::new(2023, 1, 1), [System.DateTimeKind]::Utc)
            $expectedDuration = $now - $then
            $expectedResult = 'past test'

            Mock -ModuleName $moduleName Get-Now { return $now }
            Mock -ModuleName $moduleName Convert-ToAgeString { return $expectedResult } -Verifiable -ParameterFilter { $Duration -eq $expectedDuration }

            InModuleScope $moduleName -Parameters @{Then = $then } {
                $script:result = Get-Age -Timestamp $($Then.ToString('o'))
            }
        }

        It 'calculates duration correctly' {
            Should -InvokeVerifiable
        }

        It 'returns conversion result' {
            InModuleScope $moduleName -Parameters @{Expected = $expectedResult } {
                $result | Should -Be $Expected
            }
        }
    }

    Context 'timestamp is in the future' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Now { return [datetime]::SpecifyKind([datetime]::new(2023, 1, 1), [System.DateTimeKind]::Utc) }
        }

        It 'throws' {
            InModuleScope $moduleName {
                $timestamp = [datetime]::SpecifyKind([datetime]::new(2023, 1, 2), [System.DateTimeKind]::Utc)

                { Get-Age -Timestamp $($timestamp.ToString('o')) } | Should -Throw
            }
        }
    }

    Context 'timestamp is now' {
        BeforeEach {
            $now = [datetime]::SpecifyKind([datetime]::new(2023, 1, 2), [System.DateTimeKind]::Utc)
            $then = $now
            $expectedDuration = $now - $then
            $expectedResult = 'now test'

            Mock -ModuleName $moduleName Get-Now { return $now }
            Mock -ModuleName $moduleName Convert-ToAgeString { return $expectedResult } -Verifiable -ParameterFilter { $Duration -eq $expectedDuration }

            InModuleScope $moduleName -Parameters @{Then = $then } {
                $script:result = Get-Age -Timestamp $($Then.ToString('o'))
            }
        }

        It 'calculates duration correctly' {
            Should -InvokeVerifiable
        }

        It 'returns conversion result' {
            InModuleScope $moduleName -Parameters @{Expected = $expectedResult } {
                $result | Should -Be $Expected
            }
        }
    }

    Context 'Timestamp param not set' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-Age } | Should -Throw
            }
        }
    }

    Context 'invalid Timestamp param (not parseable)' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-Age -Timestamp 'invalid' } | Should -Throw
            }
        }
    }
}

Describe 'Get-NodeStatus' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'no conditions' {
        It 'returns default status' {
            InModuleScope $moduleName {
                $result = Get-NodeStatus

                $result.StatusText | Should -Be 'Unknown'
                $result.IsReady | Should -Be $false
            }
        }
    }

    Context 'no valid status in conditions found' {
        BeforeAll {
            $conditions = @{status = 'my status'; type = 'my type' }, @{status = 'another status'; type = 'different type' }
        }

        It 'returns default status' {
            InModuleScope $moduleName -Parameters @{conditions = $conditions } {
                $result = Get-NodeStatus -Conditions $conditions

                $result.StatusText | Should -Be 'Unknown'
                $result.IsReady | Should -Be $false
            }
        }
    }

    Context 'status found, but not ready' {
        BeforeAll {
            $conditions = @{status = 'my status'; type = 'my type' }, @{status = 'True'; type = 'not ready' }
        }

        It 'returns correct status' {
            InModuleScope $moduleName -Parameters @{conditions = $conditions } {
                $result = Get-NodeStatus -Conditions $conditions

                $result.StatusText | Should -Be 'not ready'
                $result.IsReady | Should -Be $false
            }
        }
    }

    Context 'status found, node ready' {
        BeforeAll {
            $conditions = @{status = 'my status'; type = 'my type' }, @{status = 'True'; type = 'Ready' }
        }

        It 'returns correct status' {
            InModuleScope $moduleName -Parameters @{conditions = $conditions } {
                $result = Get-NodeStatus -Conditions $conditions

                $result.StatusText | Should -Be 'Ready'
                $result.IsReady | Should -Be $true
            }
        }
    }
}

Describe 'Get-NodeRole' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'no labels' {
        It 'returns default role' {
            InModuleScope $moduleName {
                Get-NodeRole | Should -Be 'Unknown'
            }
        }
    }

    Context 'no valid role found' {
        BeforeAll {
            $labels = [PSCustomObject]@{
                'my role name' = ''
            }
        }

        It 'returns default role' {
            InModuleScope $moduleName -Parameters @{labels = $labels } {
                Get-NodeRole -Labels $labels | Should -Be 'Unknown'
            }
        }
    }

    Context 'control-plane role found' {
        BeforeAll {
            $labels = [PSCustomObject]@{
                'node-role.kubernetes.io/control-plane' = ''
            }
        }

        It 'returns control-plane role' {
            InModuleScope $moduleName -Parameters @{labels = $labels } {
                Get-NodeRole -Labels $labels | Should -Be 'control-plane'
            }
        }
    }

    Context 'worker role found' {
        BeforeAll {
            $labels = [PSCustomObject]@{
                'kubernetes.io/role' = 'worker'
            }
        }

        It 'returns worker role' {
            InModuleScope $moduleName -Parameters @{labels = $labels } {
                Get-NodeRole -Labels $labels | Should -Be 'worker'
            }
        }
    }
}

Describe 'Get-NodeInternalIp' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'no addresses' {
        It 'returns default IP' {
            InModuleScope $moduleName {
                Get-NodeInternalIp | Should -Be '<none>'
            }
        }
    }

    Context 'no valid address found' {
        BeforeAll {
            $addresses = [PSCustomObject[]] @{
                type    = 'my type'
                address = 'localhost'
            },
            @{
                type    = 'another type'
                address = '127.0.0.1'
            }
        }

        It 'returns default IP' {
            InModuleScope $moduleName -Parameters @{addresses = $addresses } {
                Get-NodeInternalIp -Addresses $addresses | Should -Be '<none>'
            }
        }
    }

    Context 'valid address found' {
        BeforeAll {
            $addresses = [PSCustomObject] @{
                type    = 'another type'
                address = '127.0.0.1'
            },
            [PSCustomObject] @{
                type    = 'InternalIP'
                address = 'localhost'
            }
        }

        It 'returns internal IP' {
            InModuleScope $moduleName -Parameters @{addresses = $addresses } {
                Get-NodeInternalIp -Addresses $addresses | Should -Be 'localhost'
            }
        }
    }
}

Describe 'Get-Node' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'JSON is valid' {
        BeforeAll {
            $expectedStatus = @{StatusText = 'good'; IsReady = $true }
            $expectedRole = 'tester'
            $expectedAge = 'old'
            $expectedIp = 'localhost'
            $expectedName = 'test node'
            $expectedKubeletVersion = '1.2.3'
            $expectedOs = 'Linux'
            $expectedKernel = 'amd-x64'
            $expectedRuntime = 'CRY-OH'

            $json = [PSCustomObject]@{
                status   = [PSCustomObject]@{
                    conditions = [PSCustomObject]@{}, [PSCustomObject]@{}
                    addresses  = [PSCustomObject]@{}, [PSCustomObject]@{}
                    nodeInfo   = [PSCustomObject]@{
                        kubeletVersion          = $expectedKubeletVersion
                        osImage                 = $expectedOs
                        kernelVersion           = $expectedKernel
                        containerRuntimeVersion = $expectedRuntime
                    }
                }
                metadata = [PSCustomObject]@{
                    name              = $expectedName
                    labels            = [pscustomobject]@{}
                    creationTimestamp = [datetime]::new(2023, 1, 2)
                }
            }

            Mock -ModuleName $moduleName Get-NodeStatus { return $expectedStatus } -Verifiable -ParameterFilter { $Conditions.Count -eq $json.status.conditions.Count }
            Mock -ModuleName $moduleName Get-NodeRole { return $expectedRole } -Verifiable -ParameterFilter { $Labels -eq $json.metadata.labels }
            Mock -ModuleName $moduleName Get-Age { return $expectedAge } -Verifiable -ParameterFilter { $Timestamp -eq $($json.metadata.creationTimestamp.ToString()) }
            Mock -ModuleName $moduleName Get-NodeInternalIp { return $expectedIp } -Verifiable -ParameterFilter { $Addresses.Count -eq $json.status.addresses.Count }
        }

        It 'returns correctly constructed node info' {
            InModuleScope $moduleName -Parameters @{
                json                   = $json
                expectedStatus         = $expectedStatus
                expectedRole           = $expectedRole
                expectedAge            = $expectedAge
                expectedIp             = $expectedIp
                expectedName           = $expectedName
                expectedKubeletVersion = $expectedKubeletVersion
                expectedOs             = $expectedOs
                expectedKernel         = $expectedKernel
                expectedRuntime        = $expectedRuntime
            } {
                $result = Get-Node -JsonNode $json

                $result.Status | Should -Be $expectedStatus.StatusText
                $result.Name | Should -Be $expectedName
                $result.Role | Should -Be $expectedRole
                $result.Age | Should -Be $expectedAge
                $result.KubeletVersion | Should -Be $expectedKubeletVersion
                $result.InternalIp | Should -Be $expectedIp
                $result.OsImage | Should -Be $expectedOs
                $result.KernelVersion | Should -Be $expectedKernel
                $result.ContainerRuntime | Should -Be $expectedRuntime
                $result.IsReady | Should -Be $expectedStatus.IsReady
            }
        }
    }

    Context 'JSON node not specified' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-Node } | Should -Throw
            }
        }
    }
}

Describe 'Get-PodStatus' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'no JSON node specified' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-PodStatus } | Should -Throw
            }
        }
    }

    Context 'no container existing yet' {
        BeforeAll {
            $json = [PSCustomObject]@{
                status = [PSCustomObject]@{
                    phase = 'planning'
                }
                spec   = [PSCustomObject]@{
                    containers = [PSCustomObject]@{}, [PSCustomObject]@{}
                }
            }

            InModuleScope $moduleName -Parameters @{json = $json } {
                $script:result = Get-PodStatus -JsonNode $json
            }
        }

        It 'returns Pod not running' {
            InModuleScope $moduleName {
                $result.IsRunning | Should -BeFalse
            }
        }

        It 'returns Pod phase' {
            InModuleScope $moduleName {
                $result.StatusText | Should -Be 'planning'
            }
        }

        It 'returns zero restarts' {
            InModuleScope $moduleName {
                $result.Restarts | Should -Be 0
            }
        }

        It 'returns zero ready containers' {
            InModuleScope $moduleName {
                $result.Ready | Should -Be '0/2'
            }
        }
    }

    Context 'two container existing, but neither ready nor running' {
        BeforeAll {
            $json = [PSCustomObject]@{
                status = [PSCustomObject]@{
                    containerStatuses = [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            Value = [PSCustomObject]@{reason = 'not in the mood' }
                        }
                        restartCount = 3
                    }, [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            Value = [PSCustomObject]@{reason = 'indecisive' }
                        }
                        restartCount = 5
                    }
                }
                spec   = [PSCustomObject]@{
                    containers = [PSCustomObject]@{}, [PSCustomObject]@{}
                }
            }

            InModuleScope $moduleName -Parameters @{json = $json } {
                $script:result = Get-PodStatus -JsonNode $json
            }
        }

        It 'returns Pod not running' {
            InModuleScope $moduleName {
                $result.IsRunning | Should -BeFalse
            }
        }

        It 'returns reason for last container not running' {
            InModuleScope $moduleName {
                $result.StatusText | Should -Be 'indecisive'
            }
        }

        It 'returns restarts of containers' {
            InModuleScope $moduleName {
                $result.Restarts | Should -Be (3 + 5)
            }
        }

        It 'returns zero ready containers' {
            InModuleScope $moduleName {
                $result.Ready | Should -Be '0/2'
            }
        }
    }

    Context 'two container existing, but only one ready and running' {
        BeforeAll {
            $json = [PSCustomObject]@{
                status = [PSCustomObject]@{
                    containerStatuses = [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            Value = [PSCustomObject]@{reason = 'not in the mood' }
                        }
                        restartCount = 3
                    }, [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            'running' = ''
                        }
                        restartCount = 5
                        ready        = $true
                    }
                }
                spec   = [PSCustomObject]@{
                    containers = [PSCustomObject]@{}, [PSCustomObject]@{}
                }
            }

            InModuleScope $moduleName -Parameters @{json = $json } {
                $script:result = Get-PodStatus -JsonNode $json
            }
        }

        It 'returns Pod not running' {
            InModuleScope $moduleName {
                $result.IsRunning | Should -BeFalse
            }
        }

        It 'returns reason for container not running' {
            InModuleScope $moduleName {
                $result.StatusText | Should -Be 'not in the mood'
            }
        }

        It 'returns restarts of containers' {
            InModuleScope $moduleName {
                $result.Restarts | Should -Be (3 + 5)
            }
        }

        It 'returns one ready container' {
            InModuleScope $moduleName {
                $result.Ready | Should -Be '1/2'
            }
        }
    }

    Context 'two container ready and running' {
        BeforeAll {
            $json = [PSCustomObject]@{
                status = [PSCustomObject]@{
                    containerStatuses = [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            'running' = ''
                        }
                        restartCount = 3
                        ready        = $true
                    }, [PSCustomObject]@{
                        state        = [PSCustomObject]@{
                            'running' = ''
                        }
                        restartCount = 5
                        ready        = $true
                    }
                }
                spec   = [PSCustomObject]@{
                    containers = [PSCustomObject]@{}, [PSCustomObject]@{}
                }
            }

            InModuleScope $moduleName -Parameters @{json = $json } {
                $script:result = Get-PodStatus -JsonNode $json
            }
        }

        It 'returns Pod running' {
            InModuleScope $moduleName {
                $result.IsRunning | Should -BeTrue
            }
        }

        It 'returns status indicating containers are running' {
            InModuleScope $moduleName {
                $result.StatusText | Should -Be 'Running'
            }
        }

        It 'returns restarts of containers' {
            InModuleScope $moduleName {
                $result.Restarts | Should -Be (3 + 5)
            }
        }

        It 'returns all containers ready' {
            InModuleScope $moduleName {
                $result.Ready | Should -Be '2/2'
            }
        }
    }
}

Describe 'Get-Pod' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'JSON is valid' {
        BeforeAll {
            $expectedStatus = @{StatusText = 'good'; IsRunning = $true; Ready = 'yeah'; Restarts = 23 }
            $expectedAge = 'old'
            $expectedIp = 'localhost'
            $expectedName = 'test pod'
            $expectedNamespace = 'test ns'
            $expectedNode = 'test node'

            $json = [PSCustomObject]@{
                status   = [PSCustomObject]@{
                    podIP = $expectedIp
                }
                metadata = [PSCustomObject]@{
                    name              = $expectedName
                    namespace         = $expectedNamespace
                    creationTimestamp = [datetime]::new(2023, 1, 2)
                }
                spec     = [PSCustomObject]@{
                    nodeName = $expectedNode
                }
            }

            Mock -ModuleName $moduleName Get-PodStatus { return $expectedStatus } -Verifiable -ParameterFilter { $JsonNode -eq $json }
            Mock -ModuleName $moduleName Get-Age { return $expectedAge } -Verifiable -ParameterFilter { $Timestamp -eq $($json.metadata.creationTimestamp.ToString()) }
        }

        It 'returns correctly constructed pod info' {
            InModuleScope $moduleName -Parameters @{
                json              = $json
                expectedStatus    = $expectedStatus
                expectedAge       = $expectedAge
                expectedIp        = $expectedIp
                expectedName      = $expectedName
                expectedNamespace = $expectedNamespace
                expectedNode      = $expectedNode
            } {
                $result = Get-Pod -JsonNode $json

                $result.Status | Should -Be $expectedStatus.StatusText
                $result.Namespace | Should -Be $expectedNamespace
                $result.Name | Should -Be $expectedName
                $result.Ready | Should -Be $expectedStatus.Ready
                $result.Restarts | Should -Be $expectedStatus.Restarts
                $result.Age | Should -Be $expectedAge
                $result.Ip | Should -Be $expectedIp
                $result.Node | Should -Be $expectedNode
                $result.IsRunning | Should -Be $expectedStatus.IsRunning
            }
        }
    }

    Context 'JSON node not specified' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-Pod } | Should -Throw
            }
        }
    }
}

Describe 'Get-PodsForNamespace' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'namespace not specified' {
        It 'throws' {
            InModuleScope $moduleName {
                { Get-PodsForNamespace } | Should -Throw
            }
        }
    }

    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            InModuleScope $moduleName {
                { Get-PodsForNamespace -Namespace 'test-ns' } | Should -Throw -ExpectedMessage 'oops'
            }
        }
    }

    Context 'one pod existing in namespace' {
        BeforeAll {
            $expectedApiVersion = 'test-version'
            $expectedName = 'test-pod'
            $expectedNamespace = 'test-ns'

            $obj = [PSCustomObject]@{
                apiVersion = $expectedApiVersion
                items      = [System.Collections.ArrayList]@(
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{
                            name      = $expectedName
                            namespace = $expectedNamespace
                        }
                    } )
            }
            $invokeResult = [pscustomobject] @{Output = (ConvertTo-Json $obj -Depth 20); Success = $true }
            $pod = [PSCustomObject]@{
                Name      = $expectedName
                Namespace = $expectedNamespace
            }

            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -Verifiable -ParameterFilter { $Params -contains $expectedNamespace }
            Mock -ModuleName $moduleName Confirm-ApiVersionIsValid { return } -Verifiable -ParameterFilter { $Version -eq $expectedApiVersion }
            Mock -ModuleName $moduleName Get-Pod { return $pod } -Verifiable -ParameterFilter { $JsonNode.Name -eq $obj.items[0].Name }

            InModuleScope $moduleName -Parameters @{namespace = $expectedNamespace } {
                $script:result = Get-PodsForNamespace $namespace
            }
        }

        It 'checks API version validity' {
            Should -InvokeVerifiable
        }

        It 'returns single Pod' {
            InModuleScope $moduleName -Parameters @{expectedName = $expectedName; expectedNamespace = $expectedNamespace } {
                $result.Name | Should -Be $expectedName
                $result.Namespace | Should -Be $expectedNamespace
            }
        }
    }

    Context 'multiple pods existing in namespace' {
        BeforeAll {
            $expectedApiVersion = 'test-version'
            $expectedNamespace = 'test-ns'

            $obj = [PSCustomObject]@{
                apiVersion = $expectedApiVersion
                items      = [System.Collections.ArrayList]@(
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{
                            name      = 'pod-1'
                            namespace = $expectedNamespace
                        }
                    },
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{
                            name      = 'pod-2'
                            namespace = $expectedNamespace
                        }
                    } )
            }
            $invokeResult = [pscustomobject] @{Output = (ConvertTo-Json $obj -Depth 20); Success = $true }
            $pods = [System.Collections.ArrayList]@(
                [PSCustomObject]@{
                    Name      = 'pod-1'
                    Namespace = $expectedNamespace
                },
                [PSCustomObject]@{
                    Name      = 'pod-2'
                    Namespace = $expectedNamespace
                }
            )
            $script:index = -1

            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -Verifiable -ParameterFilter { $Params -contains $expectedNamespace }
            Mock -ModuleName $moduleName Confirm-ApiVersionIsValid {  } -Verifiable -ParameterFilter { $Version -eq $expectedApiVersion }
            Mock -ModuleName $moduleName Get-Pod { $script:index++; return $pods[$script:index] } -ParameterFilter { $JsonNode.Name -eq $obj.items[$script:index].Name }

            InModuleScope $moduleName -Parameters @{namespace = $expectedNamespace } {
                $script:result = Get-PodsForNamespace $namespace
            }
        }

        It 'checks API version validity' {
            Should -InvokeVerifiable
        }

        It 'returns multiple Pods' {
            InModuleScope $moduleName -Parameters @{expectedNamespace = $expectedNamespace } {
                $result.Count | Should -Be 2

                for ($i = 0; $i -lt $result.Count; $i++) {
                    $result[$i].Name | Should -Be "pod-$($i+1)"
                    $result[$i].Namespace | Should -Be $expectedNamespace
                }
            }
        }
    }
}

Describe 'Get-PodsWithPersistentVolumeClaims' -Tag 'unit', 'ci' {
    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
            Mock -ModuleName $moduleName Write-Information { }
        }

        It 'logs the error' {
            InModuleScope $moduleName {
                Get-PodsWithPersistentVolumeClaims

                Should -Invoke Write-Information -Times 1 -Scope Context -ParameterFilter { $MessageData -match 'oops' }
            }
        }
    }

    Context 'No Pod with PVCs exists' {
        BeforeAll {
            $output = @'
            [{name:%pod-0%, volumes:[]},
            {name:%pod-1%, volumes:[]},
            {name:%pod-2%, volumes:[]},]
'@
            $invokeResult = [pscustomobject] @{Output = $output; Success = $true }

            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult }
        }

        It 'returns nothing' {
            InModuleScope $moduleName {
                Get-PodsWithPersistentVolumeClaims | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Single Pod with PVCs exists' {
        BeforeAll {
            $output = @'
            [{name:%pod-0%, volumes:[%pvc-0%,]},
            {name:%pod-1%, volumes:[]},
            {name:%pod-2%, volumes:[]},]
'@
            $invokeResult = [pscustomobject] @{Output = $output; Success = $true }

            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult }
        }

        It 'returns single Pod with PVC information' {
            InModuleScope $moduleName {
                $result = Get-PodsWithPersistentVolumeClaims

                $result.name | Should -Be 'pod-0'
                $result.volumes.Count | Should -Be 1
                $result.volumes[0] | Should -Be 'pvc-0'
            }
        }
    }

    Context 'Multiple Pods with PVCs exist' {
        BeforeAll {
            $output = @'
            [{name:%pod-0%, volumes:[%pvc-0%,]},
            {name:%pod-1%, volumes:[]},
            {name:%pod-2%, volumes:[%pvc-1%,%pvc-2%,]},
            {name:%pod-3%, volumes:[]},]
'@
            $invokeResult = [pscustomobject] @{Output = $output; Success = $true }

            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult }
        }

        It 'returns only those Pods with PVC information' {
            InModuleScope $moduleName {
                $result = Get-PodsWithPersistentVolumeClaims

                $result.Count | Should -Be 2
                $result[0].name | Should -Be 'pod-0'
                $result[0].volumes.Count | Should -Be 1
                $result[0].volumes[0] | Should -Be 'pvc-0'
                $result[1].name | Should -Be 'pod-2'
                $result[1].volumes.Count | Should -Be 2
                $result[1].volumes[0] | Should -Be 'pvc-1'
                $result[1].volumes[1] | Should -Be 'pvc-2'
            }
        }
    }
}

Describe 'Get-AllPersistentVolumeClaims' -Tag 'unit', 'ci' {
    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
            Mock -ModuleName $moduleName Write-Information { }
        }

        It 'logs the error' {
            InModuleScope $moduleName {
                Get-AllPersistentVolumeClaims

                Should -Invoke Write-Information -Times 1 -Scope Context -ParameterFilter { $MessageData -match 'oops' }
            }
        }
    }

    Context 'No PVCs retrieved' {
        BeforeAll {
            $json = @'
            {
                "items":[]
            }
'@
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }
        }

        It 'returns an empty array' {
            InModuleScope $moduleName {
                $result = Get-AllPersistentVolumeClaims

                $result.Count | Should -Be 0
            }
        }
    }

    Context 'Single PVC retrieved' {
        BeforeAll {
            $json = @'
            {
                "items":[{"id":"test-item-0"}]
            }
'@
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'some piping value'; Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }
        }

        It 'returns an array with this PVC' {
            InModuleScope $moduleName {
                $result = Get-AllPersistentVolumeClaims

                $result.id | Should -Be 'test-item-0'
            }
        }
    }

    Context 'Multiple PVCs retrieved' {
        BeforeAll {
            $json = @'
            {
                "items":[{"id":"test-item-0"},{"id":"test-item-1"},{"id":"test-item-2"}]
            }
'@
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'some piping value'; Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }
        }

        It 'returns an array of those PVCs' {
            InModuleScope $moduleName {
                $result = Get-AllPersistentVolumeClaims

                $result.Count | Should -Be 3
                $result[0].id | Should -Be 'test-item-0'
                $result[1].id | Should -Be 'test-item-1'
                $result[2].id | Should -Be 'test-item-2'
            }
        }
    }
}

Describe 'Write-Nodes' -Tag 'unit', 'ci' {
    Context 'no nodes specified' {
        It 'throws' {
            { Write-Nodes } | Should -Throw
        }
    }

    Context 'none of the nodes ready' {
        BeforeAll {
            $nodes = [pscustomobject]@{Status = 'idle' }, [pscustomobject]@{Status = 'lazy' }
        }

        It 'displays the info that some nodes are not ready' {
            $output = $(Write-Nodes $nodes ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'not ready'
        }
    }

    Context 'some nodes ready' {
        BeforeAll {
            $nodes = [pscustomobject]@{Status = 'Ready'; IsReady = $true }, [pscustomobject]@{Status = 'lazy' }
        }

        It 'displays the info that some nodes are not ready' {
            $output = $(Write-Nodes $nodes ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'not ready'
        }
    }

    Context 'all nodes ready' {
        BeforeAll {
            $nodes = [pscustomobject]@{Status = 'Ready'; IsReady = $true }, [pscustomobject]@{Status = 'Ready'; IsReady = $true }
        }

        It 'displays the info that all nodes are ready' {
            $output = $(Write-Nodes $nodes ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'are ready'
        }
    }
}

Describe 'Write-Pods' -Tag 'unit', 'ci' {
    Context 'no pods specified' {
        It 'throws' {
            { Write-Pods } | Should -Throw
        }
    }

    Context 'none of the pods running' {
        BeforeAll {
            $pods = [pscustomobject]@{Status = 'idle' }, [pscustomobject]@{Status = 'lazy' }
        }

        It 'displays the info that some pods are not running' {
            $output = $(Write-Pods $pods ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'not running'
        }
    }

    Context 'some pods running' {
        BeforeAll {
            $pods = [pscustomobject]@{Status = 'Running'; IsRunning = $true }, [pscustomobject]@{Status = 'lazy' }
        }

        It 'displays the info that some pods are not running' {
            $output = $(Write-Pods $pods ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'not running'
        }
    }

    Context 'all pods running' {
        BeforeAll {
            $pods = [pscustomobject]@{Status = 'Running'; IsRunning = $true }, [pscustomobject]@{Status = 'Running'; IsRunning = $true }
        }

        It 'displays the info that all pods are running' {
            $output = $(Write-Pods $pods ) *>&1

            $output.Count | Should -BeGreaterOrEqual 2
            $output[$output.Count - 1] | Should -Match 'are running'
        }
    }
}

Describe 'Get-Nodes' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            { Get-Nodes } | Should -Throw -ExpectedMessage 'oops'
        }
    }

    Context 'one node existing' {
        BeforeAll {
            $expectedApiVersion = 'test-version'
            $expectedName = 'test-node'

            $obj = [PSCustomObject]@{
                apiVersion = $expectedApiVersion
                items      = [System.Collections.ArrayList]@(
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{ name = $expectedName }
                    } )
            }
            $json = ConvertTo-Json $obj -Depth 20
            $node = [PSCustomObject]@{
                Name = $expectedName
            }

            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'piping value'; Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }
            Mock -ModuleName $moduleName Confirm-ApiVersionIsValid { return } -Verifiable -ParameterFilter { $Version -eq $expectedApiVersion }
            Mock -ModuleName $moduleName Get-Node { return $node } -Verifiable -ParameterFilter { $JsonNode.Name -eq $obj.items[0].Name }

            InModuleScope $moduleName {
                $script:result = Get-Nodes
            }
        }

        It 'checks API version validity' {
            Should -InvokeVerifiable
        }

        It 'returns single Node' {
            InModuleScope $moduleName -Parameters @{expectedName = $expectedName } {
                $result.Name | Should -Be $expectedName
            }
        }
    }

    Context 'multiple nodes existing' {
        BeforeAll {
            $expectedApiVersion = 'test-version'

            $obj = [PSCustomObject]@{
                apiVersion = $expectedApiVersion
                items      = [System.Collections.ArrayList]@(
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{ name = 'node-1' }
                    },
                    [PSCustomObject]@{
                        metadata = [PSCustomObject]@{ name = 'node-2' }
                    } )
            }
            $json = ConvertTo-Json $obj -Depth 20
            $nodes = [System.Collections.ArrayList]@(
                [PSCustomObject]@{ Name = 'node-1' },
                [PSCustomObject]@{ Name = 'node-2' }
            )
            $script:index = -1

            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'piping value'; Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }
            Mock -ModuleName $moduleName Confirm-ApiVersionIsValid {  } -Verifiable -ParameterFilter { $Version -eq $expectedApiVersion }
            Mock -ModuleName $moduleName Get-Node { $script:index++; return $nodes[$script:index] } -ParameterFilter { $JsonNode.Name -eq $obj.items[$script:index].Name }

            InModuleScope $moduleName {
                $script:result = Get-Nodes
            }
        }

        It 'checks API version validity' {
            Should -InvokeVerifiable
        }

        It 'returns multiple Pods' {
            InModuleScope $moduleName {
                $result.Count | Should -Be 2

                for ($i = 0; $i -lt $result.Count; $i++) {
                    $result[$i].Name | Should -Be "node-$($i+1)"
                }
            }
        }
    }
}

Describe 'Get-SystemPods' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'one Pod per namespace found' {
        BeforeAll {
            $flannelPod = [pscustomobject]@{Name = 'flannel-pod' }
            $systemPod = [pscustomobject]@{Name = 'system-pod' }

            Mock -ModuleName $moduleName Get-PodsForNamespace { return $flannelPod } -ParameterFilter { $Namespace -eq 'kube-flannel' }
            Mock -ModuleName $moduleName Get-PodsForNamespace { return $systemPod } -ParameterFilter { $Namespace -eq 'kube-system' }
        }

        It 'returns list of Pods' {
            InModuleScope $moduleName {
                $pods = Get-SystemPods
                $pods.Count | Should -Be 2
                $pods[0].Name | Should -Be 'flannel-pod'
                $pods[1].Name | Should -Be 'system-pod'
            }
        }
    }

    Context 'multiple Pods per namespace found' {
        BeforeAll {
            $flannelPods = [pscustomobject]@{Name = 'flannel-pod-1' }, [pscustomobject]@{Name = 'flannel-pod-2' }
            $systemPods = [pscustomobject]@{Name = 'system-pod-1' }, [pscustomobject]@{Name = 'system-pod-2' }

            Mock -ModuleName $moduleName Get-PodsForNamespace { return $flannelPods } -ParameterFilter { $Namespace -eq 'kube-flannel' }
            Mock -ModuleName $moduleName Get-PodsForNamespace { return $systemPods } -ParameterFilter { $Namespace -eq 'kube-system' }
        }

        It 'returns list of Pods' {
            InModuleScope $moduleName {
                $pods = Get-SystemPods
                $pods.Count | Should -Be 4
                $pods[0].Name | Should -Be 'flannel-pod-1'
                $pods[1].Name | Should -Be 'flannel-pod-2'
                $pods[2].Name | Should -Be 'system-pod-1'
                $pods[3].Name | Should -Be 'system-pod-2'
            }
        }
    }
}

Describe 'Get-K8sVersionInfo' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }
    
    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            { Get-K8sVersionInfo } | Should -Throw -ExpectedMessage 'oops'
        }
    }

    Context 'K8s version info getrieved from K8s API' {
        BeforeAll {
            $expectedServerVersion = '101'
            $expectedClientVersion = '010'

            $obj = [PSCustomObject]@{
                clientVersion = [PSCustomObject]@{
                    gitVersion = $expectedClientVersion
                };
                serverVersion = [PSCustomObject]@{
                    gitVersion = $expectedServerVersion
                }
            }
            $json = ConvertTo-Json $obj -Depth 20

            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'piping value'; Success = $true } }
            Mock -ModuleName $moduleName Out-String { return $json }

            InModuleScope $moduleName {
                $script:result = Get-K8sVersionInfo
            }
        }

        It 'returns K8s version info' {
            InModuleScope $moduleName -Parameters @{expectedServerVersion = $expectedServerVersion; expectedClientVersion = $expectedClientVersion } {
                $result.K8sServerVersion | Should -Be $expectedServerVersion
                $result.K8sClientVersion | Should -Be $expectedClientVersion
            }
        }
    }
}

Describe 'Add-Secret' -Tag 'unit', 'ci' {
    Context 'Name not specified' {
        It 'throws' {
            { Add-Secret -Namespace 'ns' -Literals '1', '2' } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'Namespace not specified' {
        It 'throws' {
            { Add-Secret -Name 'n' -Literals '1', '2' } | Should -Throw -ExpectedMessage 'Namespace not specified'
        }
    }

    Context 'Literals not specified' {
        It 'throws' {
            { Add-Secret -Name 'top secret' -Namespace 'ns' } | Should -Throw -ExpectedMessage 'Literals not specified'
        }
    }

    Context 'Invoke-Kubectl fails retrieving the secret' {
        BeforeAll {
            $invokeResult = [pscustomobject]@{Output = 'oops'; Success = $false }

            Mock -ModuleName $moduleName Write-Output
            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -ParameterFilter { $Params -contains 'get' -and $Params -contains 'secret' -and $Params -contains 'test-name' -and $Params -contains 'test-ns' }
        }

        It 'throws' {
            { Add-Secret -Name 'test-name' -Namespace 'test-ns' -Literals '' } | Should -Throw -ExpectedMessage 'oops'
        }
    }

    Context 'Secret already existing' {
        BeforeAll {
            $invokeResult = [pscustomobject]@{Output = 'secret'; Success = $true }

            Mock -ModuleName $moduleName Write-Output
            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -ParameterFilter { $Params -contains 'get' -and $Params -contains 'secret' -and $Params -contains 'test-name' -and $Params -contains 'test-ns' }
        }

        It 'skips creation' {
            InModuleScope -ModuleName $moduleName {
                Add-Secret -Name 'test-name' -Namespace 'test-ns' -Literals ''

                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'already existing' }
            }
        }
    }

    Context 'Secret non-existent' {
        BeforeAll {
            $secretName = 'test-secret'
            $secretNamespace = 'test-ns'
            $getResult = [pscustomobject]@{Success = $true }

            Mock -ModuleName $moduleName Write-Output
            Mock -ModuleName $moduleName Invoke-Kubectl { return $getResult } -ParameterFilter { $Params -contains 'get' -and $Params -contains 'secret' -and $Params -contains $secretName -and $Params -contains $secretNamespace }
        }

        Context 'Invoke-Kubectl fails creating the secret' {
            BeforeAll {
                $invokeResult = [pscustomobject]@{Output = 'oops'; Success = $false }

                Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -ParameterFilter { $Params -contains 'create' -and $Params -contains 'secret' -and $Params -contains $secretName -and $Params -contains $secretNamespace }
            }

            It 'throws' {
                InModuleScope -ModuleName $moduleName -Parameters @{secretName = $secretName; secretNamespace = $secretNamespace } {
                    { Add-Secret -Name $secretName -Namespace $secretNamespace -Literals '' } | Should -Throw -ExpectedMessage 'oops'
                }
            }
        }

        Context 'Invoke-Kubectl succeeds creating the secret' {
            BeforeAll {
                $literals = 'a=1', 'b=2', 'c=3'
                $invokeResult = [pscustomobject]@{Success = $true }

                Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult }
            }

            It 'creates the secret' {
                InModuleScope -ModuleName $moduleName -Parameters @{secretName = $secretName; secretNamespace = $secretNamespace; literals = $literals } {
                    Add-Secret -Name $secretName -Namespace $secretNamespace -Literals $literals

                    Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                        $Params -contains 'create' -and $Params -contains 'secret' -and $Params -contains $secretName -and $Params -contains $secretNamespace -and $Params -contains '--from-literal' -and $Params -contains 'a=1' -and $Params -contains 'b=2' -and $Params -contains 'c=3'
                    }
                }
            }
        }
    }
}

Describe 'Remove-Secret' -Tag 'unit', 'ci' {
    Context 'Name not specified' {
        It 'throws' {
            { Remove-Secret -Namespace 'ns' } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'Namespace not specified' {
        It 'throws' {
            { Remove-Secret -Name 'name' } | Should -Throw -ExpectedMessage 'Namespace not specified'
        }
    }

    
    Context 'Parameters valid' {
        BeforeAll {
            $secretName = 'test-secret'
            $secretNamespace = 'test-ns'
    
            Mock -ModuleName $moduleName Write-Output
        }
    
        Context 'Invoke-Kubectl fails deleting the secret' {
            BeforeAll {
                $invokeResult = [pscustomobject]@{Output = 'oops'; Success = $false }
    
                Mock -ModuleName $moduleName Write-Warning
                Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -ParameterFilter { $Params -contains 'delete' -and $Params -contains 'secret' -and $Params -contains $secretName -and $Params -contains $secretNamespace }
            }
    
            It 'logs a warning' {
                InModuleScope -ModuleName $moduleName -Parameters @{secretName = $secretName; secretNamespace = $secretNamespace } {
                    Remove-Secret -Name $secretName -Namespace $secretNamespace
    
                    Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'oops' }
                }
            }
        }
    
        Context 'Invoke-Kubectl succeeds deleting the secret' {
            BeforeAll {
                $invokeResult = [pscustomobject]@{Success = $true }
    
                Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult }
            }
    
            It 'deletes the secret' {
                InModuleScope -ModuleName $moduleName -Parameters @{secretName = $secretName; secretNamespace = $secretNamespace } {
                    Remove-Secret -Name $secretName -Namespace $secretNamespace
    
                    Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                        $Params -contains 'delete' -and $Params -contains 'secret' -and $Params -contains $secretName -and $Params -contains $secretNamespace
                    }
                }
            }
        }
    }
}

Describe 'Remove-PersistentVolumeClaim' -Tag 'unit', 'ci' {
    Context 'StorageClass not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Remove-PersistentVolumeClaim -Pvc @{test = '123' } -PodsWithPersistentVolumeClaims @() } | Should -Throw -ExpectedMessage 'StorageClass not specified'
            }
        }
    }

    Context 'PVC not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Remove-PersistentVolumeClaim -StorageClass 'test-class' -PodsWithPersistentVolumeClaims @() } | Should -Throw -ExpectedMessage 'PVC not specified'
            }
        }
    }

    Context 'Pods not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc @{test = '123' } } | Should -Throw -ExpectedMessage 'Pods not specified'
            }
        }
    }

    Context 'Invoke-Kubectl fails deleting the pvc' {
        BeforeAll {
            $invokeResult = [pscustomobject]@{Output = 'oops'; Success = $false }
            $pvc = [pscustomobject]@{metadata = [pscustomobject]@{name = 'test-pvc'; namespace = 'test-ns' } }
            $pods = @()

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Invoke-Kubectl { return $invokeResult } -ParameterFilter {
                $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains $pvc.metadata.name -and $Params -contains '-n' -and $Params -contains $pvc.metadata.namespace
            }
        }

        It 'logs a warning' {
            InModuleScope -ModuleName $moduleName -Parameters @{pvc = $pvc; pods = $pods } {
                Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc $pvc -PodsWithPersistentVolumeClaims $pods

                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'oops' }
            }
        }
    }

    Context 'No pods to check exist' {
        BeforeAll {
            $pvc = [pscustomobject]@{metadata = [pscustomobject]@{name = 'test-pvc'; namespace = 'test-ns' } }
            $pods = @()

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Invoke-Kubectl { return  [pscustomobject]@{Success = $true } }
        }

        It 'deletes the PVC' {
            InModuleScope -ModuleName $moduleName -Parameters @{pvc = $pvc; pods = $pods } {
                Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc $pvc -PodsWithPersistentVolumeClaims $pods

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains $pvc.metadata.name -and $Params -contains '-n' -and $Params -contains $pvc.metadata.namespace
                }
            }
        }
    }

    Context 'Pods without volumes exist' {
        BeforeAll {
            $pvc = [pscustomobject]@{metadata = [pscustomobject]@{name = 'test-pvc'; namespace = 'test-ns' } }
            $pods = [pscustomobject]@{}, [pscustomobject]@{}

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Invoke-Kubectl { return  [pscustomobject]@{Success = $true } }
        }

        It 'deletes the PVC' {
            InModuleScope -ModuleName $moduleName -Parameters @{pvc = $pvc; pods = $pods } {
                Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc $pvc -PodsWithPersistentVolumeClaims $pods

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains $pvc.metadata.name -and $Params -contains '-n' -and $Params -contains $pvc.metadata.namespace
                }
            }
        }
    }

    Context 'Pods with volumes that do not match the PVC exist' {
        BeforeAll {
            $pvc = [pscustomobject]@{metadata = [pscustomobject]@{name = 'test-pvc'; namespace = 'test-ns' } }
            $pods = [pscustomobject]@{volumes = 'v1', 'v2' }, [pscustomobject]@{volumes = 'v3', 'v4' }

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Invoke-Kubectl { return  [pscustomobject]@{Success = $true } }
        }

        It 'deletes the PVC' {
            InModuleScope -ModuleName $moduleName -Parameters @{pvc = $pvc; pods = $pods } {
                Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc $pvc -PodsWithPersistentVolumeClaims $pods

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains 'pvc' -and $Params -contains $pvc.metadata.name -and $Params -contains '-n' -and $Params -contains $pvc.metadata.namespace
                }
            }
        }
    }

    Context 'Pod with matching volume exist' {
        BeforeAll {
            $expectedMessage = "Pod 'p2' is still using PVC 'test-pvc' in namespace 'test-ns'. Delete all workloads using the SC 'test-class' and try again."
            $pvc = [pscustomobject]@{metadata = [pscustomobject]@{name = 'test-pvc'; namespace = 'test-ns' } }
            $pods = [pscustomobject]@{name = 'p1'; volumes = 'v1', 'v2' }, [pscustomobject]@{name = 'p2'; volumes = 'test-pvc', 'v4' }

            Mock -ModuleName $moduleName Write-Output {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName -Parameters @{pvc = $pvc; pods = $pods; expectedMessage = $expectedMessage } {
                { Remove-PersistentVolumeClaim -StorageClass 'test-class' -Pvc $pvc -PodsWithPersistentVolumeClaims $pods } | Should -Throw -ExpectedMessage $expectedMessage
            }
        }
    }
}

Describe 'Remove-PersistentVolumeClaimsForStorageClass' -Tag 'unit', 'ci' {
    Context 'StorageClass not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Remove-PersistentVolumeClaimsForStorageClass } | Should -Throw -ExpectedMessage 'StorageClass not specified'
            }
        }
    }

    Context 'Getting Pods with PVCs returns invalid data type' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { return 123 }
        }

        It 'throws' {
            { Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class' } | Should -Throw -ExpectedMessage 'invalid return type'
        }
    }

    Context 'Single Pods with PVCs found' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { return [pscustomobject]@{name = 'p1' } }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { }

            InModuleScope -ModuleName $moduleName {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class'
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'Found one Pod' }
            }
        }
    }

    Context 'Multiple Pods with PVCs found' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { return [pscustomobject]@{name = 'p1' }, [pscustomobject]@{name = 'p2' } }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { }

            InModuleScope -ModuleName $moduleName {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class'
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'Found 2 Pods' }
            }
        }
    }

    Context 'No Pods with PVCs found' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { return $null }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { }

            InModuleScope -ModuleName $moduleName {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class'
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'No Pods' }
            }
        }
    }

    Context 'No PVCs found' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { return $null }
            Mock -ModuleName $moduleName Remove-PersistentVolumeClaim { }

            InModuleScope -ModuleName $moduleName {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class'
            }
        }

        It 'removes nothing' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-PersistentVolumeClaim -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'No PVCs' -and $InputObject -match 'found' }
            }
        }
    }

    Context 'PVCs with non-matching SCs found' {
        BeforeAll {
            $pvcs = [pscustomobject]@{spec = [pscustomobject]@{storageClassName = 'sc-1' } }, [pscustomobject]@{spec = [pscustomobject]@{storageClassName = 'sc-2' } }

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { return $pvcs }
            Mock -ModuleName $moduleName Remove-PersistentVolumeClaim { }

            InModuleScope -ModuleName $moduleName {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass 'test-class'
            }
        }

        It 'removes nothing' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-PersistentVolumeClaim -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 1 -Scope Context -ParameterFilter { $InputObject -match 'No PVCs' -and $InputObject -match 'found' }
            }
        }
    }

    Context 'PVCs with matching SCs found' {
        BeforeAll {
            $storageClass = 'test-class'
            $pvcs = [pscustomobject]@{id = '0'; spec = [pscustomobject]@{storageClassName = 'sc-1' } },
            [pscustomobject]@{id = '1'; spec = [pscustomobject]@{storageClassName = $storageClass } },
            [pscustomobject]@{id = '2'; spec = [pscustomobject]@{storageClassName = 'sc-2' } },
            [pscustomobject]@{id = '3'; spec = [pscustomobject]@{storageClassName = $storageClass } }
            $pods = [pscustomobject]@{name = 'p1' }, [pscustomobject]@{name = 'p2' }

            Mock -ModuleName $moduleName Write-Output {}
            Mock -ModuleName $moduleName Get-PodsWithPersistentVolumeClaims { return $pods }
            Mock -ModuleName $moduleName Get-AllPersistentVolumeClaims { return $pvcs }
            Mock -ModuleName $moduleName Remove-PersistentVolumeClaim { }

            InModuleScope -ModuleName $moduleName -Parameters @{storageClass = $storageClass } {
                Remove-PersistentVolumeClaimsForStorageClass -StorageClass $storageClass
            }
        }

        It 'removes matching PVCs' {
            InModuleScope -ModuleName $moduleName -Parameters @{storageClass = $storageClass ; pods = $pods } {
                Should -Invoke Remove-PersistentVolumeClaim -Times 1 -Scope Context -ParameterFilter { $StorageClass -eq $storageClass -and $Pvc.id -eq '1' -and $PodsWithPersistentVolumeClaims[1].name -eq 'p2' }
                Should -Invoke Remove-PersistentVolumeClaim -Times 1 -Scope Context -ParameterFilter { $StorageClass -eq $storageClass -and $Pvc.id -eq '3' -and $PodsWithPersistentVolumeClaims[1].name -eq 'p2' }
            }
        }

        It 'does not inform the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Output -Times 0 -Scope Context -ParameterFilter { $InputObject -match 'No PVCs' -and $InputObject -match 'found' }
            }
        }
    }
}

Describe 'Wait-ForPodCondition' -Tag 'unit', 'ci' {
    Context 'Label not specified' {
        It 'throws' {
            { Wait-ForPodCondition } | Should -Throw -ExpectedMessage 'Label not specified'
        }
    }

    Context 'Condition invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForPodCondition -Label 'test-l' -Condition 'invalid' } | Should -Throw
            }
        }
    }

    Context 'Invoke-Kubectl fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForPodCondition -Label 'test' } | Should -Throw -ExpectedMessage 'oops'
            }
        }
    }

    Context 'Waits with default values' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true; Output = '' } }
        }

        It 'succeeds using default values' {
            InModuleScope -ModuleName $moduleName {
                $result = Wait-ForPodCondition -Label 'test-label'

                $result | Should -BeTrue

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'wait' -and $Params -contains 'pod' -and $Params -contains '-l' -and $Params -contains 'test-label' -and $Params -contains '-n' -and $Params -contains 'default' -and $Params -contains '--for=condition=ready' -and $Params -contains '--timeout=60s' }
            }
        }
    }

    Context 'Waits with custom values' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true; Output = '' } }
        }

        It 'succeeds using default values' {
            InModuleScope -ModuleName $moduleName {
                $result = Wait-ForPodCondition -Label 'test-label' -Namespace 'test-ns' -Condition 'Deleted' -TimeoutSeconds 123

                $result | Should -BeTrue

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'wait' -and $Params -contains 'pod' -and $Params -contains '-l' -and $Params -contains 'test-label' -and $Params -contains '-n' -and $Params -contains 'test-ns' -and $Params -contains '--for=delete' -and $Params -contains '--timeout=123s' }
            }
        }
    }
}
