# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Unit tests for the K2S_SETUP_CONFIG_DIR override of the K2s setup config directory.

.DESCRIPTION
    #2886: during 'k2s system upgrade' the CLI sets K2S_SETUP_CONFIG_DIR to the setup
    config dir of the OLD installation so it can be discovered, analyzed and uninstalled.
    Before the NEW version is installed the override is cleared again and the module
    switches back to the setup config dir of its own package via 'Update-SetupConfigDir'.

    The package's cfg/config.json is never modified.
#>

BeforeAll {
    $script:ModulePath = "$PSScriptRoot\config.module.psm1"
    $script:PackageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..\..\..')).Path

    function Import-ConfigModuleFresh {
        Remove-Module -Name 'config.module' -Force -ErrorAction SilentlyContinue
        Import-Module $script:ModulePath -Force -DisableNameChecking
    }

    function Get-PackageConfigDirK2s {
        return (Get-Content "$script:PackageRoot\cfg\config.json" -Raw | ConvertFrom-Json).configDir.k2s
    }

    function New-SetupConfigFixture {
        param(
            [string] $SetupType = 'k2s',
            [string] $Version = '1.8.1',
            [string] $InstallFolder = 'D:\ws\K2s\1.6.0'
        )

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        New-Item -Path $dir -ItemType Directory -Force | Out-Null

        $setup = [ordered]@{
            SetupType     = $SetupType
            Version       = $Version
            InstallFolder = $InstallFolder
            ClusterName   = 'k2s-cluster'
        }
        $setup | ConvertTo-Json | Set-Content -Path (Join-Path $dir 'setup.json') -Encoding UTF8

        return $dir
    }
}

Describe 'Setup config dir override (K2S_SETUP_CONFIG_DIR)' -Tag 'unit', 'ci' {

    AfterEach {
        Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue
        Import-ConfigModuleFresh
    }

    Context 'override is set (old-system discovery phase)' {
        It 'uses the overridden directory for the setup config file path' {
            $fixtureDir = New-SetupConfigFixture
            $env:K2S_SETUP_CONFIG_DIR = $fixtureDir

            Import-ConfigModuleFresh

            Get-K2sConfigDir | Should -Be $fixtureDir
            Get-SetupConfigFilePath | Should -Be (Join-Path $fixtureDir 'setup.json')
        }

        It 'reads setup type, version and install folder of the OLD installation' {
            $fixtureDir = New-SetupConfigFixture -SetupType 'k2s' -Version '1.8.1' -InstallFolder 'D:\ws\K2s\1.6.0'
            $env:K2S_SETUP_CONFIG_DIR = $fixtureDir

            Import-ConfigModuleFresh

            Get-ConfigSetupType | Should -Be 'k2s'
            Get-ConfigProductVersion | Should -Be '1.8.1'
            Get-ConfigInstallFolder | Should -Be 'D:\ws\K2s\1.6.0'
        }
    }

    Context 'override is not set' {
        It 'falls back to configDir.k2s from the package cfg/config.json' {
            Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue

            Import-ConfigModuleFresh

            $expected = Get-PackageConfigDirK2s

            Get-K2sConfigDir | Should -Be $expected
            Get-SetupConfigFilePath | Should -Be (Join-Path $expected 'setup.json')
        }
    }

    Context 'Update-SetupConfigDir (switch back before the new installation)' {
        It 'switches back to the package config dir after the override was cleared' {
            $fixtureDir = New-SetupConfigFixture
            $env:K2S_SETUP_CONFIG_DIR = $fixtureDir

            Import-ConfigModuleFresh

            # old-system phase
            Get-K2sConfigDir | Should -Be $fixtureDir

            # boundary: upgrade clears the override before installing the new version
            Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue
            $newDir = Update-SetupConfigDir

            $expected = Get-PackageConfigDirK2s

            $newDir | Should -Be $expected
            Get-K2sConfigDir | Should -Be $expected
            Get-SetupConfigFilePath | Should -Be (Join-Path $expected 'setup.json')
        }

        It 'makes setup.json based functions use the package config dir afterwards' {
            $fixtureDir = New-SetupConfigFixture -Version '1.8.1'
            $env:K2S_SETUP_CONFIG_DIR = $fixtureDir

            Import-ConfigModuleFresh

            Get-ConfigProductVersion | Should -Be '1.8.1'

            Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue
            Update-SetupConfigDir | Out-Null

            # the old setup.json must no longer be consulted
            Get-SetupConfigFilePath | Should -Not -Be (Join-Path $fixtureDir 'setup.json')
        }

        It 'is idempotent when no override was set' {
            Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue

            Import-ConfigModuleFresh

            $before = Get-SetupConfigFilePath
            Update-SetupConfigDir | Out-Null

            Get-SetupConfigFilePath | Should -Be $before
        }
    }

    Context 'package configuration is read-only' {
        It 'never modifies cfg/config.json' {
            $configFile = "$script:PackageRoot\cfg\config.json"
            $before = Get-Content $configFile -Raw

            $fixtureDir = New-SetupConfigFixture
            $env:K2S_SETUP_CONFIG_DIR = $fixtureDir
            Import-ConfigModuleFresh
            Get-K2sConfigDir | Out-Null

            Remove-Item Env:\K2S_SETUP_CONFIG_DIR -ErrorAction SilentlyContinue
            Update-SetupConfigDir | Out-Null

            (Get-Content $configFile -Raw) | Should -Be $before
        }
    }
}

