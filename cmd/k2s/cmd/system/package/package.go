// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	nodepackage "github.com/k2s-project/k2s/cmd/k2s/cmd/system/package/node"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/providers/powershell"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var (
	example = `
	# Creates K2s package
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip"

	# Creates K2s package for offline installation and optimized
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --for-offline-installation --profile "Lite"

	# Creates K2s package with only specific addons
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --addons-list "ingress nginx,monitoring,logging"

	# Creates K2s package with code signing (certificate and password are both required)
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --certificate "path\to\cert.pfx" --password "mycertpassword"

	# Creates K2s package for offline installation with code signing
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --for-offline-installation --certificate "path\to\cert.pfx" --password "mycertpassword"

	# Creates a delta package (provide full package zip paths)
	k2s system package --delta-package --target-dir "C:\tmp" --name "k2s-delta-1.4.0-to-1.4.1.zip" --package-version-from "C:\tmp\k2s-1.4.0.zip" --package-version-to "C:\tmp\k2s-1.4.1.zip"

	# Creates a node package with Linux worker node artifacts for a specific OS
	# Requires an existing K2s cluster and the local cluster proxy
	k2s system package --node-package --os debian12 --target-dir "C:\out" --name "debian12-node.zip" --proxy http://172.19.1.1:8181

	# Creates a node package with GPU support (includes NVIDIA Container Toolkit packages)
	k2s system package --node-package --os debian12 --include-gpu --target-dir "C:\output" --name "debian12-node-gpu.zip" --proxy http://172.19.1.1:8181

	# Creates an arm64 node package - must run on a Linux arm64 host (no cross-build/VM path exists)
	sudo k2s system package --node-package --os debian13 --arch arm64 --target-dir /tmp/out --name debian13-node-arm64.zip

	# Creates a node-only delta package (between two node package zips)
	k2s system package --node-package --delta-package --package-version-from "C:\tmp\debian13-node-v1.7.0.zip" --package-version-to "C:\tmp\debian13-node-v1.8.0.zip" --target-dir "C:\output" --name "debian13-node-delta-v1.7.0-to-v1.8.0.zip"

	Note: For non-node packages, if offline artifacts are not already available due to previous installation, a 'Development Only Variant' will be installed during package creation and removed afterwards again
	`

	PackageCmd = &cobra.Command{
		Use:     "package",
		Short:   "Build K2s zip package with optional code signing",
		RunE:    systemPackage,
		Example: example,
	}
)

const (
	ControlPlaneCPUsFlagName  = "master-cpus"
	ControlPlaneCPUsFlagUsage = "Number of CPUs allocated to master VM"

	ControlPlaneMemoryFlagName  = "master-memory"
	ControlPlaneMemoryFlagUsage = "Amount of RAM to allocate to master VM (minimum 2GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneDiskSizeFlagName  = "master-disk"
	ControlPlaneDiskSizeFlagUsage = "Disk size allocated to the master VM (minimum 10GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ProxyFlagName  = "proxy"
	ProxyFlagUsage = "HTTP proxy if available to be used; required for --node-package, use the local cluster proxy http://172.19.1.1:8181"

	TargetDirectoryFlagName  = "target-dir"
	TargetDirectoryFlagUsage = "Target directory"

	ZipPackageFileNameFlagName  = "name"
	ZipPackageFileNameFlagUsage = "The name of the zip package (it must have the extension .zip)"

	ForOfflineInstallationFlagName  = "for-offline-installation"
	ForOfflineInstallationFlagUsage = "Creates a zip package that can be used for offline installation"

	K8sBinsFlagName  = "k8s-bins"
	K8sBinsFlagUsage = "Path to directory of locally built Kubernetes binaries (kubelet.exe, kube-proxy.exe, kubeadm.exe, kubectl.exe)"

	// Code signing flags
	CertificateFlagName  = "certificate"
	CertificateFlagUsage = "Path to code signing certificate (.pfx file)"

	PasswordFlagName  = "password"
	PasswordFlagUsage = "Password for the code signing certificate"

	DeltaPackageFlagName  = "delta-package"
	DeltaPackageFlagUsage = "Creates a delta package for faster updates"

	PackageVersionFromFlagName  = "package-version-from"
	PackageVersionFromFlagUsage = "Path to the existing (base) full package .zip (required if --delta-package is set)"

	PackageVersionToFlagName  = "package-version-to"
	PackageVersionToFlagUsage = "Path to the new (target) full package .zip (required if --delta-package is set)"

	ProfileFlagName  = "profile"
	ProfileFlagUsage = "Packaging profile: Dev (default) or Lite (skips optional build and large intermediate artifacts)"

	AddonsListFlagName  = "addons-list"
	AddonsListFlagUsage = "Comma-separated list of addons to include (e.g., 'ingress nginx,monitoring,logging'). For ingress, specify implementation: 'ingress nginx' or 'ingress traefik'. Use 'none' to exclude all addons. Default: all addons"
)

