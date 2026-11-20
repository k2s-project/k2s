// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package backup

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
)

const (
	backupFileFlag = "file"
	skipImagesFlag = "skip-images"
	skipPVsFlag    = "skip-pvs"
)

var SystemBackupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Backs up cluster resources, persistent volumes, and user application images",
	RunE:  runSystemBackup,
}

func init() {
	SystemBackupCmd.Flags().SortFlags = false
	SystemBackupCmd.Flags().StringP(backupFileFlag, "f", "", "Backup file to create (.zip). If omitted, a default file in temp directory is generated")
	SystemBackupCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	SystemBackupCmd.Flags().Bool(skipImagesFlag, false, "Skip backing up container images")
	SystemBackupCmd.Flags().Bool(skipPVsFlag, false, "Skip backing up persistent volumes")
}

func runSystemBackup(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	defer cmdSession.Finish()

	pterm.Println("📦 Creating K2s system backup ...")

	out, err := cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}

	backupFile := resolveBackupFileName(cmd)

	additionalHooksDir, err := cmd.Flags().GetString(common.AdditionalHooksDirFlagName)
	if err != nil {
		return err
	}

	skipImages, err := cmd.Flags().GetBool(skipImagesFlag)
	if err != nil {
		return err
	}

	skipPVs, err := cmd.Flags().GetBool(skipPVsFlag)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	return context.Providers().System.Backup(provider.SystemBackupConfig{
		BackupFile:         backupFile,
		AdditionalHooksDir: additionalHooksDir,
		SkipImages:         skipImages,
		SkipPVs:            skipPVs,
		ShowOutput:         out,
	})
}

func resolveBackupFileName(cmd *cobra.Command) string {
	file, err := cmd.Flags().GetString(backupFileFlag)
	if err == nil && file != "" {
		return file
	}

	timestamp := time.Now().Format("2006-01-02_15-04-05")
	filename := fmt.Sprintf("k2s-backup-file-%s.zip", timestamp)
	return filepath.Join(os.TempDir(), "k2s", "backups", filename)
}
