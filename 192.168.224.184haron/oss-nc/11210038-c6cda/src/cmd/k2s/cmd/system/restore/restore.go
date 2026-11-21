// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package restore

import (
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/provider"
)

const (
	restoreFileFlag      = "file"
	errorOnFailureFlag   = "error-on-failure"
)

var SystemRestoreCmd = &cobra.Command{
	Use:   "restore",
	Short: "Restores K2s cluster resources from a backup",
	RunE:  runSystemRestore,
}

func init() {
	SystemRestoreCmd.Flags().SortFlags = false
	SystemRestoreCmd.Flags().StringP(restoreFileFlag, "f", "", "Backup file to restore from (zip)",)
	_ = SystemRestoreCmd.MarkFlagRequired(restoreFileFlag)
	SystemRestoreCmd.Flags().BoolP(errorOnFailureFlag, "e", false, "Fail if errors occur while restoring resources",)
	SystemRestoreCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage,)
}

func runSystemRestore(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("📦 Restoring K2s system backup ...")

	out, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())

	backupFile := cmd.Flags().Lookup(restoreFileFlag).Value.String()

	errorOnFailure, _ := strconv.ParseBool(cmd.Flags().Lookup(errorOnFailureFlag).Value.String())

	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	if err := context.Providers().System.Restore(provider.SystemRestoreConfig{
		BackupFile:         backupFile,
		AdditionalHooksDir: additionalHooksDir,
		ErrorOnFailure:     errorOnFailure,
		ShowOutput:         out,
	}); err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}

func createSystemRestorePsCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(
		utils.InstallDir() +
			"\\lib\\scripts\\windows\\host\\system\\restore\\Start-SystemRestore.ps1",
	)

	out, _ := strconv.ParseBool(
		cmd.Flags().Lookup(common.OutputFlagName).Value.String(),
	)
	if out {
		psCmd += " -ShowLogs"
	}

	backupFile := cmd.Flags().Lookup(restoreFileFlag).Value.String()
	psCmd += " -BackupFile " + utils.EscapeWithSingleQuotes(backupFile)

	errorOnFailure, _ := strconv.ParseBool(
		cmd.Flags().Lookup(errorOnFailureFlag).Value.String(),
	)
	if errorOnFailure {
		psCmd += " -ErrorOnFailure"
	}

	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	if additionalHooksDir != "" {
		psCmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	return psCmd
}
