# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\proxy.module.psm1"
    $moduleName = (Import-Module $module -PassThru -Force).Name
    
    Mock -ModuleName $moduleName Write-Log { }
    
    Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    Mock -ModuleName $moduleName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
    Mock -ModuleName $moduleName Get-ConfiguredClusterCIDR { return '172.20.0.0/16' }
    Mock -ModuleName $moduleName Get-ConfiguredClusterCIDRServices { return '172.21.0.0/16' }
    Mock -ModuleName $moduleName Get-ConfiguredControlPlaneCIDR { return '172.19.1.0/24' }
}

Describe 'Get-K2sHosts' -Tag 'unit', 'ci', 'proxy' {
    It 'returns expected K2s related hosts and patterns with all required values' {
        InModuleScope $moduleName {
            $result = Get-K2sHosts

            $result | Should -Contain 'localhost'
            $result | Should -Contain '127.0.0.1'
            $result | Should -Contain '::1'
            $result | Should -Contain '.local'
            $result | Should -Contain '.cluster.local'
            
            $result | Should -Contain '172.19.1.100'
            $result | Should -Contain '172.20.0.0/16'
            $result | Should -Contain '172.21.0.0/16'
        }
    }

    It 'throws exception when Control Plane IP is null' {
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return $null }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Control Plane IP is not configured*"
        }
    }

    It 'throws exception when Control Plane IP is empty string' {
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '' }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Control Plane IP is not configured*"
        }
    }

    It 'throws exception when Control Plane IP is whitespace' {
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '   ' }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Control Plane IP is not configured*"
        }
    }

    It 'throws exception when Cluster CIDR is null' {
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDR { return $null }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Cluster CIDR is not configured*"
        }
    }

    It 'throws exception when Cluster CIDR is empty string' {
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDR { return '' }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Cluster CIDR is not configured*"
        }
    }

    It 'throws exception when Cluster Service CIDR is null' {
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDRServices { return $null }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Cluster Service CIDR is not configured*"
        }
    }

    It 'throws exception when Cluster Service CIDR is empty string' {
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDRServices { return '' }
        
        InModuleScope $moduleName {
            { Get-K2sHosts } | Should -Throw "*Cluster Service CIDR is not configured*"
        }
    }

    It 'removes duplicate entries and returns unique values' {
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
        Mock -ModuleName $moduleName Get-ConfiguredKubeSwitchIP { return '172.19.1.100' }
        
        InModuleScope $moduleName {
            $result = Get-K2sHosts
            
            $duplicateCount = ($result | Where-Object { $_ -eq '172.19.1.100' } | Measure-Object).Count
            $duplicateCount | Should -Be 1
        }
    }

    It 'filters out null or whitespace entries' {
        InModuleScope $moduleName {
            $result = Get-K2sHosts
            
            $result | Where-Object { [string]::IsNullOrWhiteSpace($_) } | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-ProxyEnabledStatusFromWindowsSettings' -Tag 'unit', 'ci', 'proxy' {
    It 'returns true when ProxyEnable is set to 1' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyEnable = '1' } }
            
            $result = Get-ProxyEnabledStatusFromWindowsSettings
            
            $result | Should -Be $true
        }
    }

    It 'returns false when ProxyEnable is set to 0' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyEnable = '0' } }
            
            $result = Get-ProxyEnabledStatusFromWindowsSettings
            
            $result | Should -Be $false
        }
    }
}

Describe 'Get-ProxyServerFromWindowsSettings' -Tag 'unit', 'ci', 'proxy' {
    It 'returns proxy server from registry' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyServer = 'http://proxy.example.com:8080' } }
            
            $result = Get-ProxyServerFromWindowsSettings
            
            $result | Should -Be 'http://proxy.example.com:8080'
        }
    }

    It 'adds http:// prefix if missing' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyServer = 'proxy.example.com:8080' } }
            
            $result = Get-ProxyServerFromWindowsSettings
            
            $result | Should -Be 'http://proxy.example.com:8080'
        }
    }

    It 'handles null proxy server value' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyServer = $null } }
            
            $result = Get-ProxyServerFromWindowsSettings
            
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-ProxyOverrideFromWindowsSettings' -Tag 'unit', 'ci', 'proxy' {
    It 'returns proxy overrides with semicolons replaced by commas' {
        InModuleScope $moduleName {
            Mock Get-ItemProperty { return @{ ProxyOverride = 'localhost;127.0.0.1;*.local' } }
            
            $result = Get-ProxyOverrideFromWindowsSettings
            
            $result | Should -Be 'localhost,127.0.0.1,*.local'
        }
    }
}

