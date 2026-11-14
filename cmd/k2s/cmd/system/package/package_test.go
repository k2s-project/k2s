// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package systempackage

import (
	"path/filepath"
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/pflag"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "package Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	PackageCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
})

var _ = Describe("package", func() {
	Describe("buildSystemPackageCmd", func() {
		When("flags set", func() {
			It("creates the command", func() {
				flags := PackageCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(ControlPlaneCPUsFlagName, "6")
				flags.Set(ControlPlaneMemoryFlagName, "4GB")
				flags.Set(ControlPlaneDiskSizeFlagName, "50GB")
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(ProxyFlagName, "http://myproxy:81")
				flags.Set(ForOfflineInstallationFlagName, "true")
				flags.Set(K8sBinsFlagName, "k8sbins")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ConsistOf(" -ShowLogs", " -Proxy http://myproxy:81", " -VMProcessorCount 6", " -VMMemoryStartupBytes 4GB", " -VMDiskSize 50GB", " -TargetDirectory 'dir'", " -ZipPackageFileName 'file.zip'", " -ForOfflineInstallation", " -Profile Dev", " -K8sBinsPath 'k8sbins'"))
			})
		})

		When("code signing flags set", func() {
			It("returns error when certificate provided without password", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(CertificateFlagName, "C:\\certs\\signing.pfx")
				// No password provided

				_, _, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(Equal("password is required when using a certificate"))
			})

			It("returns error when password provided without certificate", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(PasswordFlagName, "secretpassword")
				// No certificate provided
				flags.Set(CertificateFlagName, "") // Explicitly set certificate to empty

				_, _, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(Equal("certificate is required when providing a password"))
			})

			It("creates command with certificate path and password", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(CertificateFlagName, "C:\\certs\\signing.pfx")
				flags.Set(PasswordFlagName, "secretpassword")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ContainElement(" -CertificatePath 'C:\\certs\\signing.pfx'"))
				Expect(params).To(ContainElement(" -Password 'secretpassword'"))
			})

			It("creates command with both standard and code signing parameters", func() {
				flags := PackageCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(ProxyFlagName, "http://proxy:8080")
				flags.Set(ForOfflineInstallationFlagName, "true")
				flags.Set(CertificateFlagName, "signing.pfx")
				flags.Set(PasswordFlagName, "certpassword")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ContainElement(" -ShowLogs"))
				Expect(params).To(ContainElement(" -TargetDirectory 'dir'"))
				Expect(params).To(ContainElement(" -ZipPackageFileName 'file.zip'"))
				Expect(params).To(ContainElement(" -Proxy http://proxy:8080"))
				Expect(params).To(ContainElement(" -ForOfflineInstallation"))
				Expect(params).To(ContainElement(" -CertificatePath 'signing.pfx'"))
				Expect(params).To(ContainElement(" -Password 'certpassword'"))
			})

			It("creates command with both offline installation and code signing", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "output")
				flags.Set(ZipPackageFileNameFlagName, "signed-offline-package.zip")
				flags.Set(ForOfflineInstallationFlagName, "true")
				flags.Set(CertificateFlagName, "C:\\certificates\\codesign.pfx")
				flags.Set(PasswordFlagName, "mysecretpassword")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1")))

				// Verify all expected parameters are present
				Expect(params).To(ContainElement(" -TargetDirectory 'output'"))
				Expect(params).To(ContainElement(" -ZipPackageFileName 'signed-offline-package.zip'"))
				Expect(params).To(ContainElement(" -ForOfflineInstallation"))
				Expect(params).To(ContainElement(" -CertificatePath 'C:\\certificates\\codesign.pfx'"))
				Expect(params).To(ContainElement(" -Password 'mysecretpassword'"))
			})

			It("does not include code signing parameters when not specified", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")

				// Explicitly ensure certificate and password flags are not set
				flags.Set(CertificateFlagName, "")
				flags.Set(PasswordFlagName, "")

				cmd, params, err := buildSystemPackageCmd(flags)
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "windows", "host", "system", "package", "New-K2sPackage.ps1")))

				// Verify no code signing parameters are included
				for _, param := range params {
					Expect(param).ToNot(ContainSubstring("CertificatePath"))
				}
			})
		})
	})

	Describe("buildNodePackageConfig", func() {
		It("passes node package options through the system provider configuration", func() {
			flags := pflag.NewFlagSet("node-package", pflag.ContinueOnError)
			flags.String(TargetDirectoryFlagName, "", "")
			flags.String(ZipPackageFileNameFlagName, "", "")
			flags.Bool(DeltaPackageFlagName, false, "")
			flags.String(PackageVersionFromFlagName, "", "")
			flags.String(PackageVersionToFlagName, "", "")
			flags.Bool(common.OutputFlagName, false, "")
			flags.Bool("include-gpu", false, "")
			flags.String("os", "", "")
			flags.String("arch", "amd64", "")
			flags.String(ProxyFlagName, "", "")
			_ = flags.Set(TargetDirectoryFlagName, "output")
			_ = flags.Set(ZipPackageFileNameFlagName, "node.zip")
			_ = flags.Set("os", "debian13")
			_ = flags.Set("arch", "arm64")
			_ = flags.Set("include-gpu", "true")
			_ = flags.Set(ProxyFlagName, "http://proxy:3128")

			cfg, err := buildNodePackageConfig(flags)
			Expect(err).ToNot(HaveOccurred())
			Expect(cfg.NodePackage).To(BeTrue())
			Expect(cfg.OutputDir).To(Equal("output"))
			Expect(cfg.PackageName).To(Equal("node.zip"))
			Expect(cfg.OS).To(Equal("debian13"))
			Expect(cfg.Architecture).To(Equal("arm64"))
			Expect(cfg.IncludeGPU).To(BeTrue())
			Expect(cfg.Proxy).To(Equal("http://proxy:3128"))
		})
	})

	Describe("ControlPlaneMemoryFlagUsage", func() {
		It("should contain 'minimum 2GB'", func() {
			Expect(ControlPlaneMemoryFlagUsage).To(ContainSubstring("minimum 2GB"))
		})
	})

	Describe("ControlPlaneDiskSizeFlagUsage", func() {
		It("should contain 'minimum 10GB'", func() {
			Expect(ControlPlaneDiskSizeFlagUsage).To(ContainSubstring("minimum 10GB"))
		})
	})
})
