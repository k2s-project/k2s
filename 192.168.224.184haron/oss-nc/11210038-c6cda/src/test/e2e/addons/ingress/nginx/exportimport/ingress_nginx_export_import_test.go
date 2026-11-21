// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package nginxexportimport

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/test/e2e/addons/exportimport"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const exportImportTestTimeout = time.Minute * 30

var (
	suite                 *framework.K2sTestSuite
	k2s                   *dsl.K2s
	exportPath            string
	exportedOciFile       string
	controlPlaneIpAddress string
	addon                 *addons.Addon
	impl                  *addons.Implementation
	testFailed            = false
)

func TestIngressNginxExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress nginx Addon Export/Import Tests", Label("addon", "addon-communication", "acceptance", "internet-required", "setup-required", "invasive", "ingress-nginx", "export-import", "air-gapped", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("INGRESS NGINX EXPORT/IMPORT TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "ingress-nginx-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	GinkgoWriter.Printf("[Setup] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[Setup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Setup] Control plane IP: %s\n", controlPlaneIpAddress)

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	GinkgoWriter.Printf("[Setup] Total addons available: %d\n", len(allAddons))

	addon = exportimport.GetAddonByName(allAddons, "ingress")
	Expect(addon).NotTo(BeNil(), "ingress addon should exist")
	GinkgoWriter.Printf("[Setup] Found addon: %s\n", addon.Metadata.Name)

	impl = exportimport.GetImplementation(addon, "nginx")
	Expect(impl).NotTo(BeNil(), "nginx implementation should exist")
	GinkgoWriter.Printf("[Setup] Found implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Setup] Export directory name: %s\n", impl.ExportDirectoryName)

	exportimport.AssertWindowsCurlContains(impl, `bin\cmctl.exe`)

	k2s = dsl.NewK2s(suite)

	GinkgoWriter.Println("[Setup] Setup complete")
	GinkgoWriter.Println("========================================")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if suite.ShouldCleanup(testFailed) {
		exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
	}
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("ingress nginx addon export and import", Ordered, func() {
	Describe("export ingress nginx addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports ingress nginx addon to versioned OCI tar file", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: exports ingress nginx addon to versioned OCI tar file")
			exportedOciFile = exportimport.ExportAddon(ctx, suite, "ingress", "nginx", exportPath)

			GinkgoWriter.Printf("[Test] Verifying exported OCI tar file exists: %s\n", exportedOciFile)
			info, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported OCI tar file should exist at %s", exportedOciFile)
			GinkgoWriter.Printf("[Test] OCI tar file verified: %d bytes\n", info.Size())
		})

		It("contains ingress addon folder with correct OCI structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: contains ingress addon folder with correct OCI structure")
			extractedArtifactsDir := exportimport.ExtractOciTar(ctx, suite, exportedOciFile, exportPath)

			expectedDirName := exportimport.GetExpectedDirName("ingress", "nginx")
			GinkgoWriter.Printf("[Test] Expected directory name: %s\n", expectedDirName)
			exportimport.VerifyExportedOciStructure(extractedArtifactsDir, expectedDirName)
		})

		It("all resources have been exported", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported")
			extractedArtifactsDir := exportPath
			GinkgoWriter.Printf("[Test] Extracted artifacts dir: %s\n", extractedArtifactsDir)

			exportimport.VerifyExportedImages(suite, extractedArtifactsDir, impl)
			exportimport.VerifyExportedPackages(extractedArtifactsDir, impl)
		})

		It("index.json contains proper OCI structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: index.json contains proper OCI structure")
			expectedDirName := exportimport.GetExpectedDirName("ingress", "nginx")
			extractedArtifactsDir := exportPath
			GinkgoWriter.Printf("[Test] Extracted artifacts dir: %s\n", extractedArtifactsDir)

			exportimport.VerifyOciManifest(extractedArtifactsDir, expectedDirName)
		})
	})

	Describe("clean up ingress nginx resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("no debian packages available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no debian packages available before import")
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import ingress nginx addon", func() {
		var restoreProxyEnvironment func()

		BeforeAll(func(ctx context.Context) {
			restoreProxyEnvironment = exportimport.PrepareAirGappedAddonImport(ctx, suite, controlPlaneIpAddress)
			exportimport.ImportAddon(ctx, suite, exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			if restoreProxyEnvironment != nil {
				restoreProxyEnvironment()
			}
			exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
		})

		It("debian packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: debian packages available after import")
			exportimport.VerifyImportedDebPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("images available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: images available after import")
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})

		It("linux curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: linux curl packages available after import")
			exportimport.VerifyImportedLinuxCurlPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("windows curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: windows curl packages available after import")
			exportimport.VerifyImportedWindowsCurlPackages(suite, impl)
		})

		It("all addon files present at correct paths after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all addon files present at correct paths after import")
			nginxImplDir := filepath.Join(suite.RootDir(), "addons", "ingress", "nginx")
			GinkgoWriter.Printf("[Test] Nginx implementation directory: %s\n", nginxImplDir)

			expectedFiles := []string{
				"Enable.ps1",
				"Disable.ps1",
				"Get-Status.ps1",
				"Backup.ps1",
				"Restore.ps1",
				"Update.ps1",
				"README.md",
				"nginx.module.psm1",
			}
			exportimport.VerifyImportedAddonFiles(nginxImplDir, expectedFiles)
		})

		It("addon can be enabled while air-gapped", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: addon can be enabled while air-gapped")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		It("can be enabled when only addons/common and addons/ingress are present", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common and addons/ingress are present")

			GinkgoWriter.Println("[Test] Disabling ingress nginx to ensure clean re-enable path")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

			GinkgoWriter.Println("[Test] Staging addon isolation: keeping only common and ingress")
			restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "ingress")
			Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
			DeferCleanup(func() {
				Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
			})
			DeferCleanup(func() {
				_, _ = suite.K2sCli().Exec(context.Background(), "addons", "disable", "ingress", "nginx", "-o")
			})

			GinkgoWriter.Println("[Test] Enabling ingress nginx with isolated addons directory")
			output := suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")

			GinkgoWriter.Println("[Test] Verifying ingress-nginx-controller deployment is available")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

			GinkgoWriter.Println("[Test] Verifying no PowerShell module-not-found signatures in output")
			Expect(output).NotTo(ContainSubstring("no valid module file was found"), "enable output must not contain PowerShell module-not-found error")
			Expect(output).NotTo(ContainSubstring("was not loaded"), "enable output must not contain PowerShell module-not-loaded error")
		})
	})

	Describe("export and import with relative paths", func() {
		var (
			relExportDir    string
			absRelExportDir string
			relOciFile      string
		)

		BeforeAll(func(ctx context.Context) {
			absRelExportDir = filepath.Join(suite.RootDir(), "tmp", "ingress-nginx-relpath-test")
			os.MkdirAll(absRelExportDir, 0o755)
			var err error
			relExportDir, err = filepath.Rel(suite.RootDir(), absRelExportDir)
			Expect(err).ToNot(HaveOccurred())
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(absRelExportDir, relOciFile)
		})

		It("exports addon using a relative directory path", func(ctx context.Context) {
			relOciFile = exportimport.ExportAddonRelativePath(ctx, suite, "ingress", "nginx", suite.RootDir(), relExportDir)
			info, err := os.Stat(relOciFile)
			Expect(err).ToNot(HaveOccurred())
			Expect(info.Size()).To(BeNumerically(">", 0))
		})

		It("imports addon using a relative file path", func(ctx context.Context) {
			Expect(relOciFile).NotTo(BeEmpty())
			relFilePath, err := filepath.Rel(suite.RootDir(), relOciFile)
			Expect(err).ToNot(HaveOccurred())
			exportimport.ImportAddonRelativePath(ctx, suite, suite.RootDir(), relFilePath)
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})

		It("imports addon using a parent-relative file path", func(ctx context.Context) {
			files, err := filepath.Glob(filepath.Join(absRelExportDir, "*.oci.tar"))
			Expect(err).ToNot(HaveOccurred())
			Expect(len(files)).To(BeNumerically(">=", 1))
			subDir := filepath.Join(absRelExportDir, "subdir")
			os.MkdirAll(subDir, 0o755)
			parentRelPath := ".." + string(filepath.Separator) + filepath.Base(files[0])
			exportimport.ImportAddonRelativePath(ctx, suite, subDir, parentRelPath)
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})
	})
})