Describe 'Get-OrUpdateProxyServer' -Tag 'unit', 'ci', 'proxy' {
    It 'returns provided proxy when specified' {
        InModuleScope $moduleName {
            $proxyValue = 'http://custom.proxy.com:8080'
            
            $result = Get-OrUpdateProxyServer -Proxy $proxyValue
            
            $result | Should -Be $proxyValue
        }
    }

    It 'retrieves proxy from Windows settings when not specified' {
        InModuleScope $moduleName {
            Mock Get-ProxyEnabledStatusFromWindowsSettings { return $true }
            Mock Get-ProxyServerFromWindowsSettings { return 'http://windows.proxy.com:8080' }
            
            $result = Get-OrUpdateProxyServer -Proxy ''
            
            $result | Should -Be 'http://windows.proxy.com:8080'
        }
    }

    It 'returns empty string when no proxy configured in Windows' {
        InModuleScope $moduleName {
            Mock Get-ProxyEnabledStatusFromWindowsSettings { return $false }
            
            $result = Get-OrUpdateProxyServer -Proxy ''
            
            $result | Should -Be ''
        }
    }
}

Describe 'New-ProxyConfig' -Tag 'unit', 'ci', 'proxy' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            Mock New-Item { }
            Mock Add-Content { }
        }
    }

    It 'creates config file with provided proxy settings' {
        InModuleScope $moduleName {
            $proxy = 'http://my.proxy.com:8080'
            $noProxy = @('localhost', '127.0.0.1')
            
            New-ProxyConfig -Proxy $proxy -NoProxy $noProxy
            
            Should -Invoke Add-Content -Exactly 1 -ParameterFilter { 
                $Value -eq "http_proxy=$proxy" 
            }
            Should -Invoke Add-Content -Exactly 1 -ParameterFilter { 
                $Value -eq "https_proxy=$proxy" 
            }
            Should -Invoke Add-Content -Exactly 1 -ParameterFilter { 
                $Value -eq "no_proxy=localhost,127.0.0.1" 
            }
        }
    }

    It 'retrieves settings from Windows registry when not provided' {
        InModuleScope $moduleName {
            Mock Get-ProxyEnabledStatusFromWindowsSettings { return $true }
            Mock Get-ProxyServerFromWindowsSettings { return 'http://windows.proxy.com:8080' }
            Mock Get-ProxyOverrideFromWindowsSettings { return 'localhost,127.0.0.1' }
            
            New-ProxyConfig -Proxy '' -NoProxy @()
            
            Should -Invoke Add-Content -Exactly 1 -ParameterFilter { 
                $Value -eq "http_proxy=http://windows.proxy.com:8080" 
            }
        }
    }

    It 'creates directory if it does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false } -ParameterFilter { $Path -like '*ProgramData\k2s' }
            
            New-ProxyConfig -Proxy 'http://test.com:8080' -NoProxy @()
            
            Should -Invoke New-Item -Exactly 1 -ParameterFilter { 
                $ItemType -eq 'Directory' 
            }
        }
    }
}

Describe 'Get-ProxyConfig' -Tag 'unit', 'ci', 'proxy' {
    It 'throws when config file does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            
            { Get-ProxyConfig } | Should -Throw "*Config file not found*"
        }
    }

    It 'parses config file correctly' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-Content { 
                return @(
                    "http_proxy='http://test.proxy.com:8080'",
                    "https_proxy='http://test.proxy.com:8080'",
                    "no_proxy='localhost,127.0.0.1,.local'"
                )
            }
            
            $result = Get-ProxyConfig
            
            $result.HttpProxy | Should -Be 'http://test.proxy.com:8080'
            $result.HttpsProxy | Should -Be 'http://test.proxy.com:8080'
            $result.NoProxy | Should -Contain 'localhost'
            $result.NoProxy | Should -Contain '127.0.0.1'
            $result.NoProxy | Should -Contain '.local'
        }
    }

    It 'handles empty no_proxy value' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-Content { 
                return @(
                    "http_proxy=http://test.proxy.com:8080",
                    "https_proxy=http://test.proxy.com:8080",
                    "no_proxy="
                )
            }
            
            $result = Get-ProxyConfig
            
            $actualEntries = $result.NoProxy | Where-Object { $_ }
            $actualEntries | Should -BeNullOrEmpty
        }
    }

    It 'removes quotes from values' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-Content { 
                return @(
                    'http_proxy="http://quoted.proxy.com:8080"',
                    "https_proxy='http://quoted.proxy.com:8080'",
                    "no_proxy='localhost'"
                )
            }
            
            $result = Get-ProxyConfig
            
            $result.HttpProxy | Should -Be 'http://quoted.proxy.com:8080'
            $result.HttpsProxy | Should -Be 'http://quoted.proxy.com:8080'
        }
    }
}

