// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package cephexportimport

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

func TestStorageCephExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Export/Import Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "storage-ceph", "export-import-ceph", "air-gapped", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "storage-ceph-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	addon = exportimport.GetAddonByName(allAddons, "storage")
	Expect(addon).NotTo(BeNil(), "storage addon should exist")

	impl = exportimport.GetImplementation(addon, "ceph")
	Expect(impl).NotTo(BeNil(), "ceph implementation should exist")

	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if suite.ShouldCleanup(testFailed) {
		exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
	}
	suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
	os.RemoveAll(exportPath)
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("storage ceph addon export and import", Ordered, func() {
	// This suite validates artifact lifecycle only (export -> cleanup -> import) and
	// does not require the storage/ceph addon to be enabled at any point.
	Describe("export storage ceph addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports storage ceph addon to versioned OCI tar file", func(ctx context.Context) {
			exportedOciFile = exportimport.ExportAddon(ctx, suite, "storage", "ceph", exportPath)
			info, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported OCI tar file should exist at %s", exportedOciFile)
			Expect(info.Size()).To(BeNumerically(">", 0))
		})

		It("contains storage ceph addon folder with correct OCI structure", func(ctx context.Context) {
			extractedArtifactsDir := exportimport.ExtractOciTar(ctx, suite, exportedOciFile, exportPath)
			expectedDirName := exportimport.GetExpectedDirName("storage", "ceph")
			exportimport.VerifyExportedOciStructure(extractedArtifactsDir, expectedDirName)
		})

		It("exports all addon resources", func(ctx context.Context) {
			exportimport.VerifyExportedImages(suite, exportPath, impl)
			exportimport.VerifyExportedPackages(exportPath, impl)
		})

		It("index.json contains proper OCI structure", func(ctx context.Context) {
			expectedDirName := exportimport.GetExpectedDirName("storage", "ceph")
			exportimport.VerifyOciManifest(exportPath, expectedDirName)
		})
	})

	Describe("clean up storage ceph resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("has no debian packages available before import", func(ctx context.Context) {
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import storage ceph addon", func() {
		var restoreProxyEnvironment func()

		BeforeAll(func(ctx context.Context) {
			restoreProxyEnvironment = exportimport.PrepareAirGappedAddonImport(ctx, suite, controlPlaneIpAddress)
			exportimport.ImportAddon(ctx, suite, exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "-f", "-o")
			if restoreProxyEnvironment != nil {
				restoreProxyEnvironment()
			}
			exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
		})

		It("has debian packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedDebPackages(ctx, suite, impl, controlPlaneIpAddress, "storage")
		})

		It("has linux curl packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedLinuxCurlPackages(ctx, suite, impl, controlPlaneIpAddress, "storage")
		})

		It("has windows curl packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedWindowsCurlPackages(suite, impl, "storage")
		})

		It("has expected addon files after import", func(ctx context.Context) {
			cephImplDir := filepath.Join(suite.RootDir(), "addons", "storage", "ceph")
			expectedFiles := []string{
				"Enable.ps1",
				"Disable.ps1",
				"Get-Status.ps1",
				"Backup.ps1",
				"Restore.ps1",
				"EnableForRestore.ps1",
				"README.md",
				"config/ceph-config.json",
				"config/ceph-config.json.license",
				"manifests/operator.yaml",
				"manifests/csi-rbac.yaml",
				"manifests/crds/ceph-crd.yaml",
				"manifests/smb-shared/base/csi-smb-controller.yaml",
				"manifests/smb-shared/base/csi-smb-node.yaml",
				"manifests/smb-shared/base/rbac-csi-smb.yaml",
				"manifests/smb-shared/base/storage-classes/template_StorageClass.yaml",
				"manifests/smb-shared/windows/csi-smb-node-windows-hp.yaml",
			}
			exportimport.VerifyImportedAddonFiles(cephImplDir, expectedFiles)
		})

		It("has no stray files at wrong addon paths after import", func(ctx context.Context) {
			storageBaseDir := filepath.Join(suite.RootDir(), "addons", "storage")
			unexpectedFiles := []string{
				filepath.Join(storageBaseDir, "config", "ceph-config.json"),
				filepath.Join(storageBaseDir, "config", "ceph-config.json.license"),
			}
			exportimport.VerifyNoStrayFiles(unexpectedFiles)
		})

		It("addon can be enabled while air-gapped", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ceph-csi-operator-controller-manager", "ceph-csi-operator-system")
		})

	})

	Describe("export and import with relative paths", func() {
		var (
			relExportDir    string
			absRelExportDir string
			relOciFile      string
		)

		BeforeAll(func(ctx context.Context) {
			absRelExportDir = filepath.Join(suite.RootDir(), "tmp", "storage-ceph-relpath-test")
			Expect(os.MkdirAll(absRelExportDir, 0o755)).To(Succeed())

			var err error
			relExportDir, err = filepath.Rel(suite.RootDir(), absRelExportDir)
			Expect(err).ToNot(HaveOccurred())
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(absRelExportDir, relOciFile)
		})

		It("exports addon using a relative directory path", func(ctx context.Context) {
			relOciFile = exportimport.ExportAddonRelativePath(ctx, suite, "storage", "ceph", suite.RootDir(), relExportDir)
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
			Expect(os.MkdirAll(subDir, 0o755)).To(Succeed())

			parentRelPath := ".." + string(filepath.Separator) + filepath.Base(files[0])
			exportimport.ImportAddonRelativePath(ctx, suite, subDir, parentRelPath)
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})
	})
})
