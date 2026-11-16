// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package install

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"os"
	"path/filepath"
	"runtime"

	config_contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/effectiveconfig"
	kos "github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/powershell"
	"github.com/k2s-project/k2s/internal/version"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/buildonly"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/core"

	"github.com/k2s-project/k2s/cmd/k2s/utils/tz"

	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"

	"github.com/k2s-project/k2s/internal/terminal"

	cc "github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
)

const (
	kind ic.Kind = "k2s"
)

var (
	example = `
	# install K2s setup (online/offline - depending on offline files existence)
	k2s install

	# install K2s setup overwriting control-plane memory
	k2s install --master-memory 8GB

	# install K2s setup with dynamic memory management (min/max auto-enables dynamic memory)
	k2s install --master-memory-min 2GB --master-memory-max 10GB

	# install K2s setup with dynamic memory and startup memory
	k2s install --master-memory 4GB --master-memory-min 2GB --master-memory-max 10GB

	# install without Windows worker node
	k2s install --linux-only

	# install K2s setup setting a proxy
	k2s install --proxy http://10.11.12.13:5000

	# install K2s setup setting a proxy with no-proxy hosts
	k2s install --proxy http://10.11.12.13:5000 --no-proxy localhost,127.0.0.1,.local

	# install K2s setup using a user-defined config file
	k2s install -c 'c:\temp\my-config.yaml'

	# install K2s setup using a user-defined config file overwriting the control-plane CPU number
	k2s install -c 'c:\temp\my-config.yaml' --master-cpus 4

	# install K2s setup deleting the downloaded files for subsequent offline installations
	k2s install --delete-files-for-offline-installation

	# install K2s setup forcing an online installation, i.e. downloading files
	k2s install --force-online-installation
	`

	InstallCmd = &cobra.Command{
		Use:     "install",
		Short:   fmt.Sprintf("Installs '%s' K8s cluster on the host machine", kind),
		RunE:    install,
		Example: example,
	}
	createTzHandleFunc func(config *config_contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error)
)

func init() {
	InstallCmd.AddCommand(buildonly.InstallCmd)

	// Wire buildonly subcommand to the core.Installer (PS-based, Windows-only).
	buildonly.Installer = &core.Installer{
		InstallConfigAccess:      ic.NewInstallConfigAccess(),
		Printer:                  terminal.NewTerminalPrinter(),
		ExecutePsScript:          powershell.ExecutePs,
		GetVersionFunc:           version.GetVersion,
		GetPlatformFunc:          utils.Platform,
		GetInstallDirFunc:        utils.InstallDir,
		LoadConfigFunc:           config.ReadRuntimeConfig,
		MarkSetupAsCorruptedFunc: config.MarkSetupAsCorrupted,
		DeleteConfigFunc: func(configDir string) error {
			return os.Remove(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName))
		},
		StageEffectiveInstallConfigFunc: func(configDir string, content []byte) (core.EffectiveInstallConfigSnapshot, error) {
			return effectiveconfig.Stage(configDir, content)
		},
	}

	createTzHandleFunc = createTimezoneConfigHandle

	bindFlags(InstallCmd)
}