Describe 'Set-ProxyServer' -Tag 'unit', 'ci', 'proxy' {
    It 'throws when config file does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            
            { Set-ProxyServer -Proxy 'http://test.com:8080' } | Should -Throw "*Config file not found*"
        }
    }

    It 'updates both http_proxy and https_proxy and adds K2s hosts to no_proxy' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://old.proxy.com:8080'
                    HttpsProxy = 'http://old.proxy.com:8080'
                    NoProxy = @('example.com')
                }
            }
            Mock Get-K2sHosts {
                return @('localhost', '127.0.0.1', '.local', '.cluster.local', '172.19.1.100', '172.20.0.0/16', '172.21.0.0/16')
            }
            Mock Set-Content { }
            
            Set-ProxyServer -Proxy 'http://new.proxy.com:9090'
            
            Should -Invoke Set-Content -ParameterFilter {
                $Value -contains "http_proxy='http://new.proxy.com:9090'"
            }
            Should -Invoke Set-Content -ParameterFilter {
                $Value -contains "https_proxy='http://new.proxy.com:9090'"
            }
            Should -Invoke Set-Content -ParameterFilter {
                $Value -match "no_proxy='.*example\.com.*'" -and
                $Value -match "no_proxy='.*localhost.*'" -and
                $Value -match "no_proxy='.*\.local.*'" -and
                $Value -match "no_proxy='.*\.cluster\.local.*'"
            }
        }
    }

    It 'merges existing no_proxy entries with K2s hosts without duplicates' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://old.proxy.com:8080'
                    HttpsProxy = 'http://old.proxy.com:8080'
                    NoProxy = @('localhost', 'example.com')  # localhost already exists
                }
            }
            Mock Get-K2sHosts {
                return @('localhost', '127.0.0.1', '.local')
            }
            Mock Set-Content { }
            
            Set-ProxyServer -Proxy 'http://new.proxy.com:9090'
            
            Should -Invoke Set-Content -ParameterFilter {
                # Verify no duplicates - localhost should appear only once
                $noProxyLine = $Value | Where-Object { $_ -match "no_proxy=" }
                $noProxyValue = $noProxyLine -replace "no_proxy='", "" -replace "'", ""
                $entries = $noProxyValue -split ","
                ($entries | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1 -and
                $entries -contains 'example.com' -and
                $entries -contains '127.0.0.1' -and
                $entries -contains '.local'
            }
        }
    }

    It 'adds K2s hosts even when no_proxy is initially empty' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = ''
                    HttpsProxy = ''
                    NoProxy = @()
                }
            }
            Mock Get-K2sHosts {
                return @('localhost', '127.0.0.1', '.local', '.cluster.local')
            }
            Mock Set-Content { }
            
            Set-ProxyServer -Proxy 'http://proxy.example.com:8080'
            
            Should -Invoke Set-Content -ParameterFilter {
                $Value -match "no_proxy='.*localhost.*'" -and
                $Value -match "no_proxy='.*127\.0\.0\.1.*'" -and
                $Value -match "no_proxy='.*\.local.*'" -and
                $Value -match "no_proxy='.*\.cluster\.local.*'"
            }
        }
    }
}

