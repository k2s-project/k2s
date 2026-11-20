// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package compact

import (
	"errors"
	"path/filepath"
	"strconv"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/cmd/k2s/utils/tz"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/spf13/cobra"
)

var (
	noRestartFlag bool
	yesFlag       bool
)

var CompactCmd = &cobra.Command{
	Use:   "compact",
	Short: "Compact VHDX disk to reclaim unused space (control-plane node only)",
	Long: `Compacts the KubeMaster VHDX file (the control-plane node disk) to reclaim disk space freed by deleted images and files.
This affects only the control-plane node; worker nodes and the local host are not touched.

Supported setups: k2s (standard) and Linux-only.
Not supported: WSL-based and build-only setups (no Hyper-V VHDX present).`,
	Example: `      # Compact VHDX with automatic cluster restart
      k2s system compact

      # Compact and keep cluster stopped afterwards (stop still happens)
      k2s system compact --no-restart

      # Skip confirmation prompts
      k2s system compact --yes`,
	RunE: compactVhdx,
}

func init() {
	CompactCmd.Flags().BoolVar(&noRestartFlag, "no-restart", false, "Keep cluster stopped after compaction")
	CompactCmd.Flags().BoolVarP(&yesFlag, "yes", "y", false, "Skip confirmation prompts")
	CompactCmd.Flags().SortFlags = false
	CompactCmd.Flags().PrintDefaults()
}

func compactVhdx(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if runtimeConfig.InstallConfig().SetupName() == definitions.SetupNameBuildOnlyEnv {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "functionality-not-available-for-build-only",
			Message:  "VHDX compaction is not available in build-only setup (no VM/VHDX present).",
		}
	}

	if runtimeConfig.InstallConfig().WslEnabled() {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "functionality-not-available-for-wsl",
			Message:  "VHDX compaction is not available for WSL-based installations.",
		}
	}

	tzConfigHandle, err := tz.NewTimezoneConfigWorkspace(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	handle, err := tzConfigHandle.CreateHandle()
	if err != nil {
		return err
	}
	defer handle.Release()

	if err := context.Providers().System.Compact(provider.SystemCompactConfig{
		NoRestart:  noRestartFlag,
		Yes:        yesFlag,
		ShowOutput: outputFlag,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildCompactCmd(outputFlag bool) (string, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "compact", "Invoke-VhdxCompaction.ps1"))

	params := ""
	if noRestartFlag {
		params += " -NoRestart"
	}
	if yesFlag {
		params += " -Yes"
	}
	if outputFlag {
		params += " -ShowLogs"
	}

	return scriptPath + params, nil
}
