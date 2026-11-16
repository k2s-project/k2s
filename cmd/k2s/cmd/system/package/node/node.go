// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

// Package nodepackage implements the --node-package flag logic for
// 'k2s system package'. It owns all constants, validation and PS command
// construction related to building a Linux node artifact zip.
package nodepackage

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	NodePackageFlagName  = "node-package"
	NodePackageFlagUsage = "Creates a zip package containing Linux node packages (kubelet, kubeadm, kubectl, CRI-O, buildah) for the specified OS and version; requires an existing K2s cluster and --proxy http://172.19.1.1:8181"

	OSFlagName  = "os"
	OSFlagUsage = "Target Linux distribution and version combined (e.g. debian12, debian13)"

	IncludeGpuFlagName  = "include-gpu"
	IncludeGpuFlagUsage = "Include NVIDIA Container Toolkit packages for GPU support. When 'k2s node add' uses a package built with this flag, it automatically detects if the target node has an NVIDIA GPU and configures GPU support (installs container toolkit, configures CRI-O, labels the node)."

	DeltaPackageFlagName       = "delta-package"
	PackageVersionFromFlagName = "package-version-from"
	PackageVersionToFlagName   = "package-version-to"
)

// RegisterFlags registers the node-package specific flags on the given command.
func RegisterFlags(cmd *cobra.Command) {
	cmd.Flags().Bool(NodePackageFlagName, false, NodePackageFlagUsage)
	cmd.Flags().String(OSFlagName, "", OSFlagUsage)
	cmd.Flags().Bool(IncludeGpuFlagName, false, IncludeGpuFlagUsage)
}

// IsSet returns true when the --node-package flag is present and enabled.
func IsSet(flags *pflag.FlagSet) bool {
	v, _ := flags.GetBool(NodePackageFlagName)
	return v
}

// Validate checks that --os is provided and is in the supported list when --node-package is set.
// supportedOS is the list read from cfg/config.json (supportedWorkerOS[].os).
func Validate(flags *pflag.FlagSet, supportedOS []string) error {
	deltaRequested, _ := flags.GetBool(DeltaPackageFlagName)

	if deltaRequested {
		from, _ := flags.GetString(PackageVersionFromFlagName)
		to, _ := flags.GetString(PackageVersionToFlagName)
		if from == "" {
			return fmt.Errorf("--%s is required when --%s and --%s are set", PackageVersionFromFlagName, NodePackageFlagName, DeltaPackageFlagName)
		}
		if to == "" {
			return fmt.Errorf("--%s is required when --%s and --%s are set", PackageVersionToFlagName, NodePackageFlagName, DeltaPackageFlagName)
		}

		os, _ := flags.GetString(OSFlagName)
		if os == "" {
			return nil
		}
		for _, s := range supportedOS {
			if s == os {
				return nil
			}
		}
		return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", OSFlagName, os, strings.Join(supportedOS, ", "))
	}

	os, _ := flags.GetString(OSFlagName)
	if os == "" {
		return fmt.Errorf("--%s is required when --%s is set", OSFlagName, NodePackageFlagName)
	}
	for _, s := range supportedOS {
		if s == os {
			return nil
		}
	}
	return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", OSFlagName, os, strings.Join(supportedOS, ", "))
}

// BuildCmd constructs the PowerShell script path and parameters for node package creation.
// targetDir and zipName are required; an error is returned if either is empty.
func BuildCmd(flags *pflag.FlagSet, out bool, targetDir, zipName, proxy string) (string, []string, error) {
	if targetDir == "" {
		return "", nil, fmt.Errorf("required flag(s) \"target-dir\" not set")
	}
	if zipName == "" {
		return "", nil, fmt.Errorf("required flag(s) \"name\" not set")
	}

	os := flags.Lookup(OSFlagName).Value.String()
	deltaRequested, _ := flags.GetBool(DeltaPackageFlagName)

	params := []string{}
	if out {
		params = append(params, " -ShowLogs")
	}
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(zipName))

	if deltaRequested {
		from := flags.Lookup(PackageVersionFromFlagName).Value.String()
		to := flags.Lookup(PackageVersionToFlagName).Value.String()
		if from == "" {
			return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", PackageVersionFromFlagName)
		}
		if to == "" {
			return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", PackageVersionToFlagName)
		}
		params = append(params, " -InputPackageOne "+utils.EscapeWithSingleQuotes(from))
		params = append(params, " -InputPackageTwo "+utils.EscapeWithSingleQuotes(to))
		if os != "" {
			params = append(params, " -OS "+utils.EscapeWithSingleQuotes(os))
		}

		scriptPath := utils.FormatScriptFilePath(
			filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sNodeDeltaPackage.ps1"),
		)
		return scriptPath, params, nil
	}

	params = append(params, " -OS "+utils.EscapeWithSingleQuotes(os))
	if proxy != "" {
		params = append(params, " -Proxy "+proxy)
	}

	includeGpu, _ := flags.GetBool(IncludeGpuFlagName)
	if includeGpu {
		params = append(params, " -IncludeGpu")
	}

	scriptPath := utils.FormatScriptFilePath(
		filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sNodePackage.ps1"),
	)
	return scriptPath, params, nil
}