func init() {
	PackageCmd.Flags().String(ControlPlaneCPUsFlagName, "", ControlPlaneCPUsFlagUsage)
	PackageCmd.Flags().String(ControlPlaneMemoryFlagName, "", ControlPlaneMemoryFlagUsage)
	PackageCmd.Flags().String(ControlPlaneDiskSizeFlagName, "", ControlPlaneDiskSizeFlagUsage)
	PackageCmd.Flags().StringP(ProxyFlagName, "p", "", ProxyFlagUsage)
	PackageCmd.Flags().StringP(TargetDirectoryFlagName, "d", "", TargetDirectoryFlagUsage)
	PackageCmd.Flags().StringP(ZipPackageFileNameFlagName, "n", "", ZipPackageFileNameFlagUsage)
	PackageCmd.Flags().Bool(ForOfflineInstallationFlagName, false, ForOfflineInstallationFlagUsage)
	PackageCmd.Flags().String(K8sBinsFlagName, "", K8sBinsFlagUsage)
	PackageCmd.Flags().Bool(DeltaPackageFlagName, false, DeltaPackageFlagUsage)
	PackageCmd.Flags().String(PackageVersionFromFlagName, "", PackageVersionFromFlagUsage)
	PackageCmd.Flags().String(PackageVersionToFlagName, "", PackageVersionToFlagUsage)
	PackageCmd.Flags().Lookup(PackageVersionFromFlagName).NoOptDefVal = ""
	PackageCmd.Flags().Lookup(PackageVersionToFlagName).NoOptDefVal = ""
	PackageCmd.Flags().Lookup(DeltaPackageFlagName).NoOptDefVal = "true"

	// Node package flags (delegated to nodepackage sub-package) - register BEFORE setting PreRunE
	// so that nodepackage.IsSet() works correctly in validation
	nodepackage.RegisterFlags(PackageCmd)

	// NOTE: We do not mark the version flags as required here because they are only
	// required when --delta-package is set. Validation is handled in PreRunE below.
	PackageCmd.PreRunE = func(cmd *cobra.Command, args []string) error {
		// Node package is a fully separate mode — skip all other validations.
		if nodepackage.IsSet(cmd.Flags()) {
			supportedOS, err := config.ReadSupportedWorkerOS(utils.InstallDir())
			if err != nil {
				return fmt.Errorf("failed to read supported OS list: %w", err)
			}
			return nodepackage.Validate(cmd.Flags(), supportedOS)
		}

		profile, _ := cmd.Flags().GetString(ProfileFlagName)
		if profile == "" {
			profile = "Dev"
		}
		profile = strings.Title(strings.ToLower(profile))
		if profile != "Dev" && profile != "Lite" {
			return fmt.Errorf("--%s must be one of: Dev, Lite (got '%s')", ProfileFlagName, profile)
		}
		// normalize flag value in place so downstream always sees canonical form
		_ = cmd.Flags().Set(ProfileFlagName, profile)
		delta, _ := cmd.Flags().GetBool(DeltaPackageFlagName)
		from, _ := cmd.Flags().GetString(PackageVersionFromFlagName)
		to, _ := cmd.Flags().GetString(PackageVersionToFlagName)
		if delta {
			if from == "" {
				return fmt.Errorf("--%s is required when --%s is set", PackageVersionFromFlagName, DeltaPackageFlagName)
			}
			if to == "" {
				return fmt.Errorf("--%s is required when --%s is set", PackageVersionToFlagName, DeltaPackageFlagName)
			}
		} else {
			if from != "" {
				return fmt.Errorf("--%s can only be used when --%s is set", PackageVersionFromFlagName, DeltaPackageFlagName)
			}
			if to != "" {
				return fmt.Errorf("--%s can only be used when --%s is set", PackageVersionToFlagName, DeltaPackageFlagName)
			}
		}
		return nil
	}

	// Code signing flags
	PackageCmd.Flags().StringP(CertificateFlagName, "c", "", CertificateFlagUsage)
	PackageCmd.Flags().StringP(PasswordFlagName, "w", "", PasswordFlagUsage)
	PackageCmd.Flags().String(ProfileFlagName, "Dev", ProfileFlagUsage)

	// Addons list flag
	PackageCmd.Flags().String(AddonsListFlagName, "", AddonsListFlagUsage)

	PackageCmd.Flags().SortFlags = false
	PackageCmd.Flags().PrintDefaults()
}