func bindFlags(cmd *cobra.Command) {
	cmd.Flags().String(cc.AdditionalHooksDirFlagName, "", cc.AdditionalHooksDirFlagUsage)
	cmd.Flags().BoolP(cc.DeleteFilesFlagName, cc.DeleteFilesFlagShorthand, false, cc.DeleteFilesFlagUsage)
	cmd.Flags().BoolP(cc.ForceOnlineInstallFlagName, cc.ForceOnlineInstallFlagShorthand, false, cc.ForceOnlineInstallFlagUsage)

	bindPlatformFlags(cmd)
	cmd.Flags().StringP(ic.ProxyFlagName, ic.ProxyFlagShorthand, "", ic.ProxyFlagUsage)
	cmd.Flags().StringSlice(ic.NoProxyFlagName, []string{}, ic.NoProxyFlagUsage)
	cmd.Flags().StringP(ic.ConfigFileFlagName, ic.ConfigFileFlagShorthand, "", ic.ConfigFileFlagUsage)

	// convenience flag; not configurable in config file
	cmd.Flags().Bool(ic.LinuxOnlyFlagName, false, ic.LinuxOnlyFlagUsage)

	cmd.Flags().Bool(ic.AppendLogFlagName, false, ic.AppendLogFlagUsage)
	cmd.Flags().Bool(ic.SkipStartFlagName, false, ic.SkipStartFlagUsage)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func createTimezoneConfigHandle(config *config_contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error) {
	tzConfigWorkspace, err := tz.NewTimezoneConfigWorkspace(config)
	if err != nil {
		return nil, err
	}
	tzConfigHandle, err := tzConfigWorkspace.CreateHandle()
	if err != nil {
		return nil, err
	}
	return tzConfigHandle, nil
}

func checkForOldK2sExecutables(currentExe string, exeName string) ([]string, error) {
	otherK2s, err := kos.FindOtherExecutablesInPath(currentExe, exeName)
	if err != nil {
		return nil, fmt.Errorf("[Install] Error scanning PATH for %s: %v", exeName, err)
	}
	return otherK2s, nil
}

func install(cmd *cobra.Command, args []string) error {
	exeName := "k2s.exe"
	if runtime.GOOS == "linux" {
		exeName = "k2s"
	}
	currentExe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("[Install] Error: unable to determine current executable path: %v", err)
	}
	otherK2s, err := checkForOldK2sExecutables(currentExe, exeName)
	if err != nil {
		return err
	}
	if len(otherK2s) > 0 {
		fmt.Println("[Install] Found older k2s executables:")
		for _, p := range otherK2s {
			fmt.Fprintf(os.Stderr, "  %s\n", p)
		}
		return fmt.Errorf("Please clean up your PATH environment variable to remove old k2s.exe locations before proceeding with installation.")
	}

	// Parse install config from CLI flags
	installCfgAccess := ic.NewInstallConfigAccess()
	installConfig, err := installCfgAccess.Load(kind, cmd.Flags())
	if err != nil {
		return err
	}
	linuxOnly, err := cmd.Flags().GetBool(ic.LinuxOnlyFlagName)
	if err != nil {
		return err
	}
	installConfig.LinuxOnly = linuxOnly

	if runtime.GOOS == "linux" {
		if err := validateLinuxInstallOptions(cmd, installConfig.LinuxOnly); err != nil {
			return err
		}
	}

	cmdSession := cc.StartCmdSession(cmd.CommandPath())
	context := cmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)
	configDir := context.Config().Host().K2sSetupConfigDir()

	// Check if already installed
	runtimeConfig, err := config.ReadRuntimeConfig(configDir)
	if errors.Is(err, config_contracts.ErrSystemInCorruptedState) {
		return cc.CreateSystemInCorruptedStateCmdFailure()
	}
	if err != nil && !errors.Is(err, config_contracts.ErrSystemNotInstalled) {
		return err
	}
	if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
		return &cc.CmdFailure{
			Severity: cc.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", runtimeConfig.InstallConfig().SetupName()),
		}
	}

	effectiveInstallConfig, err := json.MarshalIndent(installConfig, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to serialize effective install configuration: %w", err)
	}
	slog.Debug("Installing using normalized effective configuration")

	tzConfigHandle, err := createTzHandleFunc(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	// Build provider install config
	node, err := installConfig.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return err
	}
	// The managed Windows worker only exists for native Linux hosts. Everywhere
	// else the worker resources stay empty so nothing is resolved or passed on.
	var worker ic.NodeConfig
	if runtime.GOOS == "linux" && !installConfig.LinuxOnly {
		if configured, found := installConfig.FindNodeByRole(ic.WorkerRoleName); found {
			worker = *configured
		}
	}

	hostname, _ := os.Hostname()
	ver := version.GetVersion()

	slog.Info("Installing", "kind", kind, "version", ver, "platform", utils.Platform())

	outputWriter := cc.NewPtermWriter()

	err = context.Providers().Cluster.Install(provider.ClusterInstallConfig{
		SetupName:                         string(kind),
		MasterVMProcessorCount:            node.Resources.Cpu,
		MasterVMMemory:                    node.Resources.Memory,
		MasterVMMemoryMin:                 node.Resources.MemoryMin,
		MasterVMMemoryMax:                 node.Resources.MemoryMax,
		MasterDiskSize:                    node.Resources.Disk,
		WorkerCPUCount:                    worker.Resources.Cpu,
		WorkerMemory:                      worker.Resources.Memory,
		WorkerDiskSize:                    worker.Resources.Disk,
		WindowsQCOW2Path:                  installConfig.WindowsQCOW2Path,
		DynamicMemory:                     node.Resources.DynamicMemory,
		LinuxOnly:                         installConfig.LinuxOnly,
		WSL:                               installConfig.Behavior.Wsl,
		ShowLogs:                          installConfig.Behavior.ShowOutput,
		SkipStart:                         installConfig.Behavior.SkipStart,
		ForceOnlineInstallation:           installConfig.Behavior.ForceOnlineInstallation,
		DeleteFilesForOfflineInstallation: installConfig.Behavior.DeleteFilesForOfflineInstallation,
		AppendLog:                         installConfig.Behavior.AppendLog,
		Proxy:                             installConfig.Env.Proxy,
		NoProxy:                           installConfig.Env.NoProxy,
		AdditionalHooksDir:                installConfig.Env.AdditionalHooksDir,
		K8sBinsPath:                       installConfig.Env.K8sBins,
		RestartPostInstall:                installConfig.Env.RestartPostInstall,
		ConfigDir:                         configDir,
		InstallDir:                        utils.InstallDir(),
		Version:                           fmt.Sprintf("%s", ver),
		ClusterName:                       "k2s-cluster",
		ControlPlaneHostname:              hostname,
		EffectiveInstallConfig:            effectiveInstallConfig,
		StdWriter:                         outputWriter,
	})
	if err != nil {
		// On Windows, check for prerequisite failures in PS output
		errorLine, found := cc.GetInstallPreRequisiteError(outputWriter.ErrorLines)
		if found {
			slog.Warn("Prerequisite check failed", "detail", errorLine)
			if delErr := os.Remove(filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)); delErr != nil {
				slog.Debug("config file does not exist, nothing to do")
			}
			return &cc.CmdFailure{
				Severity: cc.SeverityWarning,
				Code:     "prereq-failed",
				Message:  fmt.Sprintf("Prerequisite check failed: %s. See https://github.com/k2s-project/k2s/blob/main/docs/op-manual/installing-k2s.md#prerequisites", errorLine),
			}
		}

		if outputWriter.ErrorOccurred {
			if markErr := config.MarkSetupAsCorrupted(configDir); markErr != nil {
				slog.Error("error while marking setup as corrupted", "error", markErr)
			}
			return cc.CreateSystemInCorruptedStateCmdFailure()
		}

		return err
	}

	cmdSession.Finish()
	return nil
}

func validateLinuxInstallOptions(cmd *cobra.Command, linuxOnly bool) error {
	// Flags the Linux flag set does not register at all (see flags_linux.go) are
	// rejected by cobra itself, so only the cross-platform ones are listed here.
	unsupportedFlags := []string{
		cc.ForceOnlineInstallFlagName,
		cc.DeleteFilesFlagName,
	}
	for _, flagName := range unsupportedFlags {
		if cmd.Flags().Changed(flagName) {
			return fmt.Errorf("--%s is not supported for native Linux hosts", flagName)
		}
	}
	return nil
}
