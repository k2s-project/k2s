// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package securityexportimport

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
	suite                   *framework.K2sTestSuite
	k2s                     *dsl.K2s
	exportPath              string
	exportedOciFile         string
	exportedOciFileChecksum string
	controlPlaneIpAddress   string
	addon                   *addons.Addon
	impl                    *addons.Implementation
	testFailed              = false
)

func TestSecurityExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Export/Import Tests", Label("addon", "addon-security", "acceptance", "internet-required", "setup-required", "invasive", "security", "export-import", "air-gapped", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("SECURITY EXPORT/IMPORT TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "security-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	GinkgoWriter.Printf("[Setup] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[Setup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Setup] Control plane IP: %s\n", controlPlaneIpAddress)

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	GinkgoWriter.Printf("[Setup] Total addons available: %d\n", len(allAddons))

	addon = exportimport.GetAddonByName(allAddons, "security")
	Expect(addon).NotTo(BeNil(), "security addon should exist")
	GinkgoWriter.Printf("[Setup] Found addon: %s\n", addon.Metadata.Name)

	impl = exportimport.GetImplementation(addon, "security")
	Expect(impl).NotTo(BeNil(), "security implementation should exist")
	GinkgoWriter.Printf("[Setup] Found implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Setup] Export directory name: %s\n", impl.ExportDirectoryName)

	GinkgoWriter.Printf("[Setup] Windows curl packages in security metadata: %d\n", len(impl.OfflineUsage.WindowsResources.CurlPackages))
	exportimport.AssertWindowsCurlContains(impl, `bin\cmctl.exe`)
	exportimport.AssertWindowsCurlContains(impl, `bin\kyverno.exe`)
	exportimport.AssertWindowsCurlContains(impl, `bin\linkerd.exe`)

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