func systemPackage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	// Node-package building on Linux runs entirely natively (no PowerShell, no VM):
	// it's required for arm64, since Hyper-V cannot provision an arm64 guest on an
	// x86 host, so the package has to be built directly on an arm64 Linux host.
	// --delta-package has no native-Linux implementation; fall through to the
	// PowerShell path below so it fails with the existing, explicit platform-guard
	// error rather than this branch silently building a full package instead.
	deltaRequested, _ := strconv.ParseBool(cmd.Flags().Lookup(DeltaPackageFlagName).Value.String())
	if nodepackage.IsSet(cmd.Flags()) && runtime.GOOS == "linux" && !deltaRequested {
		targetDir := cmd.Flags().Lookup(TargetDirectoryFlagName).Value.String()
		zipName := cmd.Flags().Lookup(ZipPackageFileNameFlagName).Value.String()
		proxy := cmd.Flags().Lookup(ProxyFlagName).Value.String()
		if err := nodepackage.BuildLinux(cmd.Flags(), targetDir, zipName, proxy); err != nil {
			return err
		}
		cmdSession.Finish()
		return nil
	}

	systemPackageCommand, params, err := buildSystemPackageCmd(cmd.Flags())
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", systemPackageCommand, "params", params)

	// Skip system installation check for node-package mode (no installation involved)
	if !nodepackage.IsSet(cmd.Flags()) {
		context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
		runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
		if err != nil {
			if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
				return common.CreateSystemInCorruptedStateCmdFailure()
			}
		}
		if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
			return &common.CmdFailure{
				Severity: common.SeverityWarning,
				Code:     "system-already-installed",
				Message:  fmt.Sprintf("'%s' is installed on your system. Please uninstall '%s' first and try again.", runtimeConfig.InstallConfig().SetupName(), runtimeConfig.InstallConfig().SetupName()),
			}
		}
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}

func buildSystemPackageCmd(flags *pflag.FlagSet) (string, []string, error) {
	delta, _ := strconv.ParseBool(flags.Lookup(DeltaPackageFlagName).Value.String())

	// Shared params
	out, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	targetDir := flags.Lookup(TargetDirectoryFlagName).Value.String()
	zipName := flags.Lookup(ZipPackageFileNameFlagName).Value.String()
	proxy := flags.Lookup(ProxyFlagName).Value.String()

	// Node package mode — delegate entirely to the node sub-package.
	if nodepackage.IsSet(flags) {
		return nodepackage.BuildCmd(flags, out, targetDir, zipName, proxy)
	}

	// For non-node-package modes, require target-dir and name flags
	if targetDir == "" {
		return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", TargetDirectoryFlagName)
	}
	if zipName == "" {
		return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", ZipPackageFileNameFlagName)
	}

	params := []string{}
	if out {
		params = append(params, " -ShowLogs")
	}
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(zipName))

	// Code signing (applies to both normal and delta packages)
	certPath := flags.Lookup(CertificateFlagName).Value.String()
	password := flags.Lookup(PasswordFlagName).Value.String()
	if certPath != "" {
		if password == "" {
			return "", nil, fmt.Errorf("password is required when using a certificate")
		}
		params = append(params, " -CertificatePath "+utils.EscapeWithSingleQuotes(certPath))
		params = append(params, " -Password "+utils.EscapeWithSingleQuotes(password))
	} else if password != "" {
		return "", nil, fmt.Errorf("certificate is required when providing a password")
	}

	if delta {
		oldPkg := flags.Lookup(PackageVersionFromFlagName).Value.String()
		newPkg := flags.Lookup(PackageVersionToFlagName).Value.String()
		params = append(params, " -InputPackageOne "+utils.EscapeWithSingleQuotes(oldPkg))
		params = append(params, " -InputPackageTwo "+utils.EscapeWithSingleQuotes(newPkg))
		if proxy != "" {
			params = append(params, " -Proxy "+utils.EscapeWithSingleQuotes(proxy))
		}
		return utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sDeltaPackage.ps1")), params, nil
	}

	// Normal (full) package path
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1"))

	// Only add full-package specific params if not delta
	if proxy != "" {
		params = append(params, " -Proxy "+proxy)
	}
	cpus := flags.Lookup(ControlPlaneCPUsFlagName).Value.String()
	if cpus != "" {
		params = append(params, " -VMProcessorCount "+cpus)
	}
	memory := flags.Lookup(ControlPlaneMemoryFlagName).Value.String()
	if memory != "" {
		params = append(params, " -VMMemoryStartupBytes "+memory)
	}
	disksize := flags.Lookup(ControlPlaneDiskSizeFlagName).Value.String()
	if disksize != "" {
		params = append(params, " -VMDiskSize "+disksize)
	}
	forOfflineInstallation, _ := strconv.ParseBool(flags.Lookup(ForOfflineInstallationFlagName).Value.String())
	if forOfflineInstallation {
		params = append(params, " -ForOfflineInstallation")
	}
	profile := flags.Lookup(ProfileFlagName).Value.String()
	if profile != "" {
		params = append(params, " -Profile "+profile)
	}
	k8sBins := flags.Lookup(K8sBinsFlagName).Value.String()
	if k8sBins != "" {
		params = append(params, fmt.Sprintf(" -K8sBinsPath '%s'", k8sBins))
	}
	addonsList := flags.Lookup(AddonsListFlagName).Value.String()
	if addonsList != "" {
		params = append(params, " -AddonsList "+utils.EscapeWithSingleQuotes(addonsList))
	}

	return systemPackageCommand, params, nil
}
