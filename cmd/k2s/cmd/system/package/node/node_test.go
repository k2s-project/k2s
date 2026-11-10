// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package nodepackage

import (
	"path/filepath"
	"runtime"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

func TestNodePackage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node-package Unit Tests", Label("unit", "ci"))
}

// helper: create a cobra command with all node-package flags registered.
func newTestCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "test"}
	RegisterFlags(cmd)
	cmd.Flags().Bool(DeltaPackageFlagName, false, "")
	cmd.Flags().String(PackageVersionFromFlagName, "", "")
	cmd.Flags().String(PackageVersionToFlagName, "", "")
	return cmd
}

var _ = Describe("nodepackage", func() {

	Describe("IsSet", func() {
		It("returns false when flag is not set", func() {
			cmd := newTestCmd()
			Expect(IsSet(cmd.Flags())).To(BeFalse())
		})

		It("returns true when --node-package is set", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(NodePackageFlagName, "true")
			Expect(IsSet(cmd.Flags())).To(BeTrue())
		})
	})

	Describe("Validate", func() {
		var supportedOS = []string{"debian12", "debian13"}

		It("returns error when --os is missing", func() {
			cmd := newTestCmd()

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("--os"))
			Expect(err.Error()).To(ContainSubstring("--node-package"))
		})

		It("returns nil when --os is a supported value", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian12")

			Expect(Validate(cmd.Flags(), supportedOS)).To(Succeed())
		})

		It("returns error when --os value is not in the supported list", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "ubuntu22")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("ubuntu22"))
			Expect(err.Error()).To(ContainSubstring("debian12"))
		})

		It("returns nil for node-delta mode without --os", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(DeltaPackageFlagName, "true")
			cmd.Flags().Set(PackageVersionFromFlagName, "C:\\old-node.zip")
			cmd.Flags().Set(PackageVersionToFlagName, "C:\\new-node.zip")

			Expect(Validate(cmd.Flags(), supportedOS)).To(Succeed())
		})

		It("returns error for node-delta mode without --package-version-from", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(DeltaPackageFlagName, "true")
			cmd.Flags().Set(PackageVersionToFlagName, "C:\\new-node.zip")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring(PackageVersionFromFlagName))
		})

		It("returns error for node-delta mode without --package-version-to", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(DeltaPackageFlagName, "true")
			cmd.Flags().Set(PackageVersionFromFlagName, "C:\\old-node.zip")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring(PackageVersionToFlagName))
		})

		It("returns nil when --arch defaults to amd64", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian12")

			Expect(Validate(cmd.Flags(), supportedOS)).To(Succeed())
		})

		It("returns error for an unsupported --arch value", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian13")
			cmd.Flags().Set(ArchFlagName, "mips")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("mips"))
		})

		It("returns error for --arch arm64 on a non-Debian --os", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "ubuntu22")
			cmd.Flags().Set(ArchFlagName, "arm64")
			supportedWithUbuntu := append([]string{"ubuntu22"}, supportedOS...)

			err := Validate(cmd.Flags(), supportedWithUbuntu)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("Debian-family"))
		})

		It("fails fast for --arch arm64 when not running on Linux", func() {
			if runtime.GOOS == "linux" {
				Skip("this assertion only applies to non-Linux builds")
			}
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian13")
			cmd.Flags().Set(ArchFlagName, "arm64")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("Linux arm64 host"))
		})
	})

	Describe("BuildCmd", func() {
		When("target-dir is missing", func() {
			It("returns an error", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, _, err := BuildCmd(cmd.Flags(), false, "", "debian12-node.zip", "")
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("target-dir"))
			})
		})

		When("name is missing", func() {
			It("returns an error", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, _, err := BuildCmd(cmd.Flags(), false, "C:\\output", "", "")
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("name"))
			})
		})

		When("debian12", func() {
			It("routes to New-K2sNodePackage.ps1 with correct params", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				script, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(script).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sNodePackage.ps1")))
				Expect(params).To(ContainElement(" -TargetDirectory 'C:\\output'"))
				Expect(params).To(ContainElement(" -ZipPackageFileName 'debian12-node.zip'"))
				Expect(params).To(ContainElement(" -OS 'debian12'"))
			})
		})

		When("debian13", func() {
			It("builds params for debian13", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian13")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian13-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -OS 'debian13'"))
			})
		})

		When("proxy is provided", func() {
			It("includes -Proxy param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "http://proxy:8080")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Proxy http://proxy:8080"))
			})
		})

		When("proxy is empty", func() {
			It("does not include -Proxy param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				for _, p := range params {
					Expect(p).ToNot(ContainSubstring("Proxy"))
				}
			})
		})

		When("ShowLogs is requested", func() {
			It("includes -ShowLogs param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), true, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -ShowLogs"))
			})
		})

		When("ShowLogs is not requested", func() {
			It("does not include -ShowLogs param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				for _, p := range params {
					Expect(p).ToNot(ContainSubstring("ShowLogs"))
				}
			})
		})

		It("does not route to full-package or delta-package scripts", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian12")

			script, _, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
			Expect(err).ToNot(HaveOccurred())
			Expect(script).ToNot(ContainSubstring("New-K2sPackage.ps1"))
			Expect(script).ToNot(ContainSubstring("New-K2sDeltaPackage.ps1"))
		})

		It("routes node-delta mode to New-K2sNodeDeltaPackage.ps1", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(DeltaPackageFlagName, "true")
			cmd.Flags().Set(PackageVersionFromFlagName, "C:\\old-node.zip")
			cmd.Flags().Set(PackageVersionToFlagName, "C:\\new-node.zip")

			script, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "node-delta.zip", "")
			Expect(err).ToNot(HaveOccurred())
			Expect(script).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sNodeDeltaPackage.ps1")))
			Expect(params).To(ContainElement(" -InputPackageOne 'C:\\old-node.zip'"))
			Expect(params).To(ContainElement(" -InputPackageTwo 'C:\\new-node.zip'"))
		})
	})
})