Describe 'Add-NoProxyEntry' -Tag 'unit', 'ci', 'proxy' {
    It 'throws when config file does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            
            { Add-NoProxyEntry -Entries @('test.local') } | Should -Throw "*Config file not found*"
        }
    }

    It 'adds new entries to NoProxy array' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://test.proxy.com:8080'
                    HttpsProxy = 'http://test.proxy.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock Set-Content { }
            
            Add-NoProxyEntry -Entries @('example.com', 'test.local')
            
            Should -Invoke Set-Content -Exactly 1 -ParameterFilter {
                $Value -contains "no_proxy=localhost,example.com,test.local"
            }
        }
    }

    It 'does not add duplicate entries' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://test.proxy.com:8080'
                    HttpsProxy = 'http://test.proxy.com:8080'
                    NoProxy = @('localhost', 'example.com')
                }
            }
            Mock Set-Content { }
            
            Add-NoProxyEntry -Entries @('example.com', 'new.local')
            
            Should -Invoke Set-Content -Exactly 1 -ParameterFilter {
                $Value -contains "no_proxy=localhost,example.com,new.local"
            }
        }
    }
}

Describe 'Remove-NoProxyEntry' -Tag 'unit', 'ci', 'proxy' {
    It 'throws when config file does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            
            { Remove-NoProxyEntry -Entries @('test.local') } | Should -Throw "*Config file not found*"
        }
    }

    It 'removes specified entries from NoProxy array' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://test.proxy.com:8080'
                    HttpsProxy = 'http://test.proxy.com:8080'
                    NoProxy = @('localhost', 'example.com', 'test.local')
                }
            }
            Mock Set-Content { }
            
            Remove-NoProxyEntry -Entries @('example.com')
            
            Should -Invoke Set-Content -Exactly 1 -ParameterFilter {
                $Value -contains "no_proxy=localhost,test.local"
            }
        }
    }

    It 'handles removal of multiple entries' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://test.proxy.com:8080'
                    HttpsProxy = 'http://test.proxy.com:8080'
                    NoProxy = @('localhost', 'example.com', 'test.local', 'another.com')
                }
            }
            Mock Set-Content { }
            
            Remove-NoProxyEntry -Entries @('example.com', 'test.local')
            
            Should -Invoke Set-Content -Exactly 1 -ParameterFilter {
                $Value -contains "no_proxy=localhost,another.com"
            }
        }
    }

    It 'does not fail when removing non-existent entry' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true }
            Mock Get-ProxyConfig { 
                return [ProxyConfig]@{
                    HttpProxy = 'http://test.proxy.com:8080'
                    HttpsProxy = 'http://test.proxy.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock Set-Content { }
            
            { Remove-NoProxyEntry -Entries @('nonexistent.com') } | Should -Not -Throw
        }
    }
}

Describe 'Reset-ProxyConfig' -Tag 'unit', 'ci', 'proxy' {
    It 'throws when config file does not exist' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }
            
            { Reset-ProxyConfig } | Should -Throw "*Config file not found*"
        }
    }
}

Describe 'Add-K2sHostsToNoProxyEnvVar' -Tag 'unit', 'ci', 'proxy' {
    It 'adds K2s hosts to existing NO_PROXY environment variable' {
        InModuleScope $moduleName {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '.local') }
            $script:noProxyBaselineFp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-no-proxy-baseline-add-$PID.txt"
            $originalMachineNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
            $originalProcessNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            
            [Environment]::SetEnvironmentVariable("NO_PROXY", "existing.com,another.com", "Machine")
            
            try {
                Add-K2sHostsToNoProxyEnvVar
                
                $result = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
                $result | Should -Match 'localhost'
                $result | Should -Match 'existing.com'
            }
            finally {
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalMachineNoProxy, "Machine")
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalProcessNoProxy, "Process")
                Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'stores the original NO_PROXY value before adding K2s hosts' {
        InModuleScope $moduleName {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1') }
            $script:noProxyBaselineFp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-no-proxy-baseline-store-$PID.txt"
            $originalMachineNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
            $originalProcessNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            
            [Environment]::SetEnvironmentVariable("NO_PROXY", " existing.com, localhost ", "Machine")
            
            try {
                Add-K2sHostsToNoProxyEnvVar
                $baseline = Get-Content -Path $script:noProxyBaselineFp -Raw
                $result = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
                
                $baseline.Trim() | Should -Be 'existing.com,localhost'
                $result | Should -Be '127.0.0.1,existing.com,localhost'
            }
            finally {
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalMachineNoProxy, "Machine")
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalProcessNoProxy, "Process")
                Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            }
        }
    }

}

