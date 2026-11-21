// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package restore

import (
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "restore Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	SystemRestoreCmd.Flags().BoolP(
		common.OutputFlagName,
		common.OutputFlagShorthand,
		false,
		common.OutputFlagUsage,
	)
})

// Helper to reset flags between tests
func resetRestoreFlags() {
	flags := SystemRestoreCmd.Flags()
	flags.Set(common.OutputFlagName, "false")
	flags.Set(restoreFileFlag, "")
	flags.Set(errorOnFailureFlag, "false")
	flags.Set(common.AdditionalHooksDirFlagName, "")
}

var _ = Describe("restore", func() {

	Describe("createSystemRestorePsCommand", func() {

		When("only mandatory flags are set", func() {
			It("creates minimal restore command", func() {
				const staticPart = `\lib\scripts\windows\host\system\restore\Start-SystemRestore.ps1`
				const args = ` -BackupFile 'C:\temp\backup.zip'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetRestoreFlags()
				SystemRestoreCmd.Flags().Set(restoreFileFlag, `C:\temp\backup.zip`)

				actual := createSystemRestorePsCommand(SystemRestoreCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("show logs flag is enabled", func() {
			It("adds -ShowLogs to restore command", func() {
				const staticPart = `\lib\scripts\windows\host\system\restore\Start-SystemRestore.ps1`
				const args = ` -ShowLogs -BackupFile 'C:\temp\backup.zip'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetRestoreFlags()
				flags := SystemRestoreCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(restoreFileFlag, `C:\temp\backup.zip`)

				actual := createSystemRestorePsCommand(SystemRestoreCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("error-on-failure flag is enabled", func() {
			It("adds -ErrorOnFailure to restore command", func() {
				const staticPart = `\lib\scripts\windows\host\system\restore\Start-SystemRestore.ps1`
				const args = ` -BackupFile 'C:\temp\backup.zip' -ErrorOnFailure`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetRestoreFlags()
				flags := SystemRestoreCmd.Flags()
				flags.Set(restoreFileFlag, `C:\temp\backup.zip`)
				flags.Set(errorOnFailureFlag, "true")

				actual := createSystemRestorePsCommand(SystemRestoreCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("additional hooks directory is provided", func() {
			It("adds -AdditionalHooksDir to restore command", func() {
				const staticPart = `\lib\scripts\windows\host\system\restore\Start-SystemRestore.ps1`
				const args = ` -BackupFile 'C:\temp\backup.zip' -AdditionalHooksDir 'hooksDir'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetRestoreFlags()
				flags := SystemRestoreCmd.Flags()
				flags.Set(restoreFileFlag, `C:\temp\backup.zip`)
				flags.Set(common.AdditionalHooksDirFlagName, "hooksDir")

				actual := createSystemRestorePsCommand(SystemRestoreCmd)

				Expect(actual).To(Equal(expected))
			})
		})

		When("all flags are enabled together", func() {
			It("creates full restore command", func() {
				const staticPart = `\lib\scripts\windows\host\system\restore\Start-SystemRestore.ps1`
				const args = ` -ShowLogs -BackupFile 'C:\temp\backup.zip' -ErrorOnFailure -AdditionalHooksDir 'hooksDir'`

				expected := utils.FormatScriptFilePath(
					utils.InstallDir()+staticPart,
				) + args

				resetRestoreFlags()
				flags := SystemRestoreCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(restoreFileFlag, `C:\temp\backup.zip`)
				flags.Set(errorOnFailureFlag, "true")
				flags.Set(common.AdditionalHooksDirFlagName, "hooksDir")

				actual := createSystemRestorePsCommand(SystemRestoreCmd)

				Expect(actual).To(Equal(expected))
			})
		})
	})
})
