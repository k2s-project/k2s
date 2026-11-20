# SPDX-FileCopyrightText:  © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/Image-Common.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name

    # Every import copies the archive to its own '/tmp/k2s-image-import-<guid>.tar'; commands are recorded with that path replaced by '<archive>'
    $script:remotePathPattern = '/tmp/k2s-image-import-[0-9a-f]{32}\.tar'
    $script:cleanupCommand = 'sudo rm -f <archive>'
    $script:legacyDockerCommand = 'sudo buildah pull docker-archive:<archive> 2>&1'
    $script:legacyOciCommand = 'sudo buildah pull oci-archive:<archive> 2>&1'

    function Get-IndexedPullCommand {
        param([int]$Index)
        "sudo buildah pull docker-archive:<archive>:@$Index 2>&1"
    }

    function Initialize-RemoteCommandMocks {
        $script:executedCommands = [System.Collections.Generic.List[string]]::new()
        $script:rawCommands = [System.Collections.Generic.List[string]]::new()
        $script:copyTargets = [System.Collections.Generic.List[string]]::new()
        $script:failingCommands = @()
        $script:cleanupSucceeds = $true
        $script:cleanupThrows = $false

        Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey { $script:copyTargets.Add([string]$Target) }
        Mock -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey { $script:copyTargets.Add([string]$Target) }
        $commandMock = {
            $script:rawCommands.Add([string]$CmdToExecute)
            $command = ([string]$CmdToExecute) -replace $script:remotePathPattern, '<archive>'
            $script:executedCommands.Add($command)
            if ($command -eq $script:cleanupCommand) {
                if ($script:cleanupThrows) {
                    throw 'ssh connection lost'
                }
                return [PSCustomObject]@{ Success = $script:cleanupSucceeds; Output = '' }
            }
            [PSCustomObject]@{ Success = ($script:failingCommands -notcontains $command); Output = '' }
        }
        Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey $commandMock
        Mock -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey $commandMock
    }

    # The archive is copied once to a unique remote path, and every remote command uses exactly that path
    function Assert-SingleRemoteArchivePath {
        $script:copyTargets.Count | Should -Be 1
        $script:copyTargets[0] | Should -Match "^$script:remotePathPattern$"
        foreach ($rawCommand in $script:rawCommands) {
            foreach ($match in [regex]::Matches($rawCommand, '/tmp/\S+\.tar')) {
                $match.Value | Should -BeExactly $script:copyTargets[0]
            }
        }
    }

    $script:tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

    function New-TestArchive {
        param([string]$Name, [hashtable]$Files, [string[]]$MemberNames)
        $sourceDir = Join-Path $TestDrive "$Name-src"
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        foreach ($fileName in $Files.Keys) {
            $filePath = Join-Path $sourceDir $fileName
            New-Item -ItemType Directory -Path (Split-Path $filePath -Parent) -Force | Out-Null
            Set-Content -LiteralPath $filePath -Value $Files[$fileName] -Encoding Ascii -NoNewline
        }
        if (-not $MemberNames) {
            $MemberNames = @($Files.Keys)
        }
        $archivePath = Join-Path $TestDrive "$Name.tar"
        & $script:tarExe -cf $archivePath -C $sourceDir @MemberNames
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create test archive '$archivePath'" }
        return $archivePath
    }

    # Writes a ustar archive with the member names exactly as given (tar.exe would convert '\' and refuse '../' names).
    # A member with Pax = $true stores its name as a UTF-8 PAX 'path' record, as Go and Docker do for non-ASCII names.
    function New-RawTestArchive {
        param([string]$Name, [object[]]$Members)
        $stream = New-Object IO.MemoryStream
        $ascii = [Text.Encoding]::ASCII
        $writeEntry = {
            param([string]$EntryName, [byte[]]$Data, [string]$Type)
            $header = New-Object byte[] 512
            $put = { param([string]$Text, [int]$Offset) $bytes = $ascii.GetBytes($Text); [Array]::Copy($bytes, 0, $header, $Offset, $bytes.Length) }
            & $put $EntryName 0
            & $put '0000644' 100
            & $put '0000000' 108
            & $put '0000000' 116
            & $put ([Convert]::ToString($Data.Length, 8).PadLeft(11, '0')) 124
            & $put '00000000000' 136
            & $put '        ' 148
            & $put $Type 156
            & $put 'ustar' 257
            & $put '00' 263
            $sum = 0
            foreach ($byte in $header) { $sum += $byte }
            & $put ([Convert]::ToString($sum, 8).PadLeft(6, '0')) 148
            $header[154] = 0
            $stream.Write($header, 0, 512)
            $stream.Write($Data, 0, $Data.Length)
            $padding = (512 - ($Data.Length % 512)) % 512
            $stream.Write((New-Object byte[] $padding), 0, $padding)
        }
        foreach ($member in $Members) {
            $entryName = $member.Name
            if ($member.Pax) {
                $value = [Text.Encoding]::UTF8.GetBytes("path=$($member.Name)`n")
                $length = $value.Length + 2
                while ($length -ne ("$length".Length + 1 + $value.Length)) { $length = "$length".Length + 1 + $value.Length }
                & $writeEntry 'PaxHeader' ([byte[]]($ascii.GetBytes("$length ") + $value)) 'x'
                $entryName = 'pax-placeholder'
            }
            & $writeEntry $entryName ([Text.Encoding]::UTF8.GetBytes([string]$member.Content)) '0'
        }
        $stream.Write((New-Object byte[] 1024), 0, 1024)
        $archivePath = Join-Path $TestDrive "$Name.tar"
        [IO.File]::WriteAllBytes($archivePath, $stream.ToArray())
        return $archivePath
    }
}

