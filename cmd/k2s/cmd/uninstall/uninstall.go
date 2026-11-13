// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package uninstall

import (
	"errors"
	"runtime"
	"strconv"

	cConfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/version"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
)

var (
	skipPurge       = "skip-purge"
	UninstallK8sCmd = &cobra.Command{
		Use:   "uninstall",
		Short: "Uninstalls K2s cluster from the host machine",
		RunE:  uninstallK8s,
	}
)

func init() {
	UninstallK8sCmd.Flags().Bool(skipPurge, false, "Skips purging all the files. This option is not set by default.")
	UninstallK8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	UninstallK8sCmd.Flags().BoolP(common.DeleteFilesFlagName, common.DeleteFilesFlagShorthand, false, common.DeleteFilesFlagUsage)
	UninstallK8sCmd.Flags().SortFlags = false
	UninstallK8sCmd.Flags().PrintDefaults()
}

func uninstallK8s(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	ver := version.GetVersion()

	pterm.Printfln("🤖 Uninstalling K2s %s", ver)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cConfig.ErrSystemNotInstalled) {
			// A Linux install persists runtime state only after kubeadm and the CNI
			// complete. Permit cleanup of an interrupted native installation even
			// when it failed before that final persistence step. Windows retains
			// its existing runtime-config requirement.
			if runtime.GOOS != "linux" {
				return common.CreateSystemNotInstalledCmdFailure()
			}
		} else if !errors.Is(err, cConfig.ErrSystemInCorruptedState) {
			return err
		}
	}

	// Read flags
	skipPurgeFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipPurge).Value.String())
	if err != nil {
		return err
	}
	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	deleteFiles, err := strconv.ParseBool(cmd.Flags().Lookup(common.DeleteFilesFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	var setupName string
	var linuxOnly bool
	if runtimeConfig != nil {
		setupName = runtimeConfig.InstallConfig().SetupName()
		linuxOnly = runtimeConfig.InstallConfig().LinuxOnly()
	}

	// Uninstall via provider (handles platform dispatch)
	err = context.Providers().Cluster.Uninstall(provider.ClusterUninstallConfig{
		ShowLogs:                          outputFlag,
		SkipPurge:                         skipPurgeFlag,
		DeleteFilesForOfflineInstallation: deleteFiles,
		AdditionalHooksDir:                additionalHooksDir,
		ConfigDir:                         context.Config().Host().K2sSetupConfigDir(),
		SetupName:                         setupName,
		LinuxOnly:                         linuxOnly,
	})
	if err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}