Describe 'Remove-K2sHostsFromNoProxyEnvVar' -Tag 'unit', 'ci', 'proxy' {
    It 'preserves K2s hosts that existed before K2s changed NO_PROXY' {
        InModuleScope $moduleName {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '.local') }
            $script:noProxyBaselineFp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-no-proxy-baseline-preserve-$PID.txt"
            $originalMachineNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
            $originalProcessNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            
            Set-Content -Path $script:noProxyBaselineFp -Value 'localhost,existing.com'
            [Environment]::SetEnvironmentVariable("NO_PROXY", "localhost,existing.com,127.0.0.1,.local", "Machine")
            
            try {
                Remove-K2sHostsFromNoProxyEnvVar
                
                $result = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
                $result | Should -Be 'existing.com,localhost'
                Test-Path -Path $script:noProxyBaselineFp | Should -Be $false
            }
            finally {
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalMachineNoProxy, "Machine")
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalProcessNoProxy, "Process")
                Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps required K2s hosts across an add and remove lifecycle when they were pre-existing' {
        InModuleScope $moduleName {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '::1', '172.19.1.100', '172.20.0.0/16', '172.21.0.0/16', '.local', '.cluster.local') }
            $script:noProxyBaselineFp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-no-proxy-baseline-lifecycle-$PID.txt"
            $originalMachineNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
            $originalProcessNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            $preExistingNoProxy = '.cluster.local,.local,::1,127.0.0.1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,localhost,172.19.1.0/24,carbonk8s.dev,svc.cluster.local'
            
            [Environment]::SetEnvironmentVariable("NO_PROXY", $preExistingNoProxy, "Machine")
            
            try {
                Add-K2sHostsToNoProxyEnvVar
                Remove-K2sHostsFromNoProxyEnvVar
                
                $result = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine") -split ','
                $result | Should -Contain '.cluster.local'
                $result | Should -Contain '.local'
                $result | Should -Contain '::1'
                $result | Should -Contain '127.0.0.1'
                $result | Should -Contain '172.19.1.100'
                $result | Should -Contain '172.20.0.0/16'
                $result | Should -Contain '172.21.0.0/16'
                $result | Should -Contain 'localhost'
                $result | Should -Contain 'carbonk8s.dev'
                $result | Should -Contain 'svc.cluster.local'
            }
            finally {
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalMachineNoProxy, "Machine")
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalProcessNoProxy, "Process")
                Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps NO_PROXY unchanged when no baseline is available' {
        InModuleScope $moduleName {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '.local') }
            $script:noProxyBaselineFp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-no-proxy-baseline-missing-$PID.txt"
            $originalMachineNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")
            $originalProcessNoProxy = [Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            
            Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            [Environment]::SetEnvironmentVariable("NO_PROXY", "localhost,existing.com,127.0.0.1,.local", "Machine")
            
            try {
                Remove-K2sHostsFromNoProxyEnvVar
                
                [Environment]::GetEnvironmentVariable("NO_PROXY", "Machine") | Should -Be 'localhost,existing.com,127.0.0.1,.local'
            }
            finally {
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalMachineNoProxy, "Machine")
                [Environment]::SetEnvironmentVariable("NO_PROXY", $originalProcessNoProxy, "Process")
                Remove-Item -Path $script:noProxyBaselineFp -Force -ErrorAction SilentlyContinue
            }
        }
    }

}