Describe 'Image import helpers' -Tag 'unit', 'ci', 'image' {
    It 'returns preflight failures instead of exiting when return-status mode is requested' {
        InModuleScope $moduleName {
            Mock Test-SystemAvailability { [PSCustomObject]@{ Message = 'cluster unavailable' } }

            $result = Initialize-ImageScriptContext -ReturnStatus

            $result | Should -BeFalse
        }
    }

    It 'reports a failed Linux remote import using the result Success property and attempts cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey {}
            $script:remoteCommandCount = 0
            Mock Invoke-CmdOnVmViaSSHKey {
                $script:remoteCommandCount++
                if ($script:remoteCommandCount -eq 1) {
                    return [PSCustomObject]@{ Success = $false; Output = 'remote import failed' }
                }
                return [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            $script:remoteCommandCount | Should -Be 2
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 2 -Exactly
        }
    }

    It 'reports Linux copy exceptions, skips import, and still attempts remote cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey { throw 'copy failed' }
            Mock Invoke-CmdOnVmViaSSHKey {
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly
        }
    }

    It 'does not treat ctr output plus a false status as a successful import' {
        InModuleScope $moduleName {
            $result = Test-ImageImportSuccess -Result @('ctr import failed', $false)

            $result | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $false; Output = 'ctr import failed' })) | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $true; Output = '' })) | Should -BeTrue
        }
    }

    Context 'ConvertTo-ImageArchiveMemberPath' {
        # Expected values follow Go path.Clean, which Buildah applies to manifest paths and tar member names
        It 'normalizes <Path> to <Expected>' -ForEach @(
            @{ Path = 'manifest.json'; Expected = 'manifest.json' }
            @{ Path = './manifest.json'; Expected = 'manifest.json' }
            @{ Path = './/./manifest.json'; Expected = 'manifest.json' }
            @{ Path = 'layer.tar'; Expected = 'layer.tar' }
            @{ Path = './layer.tar'; Expected = 'layer.tar' }
            @{ Path = 'folder/layer.tar'; Expected = 'folder/layer.tar' }
            @{ Path = 'blobs//sha256/abc'; Expected = 'blobs/sha256/abc' }
            @{ Path = './blobs/sha256/./abc'; Expected = 'blobs/sha256/abc' }
            @{ Path = 'blobs/sha256/'; Expected = 'blobs/sha256' }
            @{ Path = 'a/../b/layer.tar'; Expected = 'b/layer.tar' }
            @{ Path = 'a/b/../../layer.tar'; Expected = 'layer.tar' }
            @{ Path = '../layer.tar'; Expected = '../layer.tar' }
            @{ Path = 'folder/../../layer.tar'; Expected = '../layer.tar' }
            @{ Path = '../../a/layer.tar'; Expected = '../../a/layer.tar' }
            @{ Path = '..'; Expected = '..' }
            @{ Path = '/manifest.json'; Expected = '/manifest.json' }
            @{ Path = '/../layer.tar'; Expected = '/layer.tar' }
            @{ Path = '//a//b'; Expected = '/a/b' }
            @{ Path = 'folder\layer.tar'; Expected = 'folder\layer.tar' }
            @{ Path = 'C:\layer.tar'; Expected = 'C:\layer.tar' }
            @{ Path = './'; Expected = '' }
            @{ Path = '.'; Expected = '' }
            @{ Path = ''; Expected = '' }
        ) {
            InModuleScope $moduleName -Parameters @{ Path = $Path; Expected = $Expected } {
                param($Path, $Expected)
                ConvertTo-ImageArchiveMemberPath -Path $Path | Should -BeExactly $Expected
            }
        }
    }

    Context 'Test-ImageArchiveMemberReference' {
        It 'accepts the archive-relative path <Path>' -ForEach @(
            @{ Path = 'layer.tar' }
            @{ Path = './layer.tar' }
            @{ Path = 'folder/layer.tar' }
            @{ Path = 'folder\layer.tar' }
            @{ Path = 'folder/sub\layer.tar' }
            @{ Path = 'blobs//sha256/abc' }
            @{ Path = 'a/../layer.tar' }
            @{ Path = 'sha256:abc/layer.tar' }
        ) {
            InModuleScope $moduleName -Parameters @{ Path = $Path } {
                param($Path)
                Test-ImageArchiveMemberReference -Path $Path | Should -BeTrue
            }
        }

        It 'rejects <Label> <Path>' -ForEach @(
            @{ Label = 'a parent-relative path'; Path = '../layer.tar' }
            @{ Label = 'a path leaving the root after cleaning'; Path = 'folder/../../layer.tar' }
            @{ Label = 'the parent directory'; Path = '..' }
            @{ Label = 'a backslash parent-relative path'; Path = '..\layer.tar' }
            @{ Label = 'a mixed-separator path leaving the root'; Path = 'folder\..\../layer.tar' }
            @{ Label = 'an absolute Unix path'; Path = '/layer.tar' }
            @{ Label = 'an absolute Unix path to a system file'; Path = '/etc/passwd' }
            @{ Label = 'a drive-qualified path'; Path = 'C:\images\layer.tar' }
            @{ Label = 'a drive-qualified path with slashes'; Path = 'C:/images/layer.tar' }
            @{ Label = 'a drive-relative path'; Path = 'C:layer.tar' }
            @{ Label = 'a UNC path'; Path = '\\server\share\layer.tar' }
            @{ Label = 'a UNC path with slashes'; Path = '//server/share/layer.tar' }
            @{ Label = 'a root-relative Windows path'; Path = '\layer.tar' }
            @{ Label = 'the archive root'; Path = './' }
            @{ Label = 'an empty path'; Path = '' }
        ) {
            InModuleScope $moduleName -Parameters @{ Path = $Path } {
                param($Path)
                Test-ImageArchiveMemberReference -Path $Path | Should -BeFalse
            }
        }
    }

    Context 'ConvertFrom-TarListingName' {
        It 'converts the tar.exe listing <Listed> back to the stored name' -ForEach @(
            @{ Listed = 'manifest.json'; Expected = 'manifest.json' }
            @{ Listed = 'folder\\layer.tar'; Expected = 'folder\layer.tar' }
            @{ Listed = 'a\\\\b'; Expected = 'a\\b' }
            @{ Listed = 'tab\there'; Expected = "tab`there" }
            @{ Listed = 'bell\007x'; Expected = "bell$([char]7)x" }
            @{ Listed = 'no\qescape'; Expected = 'no\qescape' }
        ) {
            InModuleScope $moduleName -Parameters @{ Listed = $Listed; Expected = $Expected } {
                param($Listed, $Expected)
                ConvertFrom-TarListingName -Name $Listed | Should -BeExactly $Expected
            }
        }

        It 'matches the escaping of the installed tar.exe for a member name containing a backslash' {
            $archive = New-RawTestArchive -Name 'listing-backslash' -Members @(@{ Name = 'folder\layer.tar'; Content = 'x' })
            $listed = @(& $script:tarExe -tf $archive)

            $listed | Should -Be @('folder\\layer.tar')
            InModuleScope $moduleName -Parameters @{ Listed = $listed[0] } {
                param($Listed)
                ConvertFrom-TarListingName -Name $Listed | Should -BeExactly 'folder\layer.tar'
            }
        }

        It 'matches the octal escaping of the installed tar.exe for control characters in member names' {
            $names = @("soh$([char]1).tar", "esc$([char]27).tar")
            $archive = New-RawTestArchive -Name 'listing-control' -Members @($names | ForEach-Object { @{ Name = $_; Content = 'x' } })
            $listed = @(& $script:tarExe -tf $archive)

            $listed | Should -Be @('soh\001.tar', 'esc\033.tar')
            InModuleScope $moduleName -Parameters @{ Listed = $listed; Names = $names } {
                param($Listed, $Names)
                @($Listed | ForEach-Object { ConvertFrom-TarListingName -Name $_ }) | Should -Be $Names
            }
        }
    }

    Context 'Get-DockerArchiveEntryProblem' {
        BeforeAll {
            function Get-EntryProblem {
                param([string]$Json, [string[]]$Members = @())
                InModuleScope $moduleName -Parameters @{ Json = $Json; Members = $Members } {
                    param($Json, $Members)
                    $entry = $Json | ConvertFrom-Json
                    Get-DockerArchiveEntryProblem -Entry $entry -Members $Members
                }
            }
            $script:members = @('manifest.json', 'a.json', 'a', 'a/layer.tar', 'blobs', 'blobs/sha256', 'blobs/sha256/l1')
        }

        It 'accepts a complete entry whose config and layers are archive members' {
            Get-EntryProblem -Json '{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["a/layer.tar","blobs/sha256/l1"]}' -Members $script:members | Should -BeNullOrEmpty
        }

        It 'accepts manifest paths that differ from the member names only by a ./ prefix' {
            Get-EntryProblem -Json '{"Config":"./a.json","RepoTags":["example.local/a:1"],"Layers":["./a/layer.tar"]}' -Members $script:members | Should -BeNullOrEmpty
        }

        It 'accepts an untagged entry with RepoTags <Label>' -ForEach @(
            @{ Label = 'null'; Json = '{"Config":"a.json","RepoTags":null,"Layers":["a/layer.tar"]}' }
            @{ Label = 'missing'; Json = '{"Config":"a.json","Layers":["a/layer.tar"]}' }
            @{ Label = 'empty'; Json = '{"Config":"a.json","RepoTags":[],"Layers":["a/layer.tar"]}' }
        ) {
            Get-EntryProblem -Json $Json -Members $script:members | Should -BeNullOrEmpty
        }

        It 'skips the member check when no member list is available' {
            Get-EntryProblem -Json '{"Config":"missing.json","RepoTags":["example.local/a:1"],"Layers":["missing.tar"]}' | Should -BeNullOrEmpty
        }

        It 'rejects an entry with <Label>' -ForEach @(
            @{ Label = 'no Config'; Json = '{"RepoTags":["example.local/a:1"],"Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'an empty Config'; Json = '{"Config":" ","Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'a numeric Config'; Json = '{"Config":42,"Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'no Layers'; Json = '{"Config":"a.json"}'; Pattern = "^'Layers' is missing or not an array" }
            @{ Label = 'a string Layers value'; Json = '{"Config":"a.json","Layers":"a/layer.tar"}'; Pattern = "^'Layers' is missing or not an array" }
            @{ Label = 'an empty layer path'; Json = '{"Config":"a.json","Layers":["a/layer.tar",""]}'; Pattern = "^'Layers' contains an item" }
            @{ Label = 'a numeric layer path'; Json = '{"Config":"a.json","Layers":[1]}'; Pattern = "^'Layers' contains an item" }
            @{ Label = 'a string RepoTags value'; Json = '{"Config":"a.json","RepoTags":"example.local/a:1","Layers":["a/layer.tar"]}'; Pattern = "^'RepoTags' is not an array" }
            @{ Label = 'a numeric tag'; Json = '{"Config":"a.json","RepoTags":[1],"Layers":["a/layer.tar"]}'; Pattern = "^'RepoTags' contains an item" }
            @{ Label = 'a missing config member'; Json = '{"Config":"b.json","Layers":["a/layer.tar"]}'; Pattern = '^archive member\(s\) not found: b\.json$' }
            @{ Label = 'missing layer members'; Json = '{"Config":"a.json","Layers":["a/layer.tar","b/layer.tar","c/layer.tar","b/layer.tar"]}'; Pattern = '^archive member\(s\) not found: b/layer\.tar, c/layer\.tar$' }
        ) {
            Get-EntryProblem -Json $Json -Members $script:members | Should -Match $Pattern
        }

        It 'rejects a value that is not a JSON object' {
            InModuleScope $moduleName {
                Get-DockerArchiveEntryProblem -Entry 'a.json' | Should -Be 'the entry is not a JSON object'
                Get-DockerArchiveEntryProblem -Entry $null | Should -Be 'the entry is not a JSON object'
            }
        }

        It 'rejects <Label> outside the archive even when no member list is available' -ForEach @(
            @{ Label = 'a parent-relative layer'; Json = '{"Config":"a.json","Layers":["../a/layer.tar"]}'; Expected = 'path(s) outside the archive: ../a/layer.tar' }
            @{ Label = 'a layer leaving the root after cleaning'; Json = '{"Config":"a.json","Layers":["a/../../layer.tar"]}'; Expected = 'path(s) outside the archive: a/../../layer.tar' }
            @{ Label = 'an absolute config'; Json = '{"Config":"/etc/a.json","Layers":["a/layer.tar"]}'; Expected = 'path(s) outside the archive: /etc/a.json' }
            @{ Label = 'a drive-qualified layer'; Json = '{"Config":"a.json","Layers":["C:\\a\\layer.tar"]}'; Expected = 'path(s) outside the archive: C:\a\layer.tar' }
            @{ Label = 'a UNC layer'; Json = '{"Config":"a.json","Layers":["\\\\server\\share\\layer.tar"]}'; Expected = 'path(s) outside the archive: \\server\share\layer.tar' }
        ) {
            Get-EntryProblem -Json $Json | Should -BeExactly $Expected
        }

        It 'does not match ../a/layer.tar to the member a/layer.tar' {
            # The former normalization turned '../a/layer.tar' into 'a/layer.tar' and accepted this entry
            Get-EntryProblem -Json '{"Config":"a.json","Layers":["../a/layer.tar"]}' -Members $script:members | Should -Match 'outside the archive'
        }

        It 'matches a backslash path only to a member stored with that backslash, like Buildah' {
            Get-EntryProblem -Json '{"Config":"a.json","Layers":["folder\\layer.tar"]}' -Members @('a.json', 'folder\layer.tar') | Should -BeNullOrEmpty
            Get-EntryProblem -Json '{"Config":"a.json","Layers":["folder\\layer.tar"]}' -Members @('a.json', 'folder/layer.tar') | Should -Be 'archive member(s) not found: folder\layer.tar'
            Get-EntryProblem -Json '{"Config":"a.json","Layers":["folder/layer.tar"]}' -Members @('a.json', 'folder\layer.tar') | Should -Be 'archive member(s) not found: folder/layer.tar'
        }
    }

    Context 'Linux image import routing for single- and multi-image archives' {
        BeforeAll {
            function New-TestManifestEntries {
                param([int]$Count)
                @(1..$Count | ForEach-Object {
                        [PSCustomObject]@{ Config = "config$_.json"; RepoTags = @("example.local/image${_}:v1"); Layers = @("layer$_.tar") }
                    })
            }

            $script:controlPlane = @{ Kind = 'ControlPlane'; Name = 'control-plane' }
        }

        BeforeEach {
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @(); Members = @() }

            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-DockerArchiveManifestInfo { $script:manifestInfo }
            Initialize-RemoteCommandMocks
        }

        It 'keeps the unindexed docker-archive command for a single-entry archive with -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $Source -eq 'C:\images\single.tar' }
            Assert-SingleRemoteArchivePath
        }

        It 'keeps the unindexed oci-archive command for a single-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
            @($script:executedCommands | Where-Object { $_ -match ':@\d' }).Count | Should -Be 0
        }

        It 'does not validate the entry of a single-entry archive and leaves error reporting to Buildah' {
            $entry = [PSCustomObject]@{ Config = 'missing.json'; RepoTags = @('example.local/single:1'); Layers = @('missing.tar') }
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = @($entry); Members = @('manifest.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry' }
        }

        It 'uses the same retry and timeout settings for the import and the cleanup of a single-image archive' {
            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 2 -Exactly -ParameterFilter { $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog }
        }

        It 'imports each entry of a two-entry archive once, in order, with an indexed selector' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $Source -eq 'C:\images\multi.tar' }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 3 -Exactly -ParameterFilter { $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog }
            Assert-SingleRemoteArchivePath
        }

        It 'logs each indexed pull with the tags and config of the manifest entry at that index' {
            $entries = @(
                [PSCustomObject]@{ Config = 'blobs/sha256/cfg-b'; RepoTags = @('example.local/b:1'); Layers = @('blobs/sha256/l1') }
                [PSCustomObject]@{ Config = 'blobs/sha256/cfg-a'; RepoTags = @('example.local/a:1', 'example.local/a:latest'); Layers = @('blobs/sha256/l1') }
            )
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -contains "[Import] Importing archive entry @0 (example.local/b:1, config 'blobs/sha256/cfg-b') on 'control-plane'"
            }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -contains "[Import] Importing archive entry @1 (example.local/a:1, example.local/a:latest, config 'blobs/sha256/cfg-a') on 'control-plane'"
            }
        }

        It 'automatically uses docker-archive selectors @0..@4 for a five-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            $expected = @(0..4 | ForEach-Object { Get-IndexedPullCommand $_ }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -like '*oci-archive*' }).Count | Should -Be 0
        }

        It 'issues a single pull for an entry with multiple RepoTags and no separate tag commands' {
            $entries = New-TestManifestEntries -Count 2
            $entries[0].RepoTags = @('example.local/python:3', 'example.local/python:3.14')
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands.Count | Should -Be 3
            @($script:executedCommands | Where-Object { $_ -eq (Get-IndexedPullCommand 0) }).Count | Should -Be 1
            @($script:executedCommands | Where-Object { $_ -match 'buildah tag' }).Count | Should -Be 0
        }

        It 'imports an untagged entry, logs a warning, and does not fail because of the missing tags' {
            $entries = New-TestManifestEntries -Count 2
            $entries[1].RepoTags = $null
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands | Should -Contain (Get-IndexedPullCommand 1)
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'entry @1 has no RepoTags' }
        }

        It 'attempts every entry after a middle entry fails, reports failure, and does not roll back' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand 2)

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $expected = @(0..4 | ForEach-Object { Get-IndexedPullCommand $_ }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -match 'rmi' }).Count | Should -Be 0
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match "archive entry @2 \(example\.local/image3:v1\) of 'C:\\images\\multi\.tar'" }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -match "Imported 4 of 5 images from 'C:\\images\\multi\.tar' on 'control-plane'; failed entries: @2\."
            }
        }

        It 'reports failure when only the <Position> entry fails, so a later success cannot mask it' -ForEach @(
            @{ Position = 'first'; FailingIndex = 0 }
            @{ Position = 'last'; FailingIndex = 2 }
        ) {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 3); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand $FailingIndex)

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            @($script:executedCommands | Where-Object { $_ -like 'sudo buildah pull*' }).Count | Should -Be 3
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match "failed entries: @$FailingIndex\." }
        }

        It 'treats a malformed remote result for an entry as a failure' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $script:executedCommands.Add((([string]$CmdToExecute) -replace $script:remotePathPattern, '<archive>'))
                if ($CmdToExecute -like '*:@1 2>&1') {
                    return @('buildah output', $true)
                }
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
        }

        It 'skips a structurally invalid entry, imports the other entries, and reports failure' {
            $entries = New-TestManifestEntries -Count 3
            $entries[1] = [PSCustomObject]@{ RepoTags = @('example.local/broken:1'); Layers = @('layer2.tar') }
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 2), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                "$Messages" -match "Skipping archive entry @1 \(example\.local/broken:1\) of 'C:\\images\\multi\.tar': invalid manifest\.json entry: 'Config' is missing"
            }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Imported 2 of 3 images.*failed entries: @1\.' }
        }

        It 'skips an entry whose layer is not an archive member' {
            $entries = New-TestManifestEntries -Count 2
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @('manifest.json', 'config1.json', 'layer1.tar', 'config2.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @1 .*archive member\(s\) not found: layer2\.tar' }
        }

        It 'runs no pulls but still copies, cleans up, and fails when every entry is invalid' {
            $entries = @([PSCustomObject]@{ Config = 'a.json' }, [PSCustomObject]@{ Layers = @('b.tar') })
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly $script:cleanupCommand
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Imported 0 of 2 images.*failed entries: @0, @1\.' }
        }

        It 'rejects an archive whose manifest.json is <State> without copying it or running any remote command' -ForEach @(
            @{ State = 'Invalid'; Reason = 'manifest.json is not valid JSON'; DockerArchive = $true }
            @{ State = 'Invalid'; Reason = 'manifest.json is empty or not a list of image entries'; DockerArchive = $false }
            @{ State = 'Invalid'; Reason = 'the archive contains 2 manifest.json members'; DockerArchive = $false }
            @{ State = 'Unreadable'; Reason = "tar.exe could not read 'manifest.json' (exit code 1)"; DockerArchive = $true }
        ) {
            $script:manifestInfo = [PSCustomObject]@{ State = $State; Reason = $Reason; Entries = @(); Members = @('manifest.json', 'index.json', 'oci-layout') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\broken.tar' -NodeInfo $script:controlPlane -DockerArchive:$DockerArchive

            $result | Should -BeFalse
            $script:executedCommands.Count | Should -Be 0
            $script:copyTargets.Count | Should -Be 0
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -eq "[Import] Image archive 'C:\images\broken.tar' is not imported on 'control-plane': $Reason"
            }
        }

        It 'keeps the legacy <Label> command without a warning when the archive cannot be inspected' -ForEach @(
            @{ DockerArchive = $true; Label = 'docker-archive' }
            @{ DockerArchive = $false; Label = 'oci-archive' }
        ) {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Unavailable'; Entries = @(); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\unreadable.tar' -NodeInfo $script:controlPlane -DockerArchive:$DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "sudo buildah pull ${Label}:<archive> 2>&1|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'invalid manifest|contains \d+ images' }
        }

        It 'keeps the legacy oci-archive command for OCI-only (add-on style) archives without manifest.json' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @(); Members = @('index.json', 'oci-layout') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\addon-image.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'runs no pulls but still cleans up when copying a multi-image archive fails' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey { $script:copyTargets.Add([string]$Target); throw 'copy failed' }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly $script:cleanupCommand
            Assert-SingleRemoteArchivePath
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match "Image import failed on 'control-plane': copy failed" }
        }

        It 'reports failure when cleanup fails after all entries were imported' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            $script:cleanupSucceeds = $false

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $script:executedCommands.Count | Should -Be 3
            $script:executedCommands[2] | Should -BeExactly $script:cleanupCommand
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -match "^\[Import\] Could not remove temporary image archive '$script:remotePathPattern' from 'control-plane'$"
            }
        }

        It 'reports failure without throwing when the cleanup command throws after a successful import' {
            $script:cleanupThrows = $true

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Could not remove temporary image archive .*: ssh connection lost$' }
        }

        It 'reports both the entry failure and the cleanup failure, in that order' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand 0)
            $script:cleanupThrows = $true
            $script:errorMessages = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Write-Log { if ($_Error) { $script:errorMessages.Add("$Messages") } }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            $script:errorMessages.Count | Should -Be 2
            $script:errorMessages[0] | Should -Match 'Imported 1 of 2 images.*failed entries: @0\.'
            $script:errorMessages[1] | Should -Match 'Could not remove temporary image archive .*: ssh connection lost$'
        }

        It 'uses a different remote archive path for every import' {
            Invoke-LinuxNodeImageImport -ImagePath 'C:\images\first.tar' -NodeInfo $script:controlPlane | Should -BeTrue
            Invoke-LinuxNodeImageImport -ImagePath 'C:\images\second.tar' -NodeInfo $script:controlPlane | Should -BeTrue

            $script:copyTargets.Count | Should -Be 2
            $script:copyTargets | ForEach-Object { $_ | Should -Match "^$script:remotePathPattern$" }
            $script:copyTargets[0] | Should -Not -Be $script:copyTargets[1]
            $script:rawCommands[1] | Should -BeExactly "sudo rm -f $($script:copyTargets[0])"
            $script:rawCommands[3] | Should -BeExactly "sudo rm -f $($script:copyTargets[1])"
        }

        It 'routes a multi-image import to a Linux worker with its IP address and user name' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo @{
                Kind      = 'LinuxWorker'
                Name      = 'worker-1'
                Username  = 'k2s'
                IpAddress = '192.0.2.1'
            } -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'C:\images\multi.tar' -and $Target -match "^$script:remotePathPattern$" -and $UserName -eq 'k2s' -and $IpAddress -eq '192.0.2.1'
            }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey -Times 3 -Exactly -ParameterFilter {
                $IpAddress -eq '192.0.2.1' -and $UserName -eq 'k2s' -and $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog
            }
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 0 -Exactly
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Exactly
            Assert-SingleRemoteArchivePath
        }
    }

    Context 'Get-DockerArchiveManifestInfo with generated archives' {
        BeforeAll {
            function Get-ManifestInfoInModule {
                param([string]$Path)
                InModuleScope $moduleName -Parameters @{ Path = $Path } {
                    param($Path)
                    Get-DockerArchiveManifestInfo -ImagePath $Path
                }
            }

            $script:twoEntryManifest = '[{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/b:1","example.local/b:latest"],"Layers":["b/layer.tar"]}]'
            $script:twoEntryFiles = @{ 'manifest.json' = $script:twoEntryManifest; 'a.json' = '{}'; 'a/layer.tar' = 'a'; 'b.json' = '{}'; 'b/layer.tar' = 'b' }
        }

        BeforeEach {
            Mock -ModuleName $moduleName Write-Log {}
            Initialize-RemoteCommandMocks
        }

        It 'reports Valid with two entries and the normalized member list for a two-entry manifest' {
            $archive = New-TestArchive -Name 'two-entries' -Files $script:twoEntryFiles

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            @($info.Entries)[1].RepoTags | Should -Contain 'example.local/b:latest'
            foreach ($member in 'manifest.json', 'a.json', 'a/layer.tar', 'b.json', 'b/layer.tar') {
                $info.Members | Should -Contain $member
            }
        }

        It 'reports Valid for an archive whose members are stored with a ./ prefix' {
            $archive = New-TestArchive -Name 'dot-prefix' -Files $script:twoEntryFiles -MemberNames @('./manifest.json', './a.json', './a/layer.tar', './b.json', './b/layer.tar')
            @(& $script:tarExe -tf $archive) | Should -Contain './manifest.json'

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            $info.Members | Should -Contain 'b/layer.tar'
            $info.Members | Should -Not -Contain './b/layer.tar'
        }

        It 'detects a one-entry manifest as Valid and keeps the unindexed <Label>-archive pull' -ForEach @(
            @{ DockerArchive = $true; Label = 'docker'; ExpectedCommand = 'sudo buildah pull docker-archive:<archive> 2>&1' }
            @{ DockerArchive = $false; Label = 'oci'; ExpectedCommand = 'sudo buildah pull oci-archive:<archive> 2>&1' }
        ) {
            # A one-element JSON array exercises the PS 5.1 ConvertFrom-Json handling in the real detection helper
            $archive = New-TestArchive -Name "single-entry-$Label" -Files @{
                'manifest.json' = '[{"Config":"a.json","RepoTags":["example.local/single:1","example.local/single:latest"],"Layers":["a/layer.tar"]}]'
                'a.json'        = '{}'
                'a/layer.tar'   = 'a'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 1
            @(@($info.Entries)[0].RepoTags) | Should -Be @('example.local/single:1', 'example.local/single:latest')

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive:$DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$ExpectedCommand|sudo rm -f <archive>"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'invalid manifest|contains \d+ images' }
            Assert-SingleRemoteArchivePath
        }

        It 'reports Valid based on manifest.json when the archive also contains index.json' {
            $files = $script:twoEntryFiles.Clone()
            $files['index.json'] = '{"schemaVersion":2,"manifests":[]}'
            $files['oci-layout'] = '{"imageLayoutVersion":"1.0.0"}'
            $archive = New-TestArchive -Name 'dual-format' -Files $files

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
        }

        It 'reports Invalid for a manifest.json containing <Label>' -ForEach @(
            @{ Label = 'an empty JSON array'; Content = '[]' }
            @{ Label = 'a JSON object instead of an array'; Content = '{"Config":"a.json","RepoTags":["example.local/a:1"]}' }
            @{ Label = 'malformed JSON'; Content = '[{"Config": "a.json", ' }
            @{ Label = 'no data'; Content = '' }
            @{ Label = 'only whitespace'; Content = "  `r`n " }
            @{ Label = 'JSON null'; Content = 'null' }
            @{ Label = 'a JSON string'; Content = '"manifest"' }
            @{ Label = 'an array of numbers'; Content = '[1,2]' }
            @{ Label = 'an array of strings'; Content = '["a.json","b.json"]' }
            @{ Label = 'a nested array'; Content = '[[{"Config":"a.json","Layers":[]}]]' }
            @{ Label = 'an array with a null item'; Content = '[{"Config":"a.json","Layers":[]},null]' }
        ) {
            $archive = New-TestArchive -Name "invalid-$($Label -replace '\W', '-')" -Files @{ 'manifest.json' = $Content }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Invalid'
            $info.Reason | Should -Match '^manifest\.json is (not valid JSON|empty or not a list of image entries)$'
            @($info.Entries).Count | Should -Be 0
        }

        It 'reports Invalid for an archive with <Label> and imports nothing on a Linux node' -ForEach @(
            @{ Label = 'two manifest.json members'; Names = @('manifest.json', 'manifest.json') }
            @{ Label = 'manifest.json and ./manifest.json'; Names = @('manifest.json', './manifest.json') }
        ) {
            $members = @(
                @{ Name = $Names[0]; Content = $script:twoEntryManifest }
                @{ Name = 'a.json'; Content = '{}' }; @{ Name = 'a/layer.tar'; Content = 'a' }
                @{ Name = 'b.json'; Content = '{}' }; @{ Name = 'b/layer.tar'; Content = 'b' }
                @{ Name = $Names[1]; Content = '[{"Config":"a.json","RepoTags":["example.local/other:1"],"Layers":["a/layer.tar"]}]' }
            )
            $archive = New-RawTestArchive -Name "dup-manifest-$($Label -replace '\W', '-')" -Members $members

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Invalid'
            $info.Reason | Should -Be 'the archive contains 2 manifest.json members'

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeFalse
            $script:executedCommands.Count | Should -Be 0
            $script:copyTargets.Count | Should -Be 0
        }

        It 'reports NotFound when the only manifest.json member has an absolute path, as Buildah would not find it' {
            $archive = New-RawTestArchive -Name 'absolute-manifest' -Members @(@{ Name = '/manifest.json'; Content = $script:twoEntryManifest })

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'NotFound'
            $info.Members | Should -Be @('/manifest.json')
        }

        It 'keeps backslashes in member names and matches them to the same manifest paths' {
            $manifest = '[{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["folder\\layer.tar"]},{"Config":"b.json","RepoTags":["example.local/b:1"],"Layers":["folder/layer.tar"]}]'
            $archive = New-RawTestArchive -Name 'backslash-members' -Members @(
                @{ Name = 'manifest.json'; Content = $manifest }
                @{ Name = 'a.json'; Content = '{}' }; @{ Name = 'b.json'; Content = '{}' }
                @{ Name = 'folder\layer.tar'; Content = 'a' }
            )

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            $info.Members | Should -Contain 'folder\layer.tar'
            $info.Members | Should -Not -Contain 'folder\\layer.tar'

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @1 .*archive member\(s\) not found: folder/layer\.tar$' }
        }

        It 'skips the member check instead of skipping a valid entry when a member name is non-ASCII' {
            # tar.exe lists the PAX UTF-8 name in the ANSI code page, so it would not match the manifest path
            $layer = "a/layer-$([char]0x00FC).tar"
            $manifest = '[{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["' + $layer + '"]},{"Config":"b.json","RepoTags":["example.local/b:1"],"Layers":["b/layer.tar"]}]'
            $archive = New-RawTestArchive -Name 'non-ascii-member' -Members @(
                @{ Name = 'manifest.json'; Content = $manifest }
                @{ Name = 'a.json'; Content = '{}' }; @{ Name = $layer; Content = 'a'; Pax = $true }
                @{ Name = 'b.json'; Content = '{}' }; @{ Name = 'b/layer.tar'; Content = 'b' }
            )

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            @($info.Entries)[0].Layers | Should -Be @($layer)
            @($info.Members).Count | Should -Be 0

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            # once for the direct Get-DockerArchiveManifestInfo call above, once inside the import
            Should -Invoke -ModuleName $moduleName Write-Log -Times 2 -Exactly -ParameterFilter { "$Messages" -match 'non-ASCII characters; archive members are not checked' }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry' }
        }

        It 'reports Unavailable when tar.exe cannot list a member name outside the ANSI code page' {
            $archive = New-RawTestArchive -Name 'emoji-member' -Members @(
                @{ Name = 'manifest.json'; Content = $script:twoEntryManifest }
                @{ Name = "a/layer-$([char]0xD83D)$([char]0xDE00).tar"; Content = 'a'; Pax = $true }
            )

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Unavailable'
        }

        It 'skips an entry whose layer path leaves the archive root instead of matching it to another member' {
            $manifest = '[{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["../a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/b:1"],"Layers":["b/layer.tar"]}]'
            $files = $script:twoEntryFiles.Clone()
            $files['manifest.json'] = $manifest
            $archive = New-TestArchive -Name 'escaping-layer' -Files $files

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @0 .*path\(s\) outside the archive: \.\./a/layer\.tar$' }
        }

        It 'reports NotFound for an OCI-only archive without manifest.json' {
            $archive = New-TestArchive -Name 'oci-only' -Files @{
                'index.json' = '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:0","size":1}]}'
                'oci-layout' = '{"imageLayoutVersion":"1.0.0"}'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'NotFound'
            $info.Members | Should -Contain 'index.json'
        }

        It 'does not treat a nested manifest.json as the archive manifest' {
            $archive = New-TestArchive -Name 'nested-manifest' -Files @{ 'sub/manifest.json' = $script:twoEntryManifest }

            (Get-ManifestInfoInModule -Path $archive).State | Should -Be 'NotFound'
        }

        It 'reports Unavailable for a missing archive path' {
            $info = Get-ManifestInfoInModule -Path (Join-Path $TestDrive 'does-not-exist.tar')

            $info.State | Should -Be 'Unavailable'
            $info.Reason | Should -Be 'the archive file does not exist'
            @($info.Entries).Count | Should -Be 0
        }

        It 'reports Unavailable for a file that is not a tar archive and keeps the legacy import' {
            $notAnArchive = Join-Path $TestDrive 'not-an-archive.tar'
            Set-Content -LiteralPath $notAnArchive -Value 'this is not a tar archive' -Encoding Ascii

            $info = Get-ManifestInfoInModule -Path $notAnArchive

            $info.State | Should -Be 'Unavailable'
            $info.Reason | Should -Match '^tar\.exe could not list the archive \(exit code \d+\)$'
            @($info.Entries).Count | Should -Be 0

            $result = Invoke-LinuxNodeImageImport -ImagePath $notAnArchive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
        }

        It 'imports a generated two-entry archive entry by entry without mocking manifest detection' {
            $archive = New-TestArchive -Name 'end-to-end' -Files $script:twoEntryFiles

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Assert-SingleRemoteArchivePath
        }

        It 'imports the valid entry and skips an entry whose layer is missing from a generated archive' {
            $files = $script:twoEntryFiles.Clone()
            $files.Remove('b/layer.tar')
            $archive = New-TestArchive -Name 'missing-layer' -Files $files

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                "$Messages" -match 'Skipping archive entry @1 \(example\.local/b:1, example\.local/b:latest\) .*archive member\(s\) not found: b/layer\.tar$'
            }
        }

        It 'skips an entry whose config is missing from a generated archive' {
            $files = $script:twoEntryFiles.Clone()
            $files.Remove('a.json')
            $archive = New-TestArchive -Name 'missing-config' -Files $files

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @0 .*archive member\(s\) not found: a\.json$' }
        }

        It 'imports a Docker-style blobs/sha256 archive with index.json and gzip layers entry by entry in manifest order' {
            # Synthetic fixture modelled on the 'docker save' layout (Docker 25+, containerd image store); not produced by Docker.
            # Only manifest.json detection and @<index> selection are under test; Buildah's layer decompression is not.
            $sourceDir = Join-Path $TestDrive 'docker-style-src'
            $blobDir = Join-Path $sourceDir 'blobs\sha256'
            New-Item -ItemType Directory -Path $blobDir -Force | Out-Null
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $getHex = { param([byte[]]$Bytes) -join ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
            $addBlob = { param([byte[]]$Bytes) $hex = & $getHex $Bytes; [IO.File]::WriteAllBytes((Join-Path $blobDir $hex), $Bytes); "blobs/sha256/$hex" }
            $newGzipLayer = {
                param([string]$Name)
                $layerSrc = Join-Path $TestDrive "layer-$Name"
                New-Item -ItemType Directory -Path $layerSrc -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $layerSrc "$Name.txt") -Value $Name -Encoding Ascii -NoNewline
                (Get-Item -LiteralPath (Join-Path $layerSrc "$Name.txt")).LastWriteTimeUtc = [datetime]'2020-01-01Z'
                $layerTar = Join-Path $TestDrive "layer-$Name.tar"
                & $script:tarExe -cf $layerTar -C $layerSrc "$Name.txt"
                if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create layer '$Name'" }
                $tarBytes = [IO.File]::ReadAllBytes($layerTar)
                $buffer = New-Object IO.MemoryStream
                $gzip = New-Object IO.Compression.GZipStream($buffer, [IO.Compression.CompressionMode]::Compress)
                $gzip.Write($tarBytes, 0, $tarBytes.Length)
                $gzip.Dispose()
                [PSCustomObject]@{ DiffId = 'sha256:' + (& $getHex $tarBytes); Path = (& $addBlob $buffer.ToArray()) }
            }

            $base = & $newGzipLayer 'base'
            $images = foreach ($name in 'a', 'b') {
                $app = & $newGzipLayer "app-$name"
                $config = @{ architecture = 'amd64'; os = 'linux'; rootfs = @{ type = 'layers'; diff_ids = @($base.DiffId, $app.DiffId) } } | ConvertTo-Json -Compress
                [PSCustomObject]@{ Tag = "k2s.local/issue3212-docker/${name}:1"; Config = (& $addBlob ([Text.Encoding]::UTF8.GetBytes($config))); Layers = @($base.Path, $app.Path) }
            }
            # Docker does not guarantee manifest.json order, so b precedes a here while index.json lists a first.
            # index.json uses a placeholder digest and has no OCI manifest blobs: it is not a complete OCI image layout.
            $manifestJson = ConvertTo-Json -Compress -Depth 4 @($images[1], $images[0] | ForEach-Object { [ordered]@{ Config = $_.Config; RepoTags = @($_.Tag); Layers = $_.Layers } })
            $indexJson = @{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @($images | ForEach-Object {
                        @{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; digest = 'sha256:0'; size = 0; annotations = @{ 'io.containerd.image.name' = $_.Tag } } }) } | ConvertTo-Json -Compress -Depth 5
            Set-Content -LiteralPath (Join-Path $sourceDir 'manifest.json') -Value $manifestJson -Encoding Ascii -NoNewline
            Set-Content -LiteralPath (Join-Path $sourceDir 'index.json') -Value $indexJson -Encoding Ascii -NoNewline
            Set-Content -LiteralPath (Join-Path $sourceDir 'oci-layout') -Value '{"imageLayoutVersion":"1.0.0"}' -Encoding Ascii -NoNewline
            $archive = Join-Path $TestDrive 'docker-style.tar'
            & $script:tarExe -cf $archive -C $sourceDir 'blobs' 'index.json' 'manifest.json' 'oci-layout'
            if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create test archive '$archive'" }

            # Fixture consistency: every manifest path is an archive member and the shared base layer is a gzip blob stored once
            $members = @(& $script:tarExe -tf $archive)
            foreach ($image in $images) { @($image.Config) + $image.Layers | ForEach-Object { $members | Should -Contain $_ } }
            @($members | Where-Object { $_ -eq $base.Path }).Count | Should -Be 1
            ([IO.File]::ReadAllBytes((Join-Path $sourceDir $base.Path)))[0..1] | Should -Be @(0x1f, 0x8b)

            $info = Get-ManifestInfoInModule -Path $archive
            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            $expectedTags = @(@($info.Entries) | ForEach-Object { @($_.RepoTags)[0] })
            $expectedTags | Should -Be @('k2s.local/issue3212-docker/b:1', 'k2s.local/issue3212-docker/a:1')

            # No -DockerArchive: index.json and oci-layout must not route a multi-entry archive to oci-archive
            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            # Each selector index is paired with the tag and config of the manifest.json entry at that index, not with index.json order
            $expectedConfigs = @($images[1].Config, $images[0].Config)
            for ($i = 0; $i -lt 2; $i++) {
                $expectedMessage = "[Import] Importing archive entry @$i ($($expectedTags[$i]), config '$($expectedConfigs[$i])') on 'control-plane'"
                Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -contains $expectedMessage }
            }
        }
    }

    Context 'Docker archive tag report' {
        It 'normalizes <Reference> to the containerd name <Expected>' -ForEach @(
            # Expected values observed with 'ctr images import' (containerd 2.4.1) of a Docker archive using these RepoTags
            @{ Reference = 'pause-win3212:short'; Expected = 'docker.io/library/pause-win3212:short' }
            @{ Reference = 'k2s/test3212:1'; Expected = 'docker.io/k2s/test3212:1' }
            @{ Reference = 'docker.io/busybox3212'; Expected = 'docker.io/library/busybox3212:latest' }
            @{ Reference = 'index.docker.io/library/x3212:2'; Expected = 'docker.io/library/x3212:2' }
            @{ Reference = 'localhost:5000/y3212'; Expected = 'localhost:5000/y3212:latest' }
            @{ Reference = 'shsk2s.azurecr.io/pause-win:v1.8.0'; Expected = 'shsk2s.azurecr.io/pause-win:v1.8.0' }
            @{ Reference = 'localhost/app'; Expected = 'localhost/app:latest' }
            @{ Reference = 'example.local/app@sha256:0123'; Expected = 'example.local/app@sha256:0123' }
        ) {
            InModuleScope $moduleName -Parameters @{ Reference = $Reference } {
                param($Reference)
                ConvertTo-ContainerdImageName -Reference $Reference
            } | Should -BeExactly $Expected
        }

        It 'reports expected names, untagged entries, and tags shared by several entries' {
            $entries = @(
                [PSCustomObject]@{ Config = 'a.json'; RepoTags = @('app:1', 'docker.io/library/app:latest'); Layers = @('a.tar') }
                [PSCustomObject]@{ Config = 'b.json'; RepoTags = $null; Layers = @('b.tar') }
                [PSCustomObject]@{ Config = 'c.json'; RepoTags = @('example.local/c:1', 'app:1'); Layers = @('c.tar') }
                [PSCustomObject]@{ Config = 'd.json'; Layers = @('d.tar') }
            )

            $report = InModuleScope $moduleName -Parameters @{ Entries = $entries } {
                param($Entries)
                Get-DockerArchiveTagReport -Entries $Entries
            }

            @($report.ExpectedNames) | Should -Be @('docker.io/library/app:1', 'docker.io/library/app:latest', 'example.local/c:1')
            @($report.UntaggedEntries) | Should -Be @(1, 3)
            @($report.DuplicateTags).Count | Should -Be 1
            @($report.DuplicateTags)[0].Name | Should -BeExactly 'docker.io/library/app:1'
            @(@($report.DuplicateTags)[0].Entries) | Should -Be @(0, 2)
        }

        It 'treats tags that differ only in case as different names' {
            $entries = @(
                [PSCustomObject]@{ Config = 'a.json'; RepoTags = @('example.local/app:V1'); Layers = @('a.tar') }
                [PSCustomObject]@{ Config = 'b.json'; RepoTags = @('example.local/app:v1'); Layers = @('b.tar') }
            )

            $report = InModuleScope $moduleName -Parameters @{ Entries = $entries } {
                param($Entries)
                Get-DockerArchiveTagReport -Entries $Entries
            }

            @($report.ExpectedNames).Count | Should -Be 2
            @($report.DuplicateTags).Count | Should -Be 0
        }

        It 'warns that a tag shared by two entries of a Linux import refers to the last entry and still imports both entries' {
            Mock -ModuleName $moduleName Write-Log {}
            Initialize-RemoteCommandMocks
            $archive = New-TestArchive -Name 'linux-dup-tags' -Files @{
                'manifest.json' = '[{"Config":"a.json","RepoTags":["example.local/dup:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/dup:1"],"Layers":["b/layer.tar"]}]'
                'a.json' = '{}'; 'a/layer.tar' = 'a'; 'b.json' = '{}'; 'b/layer.tar' = 'b'
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                "$Messages" -match "tag 'example\.local/dup:1' is used by archive entries @0, @1 .*it will refer to entry @1$"
            }
        }
    }

    Context 'Windows image import on the local host (containerd)' {
        BeforeAll {
            # Two images in the classic 'docker save' layout sharing 'a/layer.tar'; the contents are placeholders because ctr is mocked
            $script:winManifest = '[{"Config":"a.json","RepoTags":["pause-win:a"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/win/b:1","example.local/win/b:latest"],"Layers":["a/layer.tar","b/layer.tar"]}]'
            $script:winFiles = @{ 'manifest.json' = $script:winManifest; 'a.json' = '{}'; 'a/layer.tar' = 'a'; 'b.json' = '{}'; 'b/layer.tar' = 'b' }
            # The names containerd stores for these RepoTags
            $script:winNames = @('docker.io/library/pause-win:a', 'example.local/win/b:1', 'example.local/win/b:latest')
        }

        BeforeEach {
            $script:ctrCalls = [System.Collections.Generic.List[string]]::new()
            $script:ctrImportSucceeds = $true
            $script:storeNames = @()
            $script:listSucceeds = $true
            $script:logMessages = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Write-Log { $script:logMessages.Add("$Messages") }
            # 'ctr images import' imports every tagged entry of the archive in one call; the store content after the call is set per test
            Mock -ModuleName $moduleName Invoke-Ctr { $script:ctrCalls.Add($Arguments -join ' '); $script:ctrImportSucceeds }
            Mock -ModuleName $moduleName Get-LocalWindowsImageNames { [pscustomobject]@{ Success = $script:listSucceeds; Names = @($script:storeNames) } }
        }

        It 'imports a two-image Docker archive with one ctr import and verifies every tag of every entry' {
            $archive = New-TestArchive -Name 'win-multi' -Files $script:winFiles
            $script:storeNames = $script:winNames + 'shsk2s.azurecr.io/pause-win:v1.8.0'

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeTrue
            @($script:ctrCalls) | Should -Be @("-n k8s.io images import $archive")
            Should -Invoke -ModuleName $moduleName Get-LocalWindowsImageNames -Times 1 -Exactly
            ($script:logMessages -join "`n") | Should -Match 'contains 2 images; containerd imports all of them in one operation'
            ($script:logMessages -join "`n") | Should -Match 'Verified 3 image name\(s\) of 2 archive entries'
            ($script:logMessages -join "`n") | Should -Not -Match 'not verified'
        }

        It 'checks every expected name of every entry and names each missing image' {
            $archive = New-TestArchive -Name 'win-second-entry-missing' -Files $script:winFiles
            $script:storeNames = @('docker.io/library/pause-win:a')

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            @($script:logMessages | Where-Object { $_ -match "Image '(.+)' from .* was not found" } | ForEach-Object { $Matches[1] }) |
                Should -Be @('example.local/win/b:1', 'example.local/win/b:latest')
            ($script:logMessages -join "`n") | Should -Not -Match 'Verified \d+ image name'
        }

        It 'fails when ctr succeeds but skips an untagged entry' {
            $files = $script:winFiles.Clone()
            $files['manifest.json'] = '[{"Config":"a.json","RepoTags":["pause-win:a"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":null,"Layers":["b/layer.tar"]}]'
            $archive = New-TestArchive -Name 'win-untagged' -Files $files
            $script:storeNames = @('docker.io/library/pause-win:a')

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match 'Archive entry @1 of .* has no RepoTags; containerd does not import untagged Docker archive entries on the local Windows host, and its import cannot be verified by name'
            ($script:logMessages -join "`n") | Should -Match 'was not completely imported or could not be verified on the local Windows host'
            ($script:logMessages -join "`n") | Should -Not -Match 'Verified \d+ image name'
        }

        It 'fails and names the missing image when a tag is absent after the import' {
            $archive = New-TestArchive -Name 'win-missing-tag' -Files $script:winFiles
            $script:storeNames = @('docker.io/library/pause-win:a', 'example.local/win/b:1')

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            @($script:logMessages | Where-Object { $_ -match "Image '(.+)' from .* was not found" } | ForEach-Object { $Matches[1] }) | Should -Be @('example.local/win/b:latest')
        }

        It 'returns false and does not verify names when ctr rejects the archive' {
            $archive = New-TestArchive -Name 'win-ctr-fails' -Files $script:winFiles
            $script:ctrImportSucceeds = $false

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Get-LocalWindowsImageNames -Times 0 -Exactly
            ($script:logMessages -join "`n") | Should -Match 'Image import of .* failed on the local Windows host'
        }

        It 'imports a single-image Docker archive and verifies its tag' {
            $archive = New-TestArchive -Name 'win-single' -Files @{ 'manifest.json' = '[{"Config":"a.json","RepoTags":["pause-win:a"],"Layers":["a/layer.tar"]}]'; 'a.json' = '{}'; 'a/layer.tar' = 'a' }
            $script:storeNames = @('docker.io/library/pause-win:a')

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeTrue
            @($script:ctrCalls) | Should -Be @("-n k8s.io images import $archive")
            ($script:logMessages -join "`n") | Should -Not -Match 'contains \d+ images'
        }

        It 'imports an OCI-only archive with ctr once, keeps the ctr result and logs that names are not verified' {
            $archive = New-TestArchive -Name 'win-oci' -Files @{ 'index.json' = '{"schemaVersion":2,"manifests":[]}'; 'oci-layout' = '{"imageLayoutVersion":"1.0.0"}' }

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeTrue
            @($script:ctrCalls) | Should -Be @("-n k8s.io images import $archive")
            Should -Invoke -ModuleName $moduleName Get-LocalWindowsImageNames -Times 0 -Exactly
            ($script:logMessages -join "`n") | Should -Match 'has no Docker manifest\.json \(for example an OCI archive\); the imported image names are not verified'
            ($script:logMessages -join "`n") | Should -Match 'imported successfully on the local Windows host \(image names not verified\)'
        }

        It 'returns false for an OCI-only archive when ctr rejects it' {
            $archive = New-TestArchive -Name 'win-oci-fails' -Files @{ 'index.json' = '{"schemaVersion":2,"manifests":[]}'; 'oci-layout' = '{"imageLayoutVersion":"1.0.0"}' }
            $script:ctrImportSucceeds = $false

            Invoke-LocalWindowsImageImport -ImagePath $archive | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Not -Match 'imported successfully'
        }

        It 'keeps the ctr result and warns on the console when the archive cannot be inspected' {
            $archive = Join-Path $TestDrive 'win-not-a-tar.tar'
            Set-Content -LiteralPath $archive -Value 'not an archive'

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeTrue
            @($script:ctrCalls) | Should -Be @("-n k8s.io images import $archive")
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Console -and "$Messages" -match 'could not be inspected \(tar\.exe could not list the archive \(exit code \d+\)\); the imported image names are not verified'
            }
        }

        It 'rejects an archive with <Label> without running ctr' -ForEach @(
            @{ Label = 'a malformed manifest.json'; Content = '[{"Config": '; Reason = 'manifest.json is not valid JSON' }
            @{ Label = 'an empty manifest.json array'; Content = '[]'; Reason = 'manifest.json is empty or not a list of image entries' }
        ) {
            # index.json makes the archive importable by ctr, which could then report success for an unverifiable import
            $archive = New-TestArchive -Name "win-invalid-$($Label -replace '\W', '-')" -Files @{ 'manifest.json' = $Content; 'index.json' = '{"schemaVersion":2,"manifests":[]}'; 'oci-layout' = '{"imageLayoutVersion":"1.0.0"}' }

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            $script:ctrCalls.Count | Should -Be 0
            Should -Invoke -ModuleName $moduleName Get-LocalWindowsImageNames -Times 0 -Exactly
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -eq "[Import] Image archive '$archive' is not imported on the local Windows host: $Reason"
            }
        }

        It 'rejects an archive whose manifest.json cannot be read without running ctr' {
            Mock -ModuleName $moduleName Get-DockerArchiveManifestInfo { [pscustomobject]@{ State = 'Unreadable'; Reason = "tar.exe could not read 'manifest.json' (exit code 1)"; Entries = @(); Members = @('manifest.json') } }

            $result = Invoke-LocalWindowsImageImport -ImagePath 'C:\images\unreadable.tar'

            $result | Should -BeFalse
            $script:ctrCalls.Count | Should -Be 0
            ($script:logMessages -join "`n") | Should -Match "is not imported on the local Windows host: tar\.exe could not read 'manifest\.json'"
        }

        It 'fails without importing again when the image list cannot be read after a successful ctr import' {
            $archive = New-TestArchive -Name 'win-list-fails' -Files $script:winFiles
            $script:listSucceeds = $false

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeFalse
            @($script:ctrCalls) | Should -Be @("-n k8s.io images import $archive")
            ($script:logMessages -join "`n") | Should -Match 'ctr imported .* on the local Windows host, but the image list could not be read; the 3 expected image name\(s\) are not verified'
            ($script:logMessages -join "`n") | Should -Not -Match 'Verified \d+ image name|imported successfully'
        }

        It 'warns that a tag shared by two entries refers to the last entry' {
            $files = $script:winFiles.Clone()
            $files['manifest.json'] = '[{"Config":"a.json","RepoTags":["example.local/win/dup:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/win/dup:1"],"Layers":["b/layer.tar"]}]'
            $archive = New-TestArchive -Name 'win-dup' -Files $files
            $script:storeNames = @('example.local/win/dup:1')

            $result = Invoke-LocalWindowsImageImport -ImagePath $archive

            $result | Should -BeTrue
            ($script:logMessages -join "`n") | Should -Match "tag 'example\.local/win/dup:1' is used by archive entries @0, @1 .*it will refer to entry @1"
            ($script:logMessages -join "`n") | Should -Match 'Verified 1 image name\(s\) of 2 archive entries .*; 1 of these name\(s\) are used by several entries and refer only to the last of them'
        }
    }

    Context 'Windows image import on a Windows worker VM (containerd)' {
        BeforeAll {
            $script:winWorkerFiles = @{
                'manifest.json' = '[{"Config":"a.json","RepoTags":["example.local/win/a:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/win/b:1"],"Layers":["b/layer.tar"]}]'
                'a.json' = '{}'; 'a/layer.tar' = 'a'; 'b.json' = '{}'; 'b/layer.tar' = 'b'
            }
            $script:winRemotePattern = '^C:\\Windows\\Temp\\k2s-image-import-[0-9a-f]{32}\.tar$'
        }

        BeforeEach {
            $script:copyDestinations = [System.Collections.Generic.List[string]]::new()
            $script:remoteCalls = [System.Collections.Generic.List[object]]::new()
            $script:remoteImport = [PSCustomObject]@{ Success = $true; Output = ''; ImageNames = @('example.local/win/a:1', 'example.local/win/b:1') }
            $script:cleanupRemoved = $true
            $script:copyThrows = $false
            $script:logMessages = [System.Collections.Generic.List[string]]::new()
            $script:session = New-MockObject -Type System.Management.Automation.Runspaces.PSSession

            Mock -ModuleName $moduleName Write-Log { $script:logMessages.Add("$Messages") }
            Mock -ModuleName $moduleName Get-DefaultTempPwd { 'not-a-secret' }
            Mock -ModuleName $moduleName Open-RemoteSession { $script:session }
            Mock -ModuleName $moduleName Remove-PSSession {}
            Mock -ModuleName $moduleName Copy-Item {
                if ($script:copyThrows) { throw 'copy failed' }
                $script:copyDestinations.Add([string]$Destination)
            }
            # Distinguishes the remote import script block (ctr import plus image list) from the cleanup script block
            Mock -ModuleName $moduleName Invoke-Command {
                $isImport = $ScriptBlock.ToString() -match 'images import'
                $script:remoteCalls.Add([PSCustomObject]@{ Kind = $(if ($isImport) { 'import' } else { 'cleanup' }); Path = [string]$ArgumentList[0] })
                if ($isImport) { return $script:remoteImport }
                return $script:cleanupRemoved
            }
        }

        It 'imports through a unique temporary file per import and removes exactly that file' {
            $archive = New-TestArchive -Name 'worker-multi' -Files $script:winWorkerFiles

            $first = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'
            $second = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $first | Should -BeTrue
            $second | Should -BeTrue
            $script:copyDestinations.Count | Should -Be 2
            $script:copyDestinations | ForEach-Object { $_ | Should -Match $script:winRemotePattern }
            $script:copyDestinations[0] | Should -Not -Be $script:copyDestinations[1]
            @($script:remoteCalls | ForEach-Object { "$($_.Kind):$($_.Path)" }) | Should -Be @(
                "import:$($script:copyDestinations[0])", "cleanup:$($script:copyDestinations[0])",
                "import:$($script:copyDestinations[1])", "cleanup:$($script:copyDestinations[1])")
            Should -Invoke -ModuleName $moduleName Remove-PSSession -Times 2 -Exactly
        }

        It 'fails when the worker reports success but an expected image is missing, and still removes the file' {
            $archive = New-TestArchive -Name 'worker-missing' -Files $script:winWorkerFiles
            $script:remoteImport = [PSCustomObject]@{ Success = $true; Output = ''; ImageNames = @('example.local/win/a:1') }

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match "Image 'example\.local/win/b:1' from .* was not found on Windows worker 'winvm'"
            @($script:remoteCalls.Kind) | Should -Be @('import', 'cleanup')
        }

        It 'fails when ctr fails on the worker and still removes the file' {
            $archive = New-TestArchive -Name 'worker-ctr-fails' -Files $script:winWorkerFiles
            $script:remoteImport = [PSCustomObject]@{ Success = $false; Output = 'ctr: failed to resolve layers'; ImageNames = $null }

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match 'ctr: failed to resolve layers'
            @($script:remoteCalls.Kind) | Should -Be @('import', 'cleanup')
        }

        It 'fails when the temporary file cannot be removed from the worker' {
            $archive = New-TestArchive -Name 'worker-cleanup' -Files $script:winWorkerFiles
            $script:cleanupRemoved = $false

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match 'Could not remove temporary image archive .*k2s-image-import-[0-9a-f]{32}\.tar'
        }

        It 'does not import when the copy fails and still attempts to remove the file' {
            $archive = New-TestArchive -Name 'worker-copy' -Files $script:winWorkerFiles
            $script:copyThrows = $true

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            @($script:remoteCalls.Kind) | Should -Be @('cleanup')
            $script:remoteCalls[0].Path | Should -Match $script:winRemotePattern
        }

        It 'fails when the worker cannot list its images after ctr succeeded, and still removes the file' {
            $archive = New-TestArchive -Name 'worker-no-list' -Files $script:winWorkerFiles
            $script:remoteImport = [PSCustomObject]@{ Success = $true; Output = ''; ImageNames = $null }

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match "ctr imported .* on Windows worker 'winvm', but the image list could not be read; the 2 expected image name\(s\) are not verified"
            @($script:remoteCalls.Kind) | Should -Be @('import', 'cleanup')
        }

        It 'fails for an untagged entry on the worker and still removes the file' {
            $files = $script:winWorkerFiles.Clone()
            $files['manifest.json'] = '[{"Config":"a.json","RepoTags":["example.local/win/a:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","Layers":["b/layer.tar"]}]'
            $archive = New-TestArchive -Name 'worker-untagged' -Files $files
            $script:remoteImport = [PSCustomObject]@{ Success = $true; Output = ''; ImageNames = @('example.local/win/a:1') }

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            ($script:logMessages -join "`n") | Should -Match "Archive entry @1 of .* has no RepoTags; containerd does not import untagged Docker archive entries on Windows worker 'winvm'"
            @($script:remoteCalls.Kind) | Should -Be @('import', 'cleanup')
        }

        It 'keeps the worker ctr result for an OCI-only archive without listing verification' {
            $archive = New-TestArchive -Name 'worker-oci' -Files @{ 'index.json' = '{"schemaVersion":2,"manifests":[]}'; 'oci-layout' = '{"imageLayoutVersion":"1.0.0"}' }
            $script:remoteImport = [PSCustomObject]@{ Success = $true; Output = ''; ImageNames = $null }

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeTrue
            ($script:logMessages -join "`n") | Should -Match 'has no Docker manifest\.json .*the imported image names are not verified'
            @($script:remoteCalls.Kind) | Should -Be @('import', 'cleanup')
        }

        It 'rejects an archive with two manifest.json members before opening a session, copying, or running ctr' {
            $archive = New-RawTestArchive -Name 'worker-dup-manifest' -Members @(
                @{ Name = 'manifest.json'; Content = $script:winWorkerFiles['manifest.json'] }
                @{ Name = './manifest.json'; Content = '[]' }
            )

            $result = Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm'

            $result | Should -BeFalse
            Should -Invoke -ModuleName $moduleName Open-RemoteSession -Times 0 -Exactly
            $script:copyDestinations.Count | Should -Be 0
            $script:remoteCalls.Count | Should -Be 0
            ($script:logMessages -join "`n") | Should -Match "is not imported on Windows worker 'winvm': the archive contains 2 manifest\.json members"
        }

        It 'rejects an archive with a malformed manifest.json on the worker' {
            $archive = New-TestArchive -Name 'worker-invalid' -Files @{ 'manifest.json' = '{"Config":"a.json"}' }

            Invoke-WindowsWorkerImageImport -ImagePath $archive -NodeName 'winvm' | Should -BeFalse
            $script:remoteCalls.Count | Should -Be 0
            ($script:logMessages -join "`n") | Should -Match 'manifest\.json is empty or not a list of image entries'
        }
    }
}