var _ = Describe("security addon export and import", Ordered, func() {
	Describe("export security addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports security addon to versioned OCI tar file", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: exports security addon to versioned OCI tar file")
			exportedOciFile = exportimport.ExportAddon(ctx, suite, "security", "", exportPath)

			GinkgoWriter.Printf("[Test] Verifying exported OCI tar file exists: %s\n", exportedOciFile)
			info, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported OCI tar file should exist at %s", exportedOciFile)
			GinkgoWriter.Printf("[Test] OCI tar file verified: %d bytes\n", info.Size())

			// Baseline for the artifact immutability check of the '--omit' block below.
			exportedOciFileChecksum = exportimport.Sha256OfFile(exportedOciFile)
		})

		It("contains security addon folder with correct OCI structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: contains security addon folder with correct OCI structure")
			extractedArtifactsDir := exportimport.ExtractOciTar(ctx, suite, exportedOciFile, exportPath)

			expectedDirName := exportimport.GetExpectedDirName("security", "security")
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
			expectedDirName := exportimport.GetExpectedDirName("security", "security")
			extractedArtifactsDir := exportPath
			GinkgoWriter.Printf("[Test] Extracted artifacts dir: %s\n", extractedArtifactsDir)

			exportimport.VerifyOciManifest(extractedArtifactsDir, expectedDirName)
		})
	})

	Describe("clean up security resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("no debian packages available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no debian packages available before import")
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	// Guards the selective image import of 'k2s addons import --omit' for an addon that declares
	// several omit options.
	//
	// The block runs between the clean-up and the full import on purpose: it reuses the artifact
	// exported above plus the empty image state established by the previous block, and restores
	// that empty state afterwards so the subsequent full import behaves exactly as before.
	Describe("import security addon while omitting the images of omitted functionality", func() {
		const (
			omitKeycloakFlag    = "omitKeycloak"
			omitOAuth2ProxyFlag = "omitOAuth2Proxy"
		)

		var (
			keycloakImages    []string
			oauth2ProxyImages []string
			remainingImages   []string
			imagesBeforeOmit  []string
		)

		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== IMPORT SECURITY WITH --omit - BeforeAll START ===")

			// The expected images are resolved from the shipped manifests, so an image version
			// bump does not require a test change.
			keycloakImages = k2s.FilterOutK8sImages(suite.AddonsAdditionalInfo().GetOmittedImagesForFlag(*impl, omitKeycloakFlag))
			oauth2ProxyImages = k2s.FilterOutK8sImages(suite.AddonsAdditionalInfo().GetOmittedImagesForFlag(*impl, omitOAuth2ProxyFlag))
			Expect(keycloakImages).NotTo(BeEmpty(), "'--%s' must resolve to at least one image", omitKeycloakFlag)
			Expect(oauth2ProxyImages).NotTo(BeEmpty(), "'--%s' must resolve to at least one image", omitOAuth2ProxyFlag)

			allImages, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
			Expect(err).ToNot(HaveOccurred())
			remainingImages = k2s.FilterOutK8sImages(exportimport.ImagesExcept(allImages, keycloakImages, oauth2ProxyImages))
			Expect(remainingImages).NotTo(BeEmpty(), "security must ship images besides the omittable ones")

			GinkgoWriter.Printf("[BeforeAll] --%s images: %v\n", omitKeycloakFlag, keycloakImages)
			GinkgoWriter.Printf("[BeforeAll] --%s images: %v\n", omitOAuth2ProxyFlag, oauth2ProxyImages)
			GinkgoWriter.Printf("[BeforeAll] remaining security images: %d\n", len(remainingImages))

			exportimport.ImportAddonsWithOmit(ctx, suite, exportedOciFile,
				[]string{"security"}, []string{omitKeycloakFlag, omitOAuth2ProxyFlag})

			GinkgoWriter.Println("=== IMPORT SECURITY WITH --omit - BeforeAll END ===")
		}, NodeTimeout(exportImportTestTimeout))

		AfterAll(func(ctx context.Context) {
			// Restore the precondition of the subsequent full-import block.
			exportimport.RemoveAllAddonImages(ctx, suite, k2s)
		})

		It("does not import the images of the omitted functionality", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: images of all requested omit options are skipped")
			exportimport.VerifyImagesAbsentFromNodes(ctx, k2s, keycloakImages, "omitted via --omit "+omitKeycloakFlag)
			exportimport.VerifyImagesAbsentFromNodes(ctx, k2s, oauth2ProxyImages, "omitted via --omit "+omitOAuth2ProxyFlag)
		})

		It("imports all images that are not covered by the requested omit options", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: images unrelated to the omit options are imported")
			exportimport.VerifyImagesPresentOnNodes(ctx, k2s, remainingImages, "not covered by the requested omit options")
		})

		It("restores the skipped images when the same artifact is imported again without omit options", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: re-importing the same artifact without --omit restores the skipped images")

			exportimport.VerifyImagesAbsentFromNodes(ctx, k2s, keycloakImages, "still skipped from the previous import")

			// Deliberately the very same artifact - nothing is re-exported in between.
			exportimport.ImportAddon(ctx, suite, exportedOciFile)

			exportimport.VerifyImagesPresentOnNodes(ctx, k2s, keycloakImages, "restored by the re-import without --omit")
			exportimport.VerifyImagesPresentOnNodes(ctx, k2s, oauth2ProxyImages, "restored by the re-import without --omit")
		}, NodeTimeout(exportImportTestTimeout))

		It("never removes images that are already present locally", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: omitting an already present image does not delete it")

			imagesBeforeOmit = k2s.GetNonK8sImagesFromNodes(ctx)
			Expect(imagesBeforeOmit).NotTo(BeEmpty(), "the previous re-import must have populated the nodes")
			GinkgoWriter.Printf("[Test] Images on nodes before the omitted import: %d\n", len(imagesBeforeOmit))

			exportimport.ImportAddonsWithOmit(ctx, suite, exportedOciFile, []string{"security"}, []string{omitKeycloakFlag})

			// Skipping an image means "do not import it", never "delete it from the runtime".
			exportimport.VerifyImagesPresentOnNodes(ctx, k2s, keycloakImages, "already present locally before the omitted import")

			imagesAfterOmit := k2s.GetNonK8sImagesFromNodes(ctx)
			GinkgoWriter.Printf("[Test] Images on nodes after the omitted import: %d\n", len(imagesAfterOmit))
			for _, image := range imagesBeforeOmit {
				Expect(imagesAfterOmit).To(ContainElement(image), "image '%s' must not be removed by an import using --omit", image)
			}
		}, NodeTimeout(exportImportTestTimeout))

		It("leaves the OCI artifact unchanged", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: the OCI artifact is not modified by --omit")
			Expect(exportimport.Sha256OfFile(exportedOciFile)).To(Equal(exportedOciFileChecksum),
				"'--omit' must not modify, shrink or repack the OCI artifact")
		})
	})

	Describe("import security addon", func() {

		var restoreProxyEnvironment func()

		BeforeAll(func(ctx context.Context) {
			restoreProxyEnvironment = exportimport.PrepareAirGappedAddonImport(ctx, suite, controlPlaneIpAddress)
			exportimport.ImportAddon(ctx, suite, exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			_, _ = suite.K2sCli().Exec(ctx, "addons", "disable", "security", "-o")

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
			securityImplDir := filepath.Join(suite.RootDir(), "addons", "security")
			GinkgoWriter.Printf("[Test] Security implementation directory: %s\n", securityImplDir)

			expectedFiles := []string{
				"Enable.ps1",
				"Disable.ps1",
				"Get-Status.ps1",
				"Update.ps1",
				"README.md",
				"security.module.psm1",
			}
			exportimport.VerifyImportedAddonFiles(securityImplDir, expectedFiles)
		})

		It("can be enabled when only addons/common, addons/security, and addons/ingress are present", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: can be enabled when only addons/common, addons/security, and addons/ingress are present")

			// Security defaults to nginx ingress and auto-enables ingress when no controller is present,
			// so the isolation test must keep the ingress addon available as well.
			restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "security", "ingress")
			Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
			DeferCleanup(func() {
				Expect(restore()).To(Succeed(), "addon isolation restore must succeed to avoid a partial workspace state")
			})
			DeferCleanup(func() {
				_, _ = suite.K2sCli().Exec(context.Background(), "addons", "disable", "security", "-o")
				_, _ = suite.K2sCli().Exec(context.Background(), "addons", "disable", "ingress", "nginx", "-o")
			})

			// Enable security with isolated addons directory
			output := suite.K2sCli().MustExec(ctx, "addons", "enable", "security", "-o")

			// Assert no PowerShell module-not-found errors
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
			absRelExportDir = filepath.Join(suite.RootDir(), "tmp", "security-relpath-test")
			os.MkdirAll(absRelExportDir, 0o755)
			var err error
			relExportDir, err = filepath.Rel(suite.RootDir(), absRelExportDir)
			Expect(err).ToNot(HaveOccurred())
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(absRelExportDir, relOciFile)
		})

		It("exports addon using a relative directory path", func(ctx context.Context) {
			relOciFile = exportimport.ExportAddonRelativePath(ctx, suite, "security", "security", suite.RootDir(), relExportDir)
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
