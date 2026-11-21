// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package compact

import (
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestCompact(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "compact Unit Tests", Label("unit", "ci"))
}

func resetCompactFlags() {
	noRestartFlag = false
	yesFlag = false
	CompactCmd.Flags().Set(common.OutputFlagName, "false")
}

var _ = Describe("compact", func() {
	Describe("buildCompactCmd", func() {
		BeforeEach(func() {
			resetCompactFlags()
		})

		When("no optional flags are set", func() {
			It("returns a command containing only the script path", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir() + `\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`)

				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("show-logs (output) flag is set", func() {
			It("appends -ShowLogs to the command", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir()+`\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`) + " -ShowLogs"

				actual, err := buildCompactCmd(true)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("no-restart flag is set", func() {
			It("appends -NoRestart to the command", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir()+`\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`) + " -NoRestart"

				noRestartFlag = true
				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("yes flag is set", func() {
			It("appends -Yes to the command", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir()+`\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`) + " -Yes"

				yesFlag = true
				actual, err := buildCompactCmd(false)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("all flags are set", func() {
			It("appends all parameters in the correct order", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir()+`\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`) + " -NoRestart -Yes -ShowLogs"

				noRestartFlag = true
				yesFlag = true
				actual, err := buildCompactCmd(true)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("no-restart and show-logs flags are set", func() {
			It("appends both parameters", func() {
				expected := utils.FormatScriptFilePath(utils.InstallDir()+`\lib\scripts\windows\host\system\compact\Invoke-VhdxCompaction.ps1`) + " -NoRestart -ShowLogs"

				noRestartFlag = true
				actual, err := buildCompactCmd(true)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		It("always references Invoke-VhdxCompaction.ps1 inside the compact subfolder", func() {
			actual, err := buildCompactCmd(false)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "compact", "Invoke-VhdxCompaction.ps1")))
		})
	})
})