Describe 'Import-Image.ps1' -Tag 'unit', 'ci', 'image' {
    BeforeAll {
        # Run the script as a dynamic scriptblock with '#Requires' and module imports removed; the module functions it calls are mocked below
        $scriptContent = (Get-Content -Path "$PSScriptRoot\Import-Image.ps1" | Where-Object {
                $_ -notmatch '^#Requires\b' -and $_ -notmatch '^\s*Import-Module\b'
            }) -join [Environment]::NewLine

        function Invoke-ImportImageScript {
            param([hashtable]$Parameters)
            & ([scriptblock]::Create($scriptContent)) @Parameters
        }

        # The real New-Error needs the [Severity] enum of the infra module, which is not loaded here
        function New-Error {
            param($Severity, $Code, $Message)
            $script:newErrorCodes.Add($Code)
            [PSCustomObject]@{ Code = $Code; Message = $Message }
        }
    }

    BeforeEach {
        $script:importCalls = [System.Collections.Generic.List[object]]::new()
        $script:failingImages = @()
        $script:cliMessages = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Import-Module {}
        Mock -CommandName Write-Log {}
        Mock -CommandName Initialize-ImageScriptContext { $true }
        Mock -CommandName Resolve-NodeList { @() }
        $script:newErrorCodes = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Send-ToCli { $script:cliMessages.Add($Message) }
        Mock -CommandName Invoke-LinuxNodeImageImport {
            $script:importCalls.Add([PSCustomObject]@{ ImagePath = $ImagePath; Kind = $NodeInfo.Kind; DockerArchive = [bool]$DockerArchive })
            $script:failingImages -notcontains $ImagePath
        }
        Mock -CommandName Invoke-LocalWindowsImageImport {
            $script:importCalls.Add([PSCustomObject]@{ ImagePath = $ImagePath; Kind = 'LocalWindows'; DockerArchive = $null })
            $script:failingImages -notcontains $ImagePath
        }
        Mock -CommandName Invoke-WindowsWorkerImageImport {
            $script:importCalls.Add([PSCustomObject]@{ ImagePath = $ImagePath; Kind = "WindowsWorker:$NodeName"; DockerArchive = $null })
            $script:failingImages -notcontains $ImagePath
        }
        Mock -CommandName Test-NodeReady { $true }
        Mock -CommandName Resolve-ImageNode {
            switch ($NodeName) {
                'kubemaster' { @{ Name = 'kubemaster'; OS = 'linux'; Kind = 'ControlPlane' } }
                'linuxvm' { @{ Name = 'linuxvm'; OS = 'linux'; Kind = 'LinuxWorker'; IpAddress = '192.0.2.10'; Username = 'remote' } }
                'winhost' { @{ Name = 'winhost'; OS = 'windows'; Kind = 'LocalWindows' } }
                'winvm' { @{ Name = 'winvm'; OS = 'windows'; Kind = 'WindowsWorker' } }
                default { $null }
            }
        }
    }

    It 'imports a Windows archive with -Windows through the verifying local helper exactly once and never calls ctr directly' -ForEach @(
        @{ Label = 'default routing'; Nodes = ''; NodeList = @() }
        @{ Label = 'the local Windows host selected by name'; Nodes = 'winhost'; NodeList = @('winhost') }
    ) {
        Mock -CommandName Resolve-NodeList { $NodeList }.GetNewClosure()
        Mock -CommandName Invoke-Ctr { $true }
        $parameters = @{ ImagePath = 'C:\images\win-multi.tar'; Windows = $true; ReturnStatus = $true }
        if ($Nodes) { $parameters.Nodes = $Nodes }

        $result = Invoke-ImportImageScript -Parameters $parameters

        $result | Should -BeTrue
        @($script:importCalls | ForEach-Object { "$($_.Kind):$($_.ImagePath)" }) | Should -Be @('LocalWindows:C:\images\win-multi.tar')
        Should -Invoke -CommandName Invoke-Ctr -Times 0 -Exactly
    }

    It 'returns failure and reports image-import-failed when the verifying local Windows import fails' {
        $script:failingImages = @('C:\images\win-untagged.tar')

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\win-untagged.tar'; Windows = $true; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls.Kind) | Should -Be @('LocalWindows')
        @($script:newErrorCodes) | Should -Be @('image-import-failed')
    }

    It 'routes every archive of a directory to the local Windows import with -Windows and fails overall when one fails' {
        $imageDir = Join-Path $TestDrive 'windows-images'
        New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        'multi.tar', 'single.tar' | ForEach-Object { Set-Content -LiteralPath (Join-Path $imageDir $_) -Value 'x' }
        $script:failingImages = @((Join-Path $imageDir 'single.tar'))

        $result = Invoke-ImportImageScript -Parameters @{ ImageDir = $imageDir; Windows = $true; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls | ForEach-Object { "$($_.Kind):$(Split-Path $_.ImagePath -Leaf)" } | Sort-Object) | Should -Be @('LocalWindows:multi.tar', 'LocalWindows:single.tar')
    }

    It 'routes each selected node to the import of its kind and forwards -DockerArchive only to Linux nodes' {
        Mock -CommandName Resolve-NodeList { @('kubemaster', 'linuxvm', 'winhost', 'winvm') }

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; Nodes = 'kubemaster,linuxvm,winhost,winvm'; DockerArchive = $true; ReturnStatus = $true }

        $result | Should -BeTrue
        @($script:importCalls | ForEach-Object { "$($_.Kind)|$($_.DockerArchive)" }) | Should -Be @('ControlPlane|True', 'LinuxWorker|True', 'LocalWindows|', 'WindowsWorker:winvm|')
    }

    It 'keeps the existing node routing when -Windows is combined with a Linux node' {
        Mock -CommandName Resolve-NodeList { @('kubemaster') }

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; Nodes = 'kubemaster'; Windows = $true; ReturnStatus = $true }

        $result | Should -BeTrue
        @($script:importCalls.Kind) | Should -Be @('ControlPlane')
    }

    It 'fails for a node that cannot be resolved and still imports on the other nodes' {
        Mock -CommandName Resolve-NodeList { @('unknown', 'winvm') }

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; Nodes = 'unknown,winvm'; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls.Kind) | Should -Be @('WindowsWorker:winvm')
    }

    It 'imports every archive of a directory on each selected node and fails overall when a Windows worker import fails' {
        $imageDir = Join-Path $TestDrive 'worker-images'
        New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        'a-multi.tar', 'b-single.tar' | ForEach-Object { Set-Content -LiteralPath (Join-Path $imageDir $_) -Value 'x' }
        Mock -CommandName Resolve-NodeList { @('winvm', 'winhost') }
        Mock -CommandName Invoke-WindowsWorkerImageImport {
            $script:importCalls.Add([PSCustomObject]@{ ImagePath = $ImagePath; Kind = "WindowsWorker:$NodeName"; DockerArchive = $null })
            (Split-Path $ImagePath -Leaf) -ne 'a-multi.tar'
        }

        $result = Invoke-ImportImageScript -Parameters @{ ImageDir = $imageDir; Nodes = 'winvm,winhost'; Windows = $true; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls | ForEach-Object { "$($_.Kind):$(Split-Path $_.ImagePath -Leaf)" } | Sort-Object) |
            Should -Be @('LocalWindows:a-multi.tar', 'LocalWindows:b-single.tar', 'WindowsWorker:winvm:a-multi.tar', 'WindowsWorker:winvm:b-single.tar')
    }

    It 'forwards -DockerArchive:<DockerArchive> to the Linux control-plane import and returns <Expected> in return-status mode' -ForEach @(
        @{ DockerArchive = $true; Failing = $false; Expected = $true }
        @{ DockerArchive = $false; Failing = $false; Expected = $true }
        @{ DockerArchive = $true; Failing = $true; Expected = $false }
    ) {
        if ($Failing) { $script:failingImages = @('C:\images\multi.tar') }

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; DockerArchive = $DockerArchive; ReturnStatus = $true }

        $result | Should -Be $Expected
        $script:importCalls.Count | Should -Be 1
        $script:importCalls[0].ImagePath | Should -BeExactly 'C:\images\multi.tar'
        $script:importCalls[0].Kind | Should -BeExactly 'ControlPlane'
        $script:importCalls[0].DockerArchive | Should -Be $DockerArchive
    }

    It 'sends the image-import-failed error to the CLI when an import fails' {
        $script:failingImages = @('C:\images\multi.tar')

        Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; EncodeStructuredOutput = $true; MessageType = 'import' }

        $script:cliMessages.Count | Should -Be 1
        $script:cliMessages[0].Error.Code | Should -BeExactly 'image-import-failed'
        @($script:newErrorCodes) | Should -Be @('image-import-failed')
    }

    It 'sends no error to the CLI when the import succeeds' {
        Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; EncodeStructuredOutput = $true; MessageType = 'import' }

        $script:cliMessages.Count | Should -Be 1
        $script:cliMessages[0].Error | Should -BeNullOrEmpty
        $script:newErrorCodes.Count | Should -Be 0
    }

    It 'imports every archive of a directory and fails overall when one of them fails' {
        $imageDir = Join-Path $TestDrive 'images'
        New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        'multi.tar', 'single.tar' | ForEach-Object { Set-Content -LiteralPath (Join-Path $imageDir $_) -Value 'x' }
        $script:failingImages = @((Join-Path $imageDir 'multi.tar'))

        $result = Invoke-ImportImageScript -Parameters @{ ImageDir = $imageDir; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls | ForEach-Object { Split-Path $_.ImagePath -Leaf } | Sort-Object) | Should -Be @('multi.tar', 'single.tar')
    }
}