Describe 'Test-ProxyEnvVarsConfiguration' -Tag 'unit', 'ci', 'proxy' {
    BeforeEach {
        InModuleScope $moduleName {
            foreach ($scope in @('Process', 'Machine')) {
                [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $null, $scope)
                [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, $scope)
                [Environment]::SetEnvironmentVariable('NO_PROXY',    $null, $scope)
                [Environment]::SetEnvironmentVariable('http_proxy',  $null, $scope)
                [Environment]::SetEnvironmentVariable('https_proxy', $null, $scope)
                [Environment]::SetEnvironmentVariable('no_proxy',    $null, $scope)
            }
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '::1', '172.19.1.100', '172.20.0.0/16', '172.21.0.0/16', '.local', '.cluster.local') }
        }
    }

    AfterEach {
        InModuleScope $moduleName {
            foreach ($scope in @('Process', 'Machine')) {
                [Environment]::SetEnvironmentVariable('HTTP_PROXY',  $null, $scope)
                [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, $scope)
                [Environment]::SetEnvironmentVariable('NO_PROXY',    $null, $scope)
                [Environment]::SetEnvironmentVariable('http_proxy',  $null, $scope)
                [Environment]::SetEnvironmentVariable('https_proxy', $null, $scope)
                [Environment]::SetEnvironmentVariable('no_proxy',    $null, $scope)
            }
        }
    }

    It 'returns true when no proxy env vars are set in any scope' {
        InModuleScope $moduleName {
            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'returns true when all three proxy env vars are set with K2s hosts in NO_PROXY in Machine scope' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $noProxy,                        'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'returns true when all three proxy env vars are set with K2s hosts in NO_PROXY in Process scope' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $noProxy,                        'Process')

            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'throws when only HTTP_PROXY is set in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://proxy.example.com:8080', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*HTTPS_PROXY*'
        }
    }

    It 'throws when only HTTPS_PROXY is set in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*HTTP_PROXY*'
        }
    }

    It 'throws when only NO_PROXY is set in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*HTTP_PROXY*'
        }
    }

    It 'throws when HTTP_PROXY and HTTPS_PROXY are set but NO_PROXY is missing in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*NO_PROXY*'
        }
    }

    It 'throws when HTTP_PROXY and NO_PROXY are set but HTTPS_PROXY is missing in Machine scope' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',   $noProxy,                        'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*HTTPS_PROXY*'
        }
    }

    It 'throws when all three are set but NO_PROXY is missing K2s hosts in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    'some.other.host',               'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*missing required K2s hosts*'
        }
    }

    It 'throws when NO_PROXY is set but only partially contains K2s hosts in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    'localhost,127.0.0.1',            'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*missing required K2s hosts*'
        }
    }

    It 'throws when Machine scope is valid but Process scope has only HTTP_PROXY set' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $noProxy,                        'Machine')
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Process')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*Process*'
        }
    }

    It 'throws when Process scope NO_PROXY is missing K2s hosts even though Machine scope is valid' {
        InModuleScope $moduleName {
            $validNoProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $validNoProxy,                   'Machine')
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    'some.other.host',               'Process')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*missing required K2s hosts*'
        }
    }

    It 'throws with all violation messages when both scopes are invalid' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Process')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    'some.other.host',               'Process')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*ProxyValidation*'
        }
    }

    It 'does not throw when NO_PROXY contains K2s hosts with extra whitespace around entries' {
        InModuleScope $moduleName {
            $noProxy = 'localhost , 127.0.0.1 , ::1 , 172.19.1.100 , 172.20.0.0/16 , 172.21.0.0/16 , .local , .cluster.local'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $noProxy,                        'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'does not throw when NO_PROXY contains K2s hosts plus additional custom entries' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local,mycorp.internal,10.0.0.0/8'
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('NO_PROXY',    $noProxy,                        'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'does not throw when all three proxy env vars are set using lowercase names in Machine scope' {
        InModuleScope $moduleName {
            $noProxy = 'localhost,127.0.0.1,::1,172.19.1.100,172.20.0.0/16,172.21.0.0/16,.local,.cluster.local'
            [Environment]::SetEnvironmentVariable('http_proxy',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('https_proxy', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('no_proxy',    $noProxy,                        'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Not -Throw
        }
    }

    It 'throws when only lowercase http_proxy is set in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('http_proxy', 'http://proxy.example.com:8080', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*HTTPS_PROXY*'
        }
    }

    It 'throws when lowercase http_proxy and https_proxy are set but no_proxy is missing K2s hosts in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('http_proxy',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('https_proxy', 'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('no_proxy',    'some.other.host',               'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*missing required K2s hosts*'
        }
    }

    It 'throws when uppercase HTTP_PROXY and lowercase https_proxy are set but NO_PROXY is missing in Machine scope' {
        InModuleScope $moduleName {
            [Environment]::SetEnvironmentVariable('HTTP_PROXY',  'http://proxy.example.com:8080', 'Machine')
            [Environment]::SetEnvironmentVariable('https_proxy', 'http://proxy.example.com:8080', 'Machine')

            { Test-ProxyEnvVarsConfiguration } | Should -Throw '*NO_PROXY*'
        }
    }
}
