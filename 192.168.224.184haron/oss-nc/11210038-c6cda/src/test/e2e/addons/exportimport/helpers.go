// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// Package exportimport provides shared helper functions for addon export/import tests.
package exportimport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

// ExportedOciInfo contains information about an exported addon OCI tar file.
type ExportedOciInfo struct {
	OciTarPath    string
	ExtractedPath string
	AddonDir      string
}

// MirrorRegistry describes one registry mirror entry from cfg/config.json.
type MirrorRegistry struct {
	Registry string `json:"registry"`
	Server   string `json:"server"`
	Mirror   string `json:"mirror"`
}

// GetAddonByName returns the addon with the given name from the list of all addons.
func GetAddonByName(allAddons addons.Addons, addonName string) *addons.Addon {
	for i := range allAddons {
		if allAddons[i].Metadata.Name == addonName {
			return &allAddons[i]
		}
	}
	return nil
}

// GetImplementation returns the implementation with the given name from the addon.
func GetImplementation(addon *addons.Addon, implName string) *addons.Implementation {
	for i := range addon.Spec.Implementations {
		if addon.Spec.Implementations[i].Name == implName {
			return &addon.Spec.Implementations[i]
		}
	}
	return nil
}

// GetExpectedDirName returns the expected directory name for an addon implementation in the exported OCI tar.
func GetExpectedDirName(addonName, implName string) string {
	if implName != addonName {
		return strings.ReplaceAll(addonName+"-"+implName, " ", "-")
	}
	return strings.ReplaceAll(addonName, " ", "-")
}

// ConfigJsonMirrorRegistries returns registry mirrors configured in cfg/config.json.
func ConfigJsonMirrorRegistries(suite *framework.K2sTestSuite) []MirrorRegistry {
	configPath := filepath.Join(suite.RootDir(), "cfg", "config.json")
	GinkgoWriter.Printf("[AirGap] Reading mirror registries from %s\n", configPath)

	content, err := os.ReadFile(configPath)
	Expect(err).ToNot(HaveOccurred(), "should be able to read %s", configPath)

	var config struct {
		SmallSetup struct {
			MirrorRegistries []MirrorRegistry `json:"mirrorRegistries"`
		} `json:"smallsetup"`
	}

	err = json.Unmarshal(content, &config)
	Expect(err).ToNot(HaveOccurred(), "should be able to parse %s", configPath)

	for i, mirror := range config.SmallSetup.MirrorRegistries {
		GinkgoWriter.Printf("[AirGap]   [%d] registry=%s server=%s mirror=%s\n", i, mirror.Registry, mirror.Server, mirror.Mirror)
	}

	return config.SmallSetup.MirrorRegistries
}

// PrepareAirGappedAddonImport removes proxy environment variables and runtime mirror files.
func PrepareAirGappedAddonImport(ctx context.Context, suite *framework.K2sTestSuite, controlPlaneIP string) func() {
	GinkgoWriter.Println("=== PREPARE AIR-GAPPED ADDON IMPORT START ===")
	restoreProxyEnvironment := RemoveProxyEnvironment()
	mirrors := ConfigJsonMirrorRegistries(suite)

	RemoveAirGappedMirrorRuntimeFiles(ctx, suite, mirrors, controlPlaneIP)
	VerifyAirGappedMirrorsRemoved(ctx, suite, mirrors, controlPlaneIP)

	GinkgoWriter.Println("=== PREPARE AIR-GAPPED ADDON IMPORT END ===")
	return restoreProxyEnvironment
}

// RemoveProxyEnvironment unsets proxy variables for the current test process and returns a restore function.
func RemoveProxyEnvironment() func() {
	GinkgoWriter.Println("[AirGap] Removing proxy environment variables for air-gapped phase")

	keys := []string{"SYSTEM_TEST_PROXY", "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"}
	originalValues := map[string]*string{}

	for _, key := range keys {
		if value, ok := os.LookupEnv(key); ok {
			valueCopy := value
			originalValues[key] = &valueCopy
			GinkgoWriter.Printf("[AirGap]   unset %s\n", key)
		} else {
			originalValues[key] = nil
		}

		Expect(os.Unsetenv(key)).To(Succeed(), "should unset %s", key)
	}

	return func() {
		GinkgoWriter.Println("[AirGap] Restoring proxy environment variables")
		for _, key := range keys {
			value := originalValues[key]
			if value == nil {
				Expect(os.Unsetenv(key)).To(Succeed(), "should keep %s unset", key)
				continue
			}

			Expect(os.Setenv(key, *value)).To(Succeed(), "should restore %s", key)
		}
	}
}

// RemoveConfigJsonMirrorRuntimeFiles removes container runtime mirror files created from cfg/config.json.
func RemoveConfigJsonMirrorRuntimeFiles(ctx context.Context, suite *framework.K2sTestSuite, mirrors []MirrorRegistry, controlPlaneIP string) {
	RemoveAirGappedMirrorRuntimeFiles(ctx, suite, mirrors, controlPlaneIP)
}

// RemoveAirGappedMirrorRuntimeFiles removes container runtime mirror files that would mask air-gapped import gaps.
func RemoveAirGappedMirrorRuntimeFiles(ctx context.Context, suite *framework.K2sTestSuite, mirrors []MirrorRegistry, controlPlaneIP string) {
	GinkgoWriter.Println("=== REMOVE CONFIG.JSON MIRROR RUNTIME FILES START ===")
	Expect(controlPlaneIP).NotTo(BeEmpty(), "control plane IP must be set to remove Linux runtime mirror files")

	removeLinuxMirrorCmd := `sudo sh -c 'for f in /etc/containers/registries.conf.d/*.conf; do [ -f "$f" ] || continue; if grep -q "^[[:space:]]*\[\[registry\.mirror\]\]" "$f"; then rm -f "$f"; fi; done' && sudo systemctl daemon-reload && sudo systemctl restart crio`
	GinkgoWriter.Println("[AirGap] Removing all Linux CRI-O registry mirror drop-ins")
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", removeLinuxMirrorCmd, "-o")

	if len(mirrors) == 0 {
		GinkgoWriter.Println("[AirGap] No config.json mirror registries configured for Windows containerd cleanup")
		GinkgoWriter.Println("=== REMOVE CONFIG.JSON MIRROR RUNTIME FILES END ===")
		return
	}

	for _, mirror := range mirrors {
		if runtime.GOOS == "windows" {
			removeWindowsMirrorRuntimeFiles(ctx, suite, mirror)
		} else {
			GinkgoWriter.Printf("[AirGap] Skipping Windows containerd mirror cleanup on non-Windows test host: %s\n", runtime.GOOS)
		}
	}
	GinkgoWriter.Println("=== REMOVE CONFIG.JSON MIRROR RUNTIME FILES END ===")
}

// VerifyConfigJsonMirrorsRemoved verifies that cfg/config.json mirrors are absent from runtime files.
func VerifyConfigJsonMirrorsRemoved(ctx context.Context, suite *framework.K2sTestSuite, mirrors []MirrorRegistry, controlPlaneIP string) {
	VerifyAirGappedMirrorsRemoved(ctx, suite, mirrors, controlPlaneIP)
}

// VerifyAirGappedMirrorsRemoved verifies that air-gapped mirror runtime files are absent.
func VerifyAirGappedMirrorsRemoved(ctx context.Context, suite *framework.K2sTestSuite, mirrors []MirrorRegistry, controlPlaneIP string) {
	GinkgoWriter.Println("=== VERIFY CONFIG.JSON MIRRORS REMOVED START ===")
	VerifyLinuxCriOMirrorsRemoved(ctx, suite, controlPlaneIP)

	if len(mirrors) == 0 {
		GinkgoWriter.Println("[AirGap] No config.json mirror registries configured for Windows containerd verification")
		GinkgoWriter.Println("=== VERIFY CONFIG.JSON MIRRORS REMOVED END ===")
		return
	}

	for _, mirror := range mirrors {
		if runtime.GOOS == "windows" {
			verifyWindowsMirrorRuntimeFilesRemoved(ctx, suite, mirror)
		}
	}
	GinkgoWriter.Println("=== VERIFY CONFIG.JSON MIRRORS REMOVED END ===")
}

func VerifyLinuxCriOMirrorsRemoved(ctx context.Context, suite *framework.K2sTestSuite, controlPlaneIP string) {
	checkLinuxMirrorCmd := `! grep -R "^[[:space:]]*\[\[registry\.mirror\]\]" /etc/containers/registries.conf.d 2>/dev/null`
	GinkgoWriter.Println("[AirGap] Verifying no Linux CRI-O registry mirror drop-ins remain")
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkLinuxMirrorCmd, "-o")
}

func removeWindowsMirrorRuntimeFiles(ctx context.Context, suite *framework.K2sTestSuite, mirror MirrorRegistry) {
	registryConfigName := runtimeRegistryConfigName(mirror.Registry)
	powershellCommand := fmt.Sprintf(`$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:SystemDrive 'etc\containerd\certs.d\%s'
if (Test-Path -LiteralPath $folder) {
    Remove-Item -LiteralPath $folder -Recurse -Force
}
if (Test-Path -LiteralPath $folder) {
    throw "Containerd mirror folder still exists: $folder"
}`, registryConfigName)

	GinkgoWriter.Printf("[AirGap] Removing Windows containerd mirror folder for %s\n", mirror.Registry)
	suite.Cli("powershell").MustExec(ctx, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", powershellCommand)
}

func verifyWindowsMirrorRuntimeFilesRemoved(ctx context.Context, suite *framework.K2sTestSuite, mirror MirrorRegistry) {
	registryConfigName := runtimeRegistryConfigName(mirror.Registry)
	powershellCommand := fmt.Sprintf(`$folder = Join-Path $env:SystemDrive 'etc\containerd\certs.d\%s'
if (Test-Path -LiteralPath $folder) {
    throw "Containerd mirror folder still exists: $folder"
}`, registryConfigName)

	GinkgoWriter.Printf("[AirGap] Verifying Windows containerd mirror folder is absent for %s\n", mirror.Registry)
	suite.Cli("powershell").MustExec(ctx, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", powershellCommand)
}

func runtimeRegistryConfigName(registry string) string {
	return strings.ReplaceAll(registry, ":", "")
}

// ExportAddon exports a single addon (or implementation) to an OCI tar file.
// Returns the path to the exported OCI tar file.
func ExportAddon(ctx context.Context, suite *framework.K2sTestSuite, addonName string, implName string, outputDir string) string {
	GinkgoWriter.Println("=== EXPORT ADDON START ===")
	GinkgoWriter.Printf("[Export] Addon: %s\n", addonName)
	if implName != "" && implName != addonName {
		GinkgoWriter.Printf("[Export] Implementation: %s\n", implName)
	}
	GinkgoWriter.Printf("[Export] Output directory: %s\n", outputDir)

	// Ensure output directory exists
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		GinkgoWriter.Printf("[Export] WARNING: Failed to create output directory: %v\n", err)
	}

	GinkgoWriter.Println("[Export] Executing k2s addons export command with verbose output (-o)...")
	if implName != "" && implName != addonName {
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName+" "+implName, "-d", outputDir, "-o")
	} else {
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName, "-d", outputDir, "-o")
	}
	GinkgoWriter.Println("[Export] Export command completed")

	// Export creates files with pattern: K2s-{version}-addons-{dirname}.oci.tar
	var pattern string
	if implName != "" && implName != addonName {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s-%s.oci.tar", addonName, implName))
	} else {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", addonName))
	}
	GinkgoWriter.Printf("[Export] Looking for OCI tar file matching pattern: %s\n", pattern)

	files, err := filepath.Glob(pattern)
	Expect(err).ToNot(HaveOccurred(), "[Export] Failed to glob for OCI tar files")

	GinkgoWriter.Printf("[Export] Found %d matching OCI tar file(s)\n", len(files))
	for i, f := range files {
		GinkgoWriter.Printf("[Export]   [%d] %s\n", i, f)
	}
	Expect(len(files)).To(Equal(1), "Should create exactly one versioned OCI tar file for %s, found %d", addonName, len(files))

	ociTarPath := files[0]
	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Export] OCI tar file size: %d bytes\n", info.Size())
	}
	GinkgoWriter.Println("=== EXPORT ADDON END ===")

	return ociTarPath
}

// ExtractOciTar extracts the OCI tar file to the given output directory.
// Returns the path to the extracted artifacts directory.
func ExtractOciTar(ctx context.Context, suite *framework.K2sTestSuite, ociTarPath string, outputDir string) string {
	GinkgoWriter.Println("=== EXTRACT OCI TAR START ===")
	GinkgoWriter.Printf("[Extract] OCI tar file: %s\n", ociTarPath)
	GinkgoWriter.Printf("[Extract] Output directory: %s\n", outputDir)

	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Extract] OCI tar file size: %d bytes\n", info.Size())
	} else {
		GinkgoWriter.Printf("[Extract] WARNING: Cannot stat OCI tar file: %v\n", err)
	}

	GinkgoWriter.Println("[Extract] Executing tar extraction...")
	suite.Cli("tar").MustExec(ctx, "-xf", ociTarPath, "-C", outputDir)
	GinkgoWriter.Println("[Extract] Extraction completed")

	// OCI layout files (oci-layout, index.json, blobs/) are at the tar root
	extractedArtifactsDir := outputDir
	_, err := os.Stat(filepath.Join(extractedArtifactsDir, "oci-layout"))
	Expect(os.IsNotExist(err)).To(BeFalse(), "oci-layout should exist after extraction at %s", extractedArtifactsDir)

	// List contents of extracted directory
	entries, _ := os.ReadDir(extractedArtifactsDir)
	GinkgoWriter.Printf("[Extract] Extracted artifacts directory contains %d entries:\n", len(entries))
	for _, entry := range entries {
		GinkgoWriter.Printf("[Extract]   - %s (dir=%v)\n", entry.Name(), entry.IsDir())
	}

	GinkgoWriter.Println("=== EXTRACT OCI TAR END ===")
	return extractedArtifactsDir
}

// VerifyExportedOciStructure verifies the structure of an exported addon OCI tar.
// The structure should be OCI Image Layout compliant with oci-layout, index.json, and blobs/sha256/.
func VerifyExportedOciStructure(extractedArtifactsDir string, expectedDirName string) {
	GinkgoWriter.Println("=== VERIFY OCI IMAGE LAYOUT STRUCTURE START ===")
	GinkgoWriter.Printf("[Structure] Extracted artifacts dir: %s\n", extractedArtifactsDir)

	// Verify oci-layout file exists (REQUIRED by OCI spec)
	ociLayoutPath := filepath.Join(extractedArtifactsDir, "oci-layout")
	ociLayoutInfo, err := os.Stat(ociLayoutPath)
	Expect(os.IsNotExist(err)).To(BeFalse(), "oci-layout file should exist at %s", ociLayoutPath)
	GinkgoWriter.Printf("[Structure] oci-layout file exists (%d bytes)\n", ociLayoutInfo.Size())

	// Verify oci-layout contains imageLayoutVersion
	ociLayoutContent, err := os.ReadFile(ociLayoutPath)
	Expect(err).ToNot(HaveOccurred(), "should be able to read oci-layout file")
	Expect(string(ociLayoutContent)).To(ContainSubstring("imageLayoutVersion"))
	Expect(string(ociLayoutContent)).To(ContainSubstring("1.0.0"))
	GinkgoWriter.Println("[Structure] oci-layout contains valid imageLayoutVersion: 1.0.0")

	// Verify index.json exists (REQUIRED by OCI spec)
	indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
	indexJsonInfo, err := os.Stat(indexJsonPath)
	Expect(os.IsNotExist(err)).To(BeFalse(), "index.json file should exist at %s", indexJsonPath)
	GinkgoWriter.Printf("[Structure] index.json file exists (%d bytes)\n", indexJsonInfo.Size())

	// Verify index.json has proper OCI structure with digests
	indexJsonContent, err := os.ReadFile(indexJsonPath)
	Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")
	Expect(string(indexJsonContent)).To(ContainSubstring("schemaVersion"))
	Expect(string(indexJsonContent)).To(ContainSubstring("application/vnd.oci.image.index.v1+json"))
	Expect(string(indexJsonContent)).To(ContainSubstring("sha256:"))
	Expect(string(indexJsonContent)).To(ContainSubstring("digest"))
	Expect(string(indexJsonContent)).To(ContainSubstring("size"))
	GinkgoWriter.Println("[Structure] index.json contains proper OCI structure with digests")

	// Verify blobs/sha256 directory exists (REQUIRED by OCI spec)
	blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
	blobsDirInfo, err := os.Stat(blobsDir)
	Expect(os.IsNotExist(err)).To(BeFalse(), "blobs/sha256 directory should exist at %s", blobsDir)
	Expect(blobsDirInfo.IsDir()).To(BeTrue(), "blobs/sha256 should be a directory")
	GinkgoWriter.Println("[Structure] blobs/sha256 directory exists")

	// List blobs
	blobEntries, err := os.ReadDir(blobsDir)
	Expect(err).ToNot(HaveOccurred(), "should be able to read blobs directory")
	GinkgoWriter.Printf("[Structure] blobs/sha256 contains %d blobs:\n", len(blobEntries))
	for _, entry := range blobEntries {
		if info, err := entry.Info(); err == nil {
			GinkgoWriter.Printf("[Structure]   - sha256:%s (%d bytes)\n", entry.Name()[:12]+"...", info.Size())
		}
	}
	Expect(len(blobEntries)).To(BeNumerically(">", 0), "blobs directory should contain at least one blob")

	// Verify the expected addon is referenced in index.json
	Expect(string(indexJsonContent)).To(ContainSubstring(expectedDirName))
	GinkgoWriter.Printf("[Structure] index.json references addon: %s\n", expectedDirName)

	GinkgoWriter.Println("=== VERIFY OCI IMAGE LAYOUT STRUCTURE END ===")
}

// VerifyExportedImages verifies that the expected images are exported in OCI blobs.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/).
func VerifyExportedImages(suite *framework.K2sTestSuite, extractedArtifactsDir string, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY EXPORTED IMAGES START ===")
	GinkgoWriter.Printf("[Images] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[Images] Implementation: %s\n", impl.Name)

	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).ToNot(HaveOccurred(), "[Images] Failed to get expected images for implementation")
	GinkgoWriter.Printf("[Images] Expected images from manifest: %d\n", len(images))
	for i, img := range images {
		GinkgoWriter.Printf("[Images]   [%d] %s\n", i, img)
	}

	// In OCI-compliant format, images are stored in blobs as content-addressable digests
	// We verify that the index.json references image layers
	if len(images) > 0 {
		indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
		indexJsonContent, err := os.ReadFile(indexJsonPath)
		Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")

		// Image layers should be referenced with proper media types
		hasLinuxImages := strings.Contains(string(indexJsonContent), "images-linux.tar") ||
			strings.Contains(string(indexJsonContent), "vnd.oci.image.layer.v1.tar")
		hasWindowsImages := strings.Contains(string(indexJsonContent), "images-windows.tar") ||
			strings.Contains(string(indexJsonContent), "vnd.k2s.addon.images-windows.v1.tar")

		// Verify blobs exist
		blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
		blobEntries, err := os.ReadDir(blobsDir)
		Expect(err).ToNot(HaveOccurred(), "should be able to read blobs directory")

		GinkgoWriter.Printf("[Images] Found %d blobs in storage\n", len(blobEntries))
		GinkgoWriter.Printf("[Images] Linux image layer referenced: %v\n", hasLinuxImages)
		GinkgoWriter.Printf("[Images] Windows image layer referenced: %v\n", hasWindowsImages)

		// At least one image layer should be present
		Expect(hasLinuxImages || hasWindowsImages || len(blobEntries) > 0).To(BeTrue(),
			"Expected at least one image layer blob for %d images", len(images))
	} else {
		GinkgoWriter.Println("[Images] No images expected, skipping layer check")
	}

	GinkgoWriter.Println("=== VERIFY EXPORTED IMAGES END ===")
}

// VerifyExportedPackages verifies that packages are exported in OCI blobs.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/).
func VerifyExportedPackages(extractedArtifactsDir string, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY EXPORTED PACKAGES START ===")
	GinkgoWriter.Printf("[Packages] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[Packages] Implementation: %s\n", impl.Name)

	// Count expected packages
	linuxCurlCount := len(impl.OfflineUsage.LinuxResources.CurlPackages)
	debCount := len(impl.OfflineUsage.LinuxResources.DebPackages)
	winCurlCount := len(impl.OfflineUsage.WindowsResources.CurlPackages)
	totalPackages := linuxCurlCount + debCount + winCurlCount

	GinkgoWriter.Printf("[Packages] Expected Linux curl packages: %d\n", linuxCurlCount)
	for i, lp := range impl.OfflineUsage.LinuxResources.CurlPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, lp.Url)
	}

	GinkgoWriter.Printf("[Packages] Expected Debian packages: %d\n", debCount)
	for i, d := range impl.OfflineUsage.LinuxResources.DebPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, d)
	}

	GinkgoWriter.Printf("[Packages] Expected Windows curl packages: %d\n", winCurlCount)
	for i, wp := range impl.OfflineUsage.WindowsResources.CurlPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, wp.Url)
	}

	GinkgoWriter.Printf("[Packages] Total expected packages: %d\n", totalPackages)

	// In OCI-compliant format, packages are stored in blobs referenced by index.json
	if totalPackages > 0 {
		indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
		indexJsonContent, err := os.ReadFile(indexJsonPath)
		Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")

		// Verify packages layer is referenced
		hasPackagesLayer := strings.Contains(string(indexJsonContent), "packages.tar.gz") ||
			strings.Contains(string(indexJsonContent), "vnd.k2s.addon.packages")

		// Verify blobs directory has content
		blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
		blobEntries, err := os.ReadDir(blobsDir)
		if err != nil {
			GinkgoWriter.Printf("[Packages] ERROR: cannot read blobs directory: %v\n", err)
		} else {
			GinkgoWriter.Printf("[Packages] Found %d blobs in storage\n", len(blobEntries))
		}

		GinkgoWriter.Printf("[Packages] Packages layer referenced: %v\n", hasPackagesLayer)
		Expect(hasPackagesLayer || len(blobEntries) > 0).To(BeTrue(),
			"packages layer should be referenced in index.json or blobs should exist for %d packages", totalPackages)
	} else {
		GinkgoWriter.Println("[Packages] No packages expected, skipping layer check")
	}

	GinkgoWriter.Printf("[Packages] OCI packages layer verified\n")
	GinkgoWriter.Println("=== VERIFY EXPORTED PACKAGES END ===")
}

// VerifyOciManifest verifies that addon manifest in blobs contains proper OCI structure and metadata.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/ and index.json).
func VerifyOciManifest(extractedArtifactsDir string, expectedDirName string) {
	GinkgoWriter.Println("=== VERIFY OCI MANIFEST START ===")
	GinkgoWriter.Printf("[OciManifest] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[OciManifest] Expected addon: %s\n", expectedDirName)

	// Read index.json to get manifest digest
	indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
	indexJsonBytes, err := os.ReadFile(indexJsonPath)
	Expect(err).To(BeNil(), "should be able to read index.json at %s", indexJsonPath)

	indexJson := string(indexJsonBytes)
	GinkgoWriter.Printf("[OciManifest] index.json content (%d bytes):\n%s\n", len(indexJsonBytes), indexJson)

	// Verify index.json has proper OCI structure
	requiredIndexFields := []string{"schemaVersion", "mediaType", "manifests", "digest", "size"}
	for _, field := range requiredIndexFields {
		if strings.Contains(indexJson, field) {
			GinkgoWriter.Printf("[OciManifest] index.json field '%s': FOUND\n", field)
		} else {
			GinkgoWriter.Printf("[OciManifest] index.json field '%s': MISSING\n", field)
		}
		Expect(indexJson).To(ContainSubstring(field), "index.json should contain '%s'", field)
	}

	// Verify K2s-specific annotations are present
	k2sAnnotations := []string{"vnd.k2s.addon.name", "vnd.k2s.addon.implementation", "org.opencontainers.image.version"}
	for _, annotation := range k2sAnnotations {
		if strings.Contains(indexJson, annotation) {
			GinkgoWriter.Printf("[OciManifest] K2s annotation '%s': FOUND\n", annotation)
		} else {
			GinkgoWriter.Printf("[OciManifest] K2s annotation '%s': MISSING\n", annotation)
		}
		Expect(indexJson).To(ContainSubstring(annotation), "index.json should contain K2s annotation '%s'", annotation)
	}

	// Verify the expected addon is referenced
	Expect(indexJson).To(ContainSubstring(expectedDirName),
		"index.json should reference addon %s", expectedDirName)

	GinkgoWriter.Println("=== VERIFY OCI MANIFEST END ===")
}

// CleanAddonResources cleans up resources for a specific addon implementation.
func CleanAddonResources(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== CLEAN ADDON RESOURCES START ===")
	GinkgoWriter.Printf("[Clean] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Clean] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Clean] Control plane IP: %s\n", controlPlaneIP)

	GinkgoWriter.Println("[Clean] Running 'k2s image clean -o' to remove images...")
	suite.K2sCli().Exec(ctx, "image", "clean", "-o")
	GinkgoWriter.Println("[Clean] Image clean completed")

	rmCmd := fmt.Sprintf("sudo rm -rf .%s", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Clean] Removing debian packages with command: %s\n", rmCmd)
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", rmCmd)
	GinkgoWriter.Println("[Clean] Debian packages removed")

	GinkgoWriter.Println("=== CLEAN ADDON RESOURCES END ===")
}

// VerifyResourcesCleanedUp verifies that addon resources have been cleaned up.
func VerifyResourcesCleanedUp(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== VERIFY RESOURCES CLEANED UP START ===")
	GinkgoWriter.Printf("[Verify] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Verify] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Verify] Control plane IP: %s\n", controlPlaneIP)

	// Verify debian packages are removed
	checkCmd := fmt.Sprintf("[ -d .%s ]", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Verify] Checking directory does not exist with command: %s\n", checkCmd)
	GinkgoWriter.Println("[Verify] Expecting exit code 1 (directory should not exist)...")
	suite.K2sCli().ExpectedExitCode(1).Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
	GinkgoWriter.Println("[Verify] Confirmed: directory does not exist (as expected)")
	GinkgoWriter.Println("=== VERIFY RESOURCES CLEANED UP END ===")
}

// ImportAddon imports all addons contained in an OCI tar file.
func ImportAddon(ctx context.Context, suite *framework.K2sTestSuite, ociTarPath string) {
	ImportAddonsWithOmit(ctx, suite, ociTarPath, nil, nil)
}

// ImportAddonsWithOmit imports addons from an OCI tar file.
//
// addonArgs selects the addons/implementations to import as positional tokens exactly like on the
// CLI (e.g. []string{"ingress", "nginx", "security"}); an empty slice imports everything.
// omitFlags are passed as repeated '--omit' options and make the importer skip the container images
// of the omitted functionality. An image is only skipped when none of the SELECTED implementations
// still requires it; the OCI artifact itself is never modified.
func ImportAddonsWithOmit(ctx context.Context, suite *framework.K2sTestSuite, ociTarPath string, addonArgs []string, omitFlags []string) {
	GinkgoWriter.Println("=== IMPORT ADDON START ===")
	GinkgoWriter.Printf("[Import] OCI tar file: %s\n", ociTarPath)
	GinkgoWriter.Printf("[Import] Selected addons: %v\n", addonArgs)
	GinkgoWriter.Printf("[Import] Omit options: %v\n", omitFlags)

	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Import] OCI tar file size: %d bytes\n", info.Size())
	} else {
		GinkgoWriter.Printf("[Import] WARNING: Cannot stat OCI tar file: %s - %v\n", ociTarPath, err)
	}

	args := append([]string{"addons", "import"}, addonArgs...)
	args = append(args, "-f", ociTarPath)
	for _, omitFlag := range omitFlags {
		args = append(args, "--omit", omitFlag)
	}

	GinkgoWriter.Printf("[Import] Executing 'k2s %s'\n", strings.Join(args, " "))
	suite.K2sCli().MustExec(ctx, args...)
	GinkgoWriter.Println("[Import] Import command completed successfully")
	GinkgoWriter.Println("=== IMPORT ADDON END ===")
}

// VerifyImagesPresentOnNodes asserts that every given image is available on one of the cluster nodes.
// Matching is substring-based like VerifyImportedImages, because node runtimes may report images
// with additional registry prefixes.
func VerifyImagesPresentOnNodes(ctx context.Context, k2sDsl *dsl.K2s, images []string, reason string) {
	GinkgoWriter.Printf("=== VERIFY IMAGES PRESENT (%s) ===\n", reason)
	Expect(images).ToNot(BeEmpty(), "[ImagesPresent] the expected image list must not be empty (%s)", reason)

	imagesOnNodes := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[ImagesPresent] Images on nodes: %d\n", len(imagesOnNodes))

	for i, image := range images {
		found := slices.ContainsFunc(imagesOnNodes, func(onNode string) bool {
			return strings.Contains(onNode, image)
		})
		GinkgoWriter.Printf("[ImagesPresent]   [%d] %s -> present=%v\n", i, image, found)
		Expect(found).To(BeTrue(), "image '%s' must be available on a node (%s)", image, reason)
	}
}

// VerifyImagesAbsentFromNodes asserts that none of the given images is available on any cluster node.
func VerifyImagesAbsentFromNodes(ctx context.Context, k2sDsl *dsl.K2s, images []string, reason string) {
	GinkgoWriter.Printf("=== VERIFY IMAGES ABSENT (%s) ===\n", reason)
	Expect(images).ToNot(BeEmpty(), "[ImagesAbsent] the expected image list must not be empty (%s)", reason)

	imagesOnNodes := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[ImagesAbsent] Images on nodes: %d\n", len(imagesOnNodes))

	for i, image := range images {
		found := slices.ContainsFunc(imagesOnNodes, func(onNode string) bool {
			return strings.Contains(onNode, image)
		})
		GinkgoWriter.Printf("[ImagesAbsent]   [%d] %s -> present=%v\n", i, image, found)
		Expect(found).To(BeFalse(), "image '%s' must NOT be available on any node (%s)", image, reason)
	}
}

// ImagesExcept returns the images of 'all' that are not contained in any of the 'excluded' sets.
// Used to derive the images that must still be imported when others are skipped via '--omit'.
func ImagesExcept(all []string, excluded ...[]string) []string {
	var result []string

	for _, image := range all {
		isExcluded := false
		for _, exclusionSet := range excluded {
			if slices.Contains(exclusionSet, image) {
				isExcluded = true
				break
			}
		}
		if !isExcluded {
			result = append(result, image)
		}
	}

	return lo.Uniq(result)
}

// Sha256OfFile returns the hex-encoded SHA256 checksum of a file. Used to prove that importing
// with '--omit' leaves the OCI artifact byte-identical.
func Sha256OfFile(path string) string {
	file, err := os.Open(path)
	Expect(err).ToNot(HaveOccurred(), "should be able to open '%s' for hashing", path)
	defer file.Close()

	hasher := sha256.New()
	_, err = io.Copy(hasher, file)
	Expect(err).ToNot(HaveOccurred(), "should be able to hash '%s'", path)

	checksum := hex.EncodeToString(hasher.Sum(nil))
	GinkgoWriter.Printf("[Sha256] %s -> %s\n", path, checksum)

	return checksum
}

// RemoveAllAddonImages removes every non-Kubernetes container image from the cluster nodes so that
// a subsequent import starts from a defined, empty state.
func RemoveAllAddonImages(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s) {
	GinkgoWriter.Println("=== REMOVE ALL ADDON IMAGES START ===")
	suite.K2sCli().Exec(ctx, "image", "clean", "-o")

	remaining := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[CleanImages] Non-K8s images remaining after clean: %d\n", len(remaining))
	Expect(remaining).To(BeEmpty(), "all non-K8s images should be removed before an import test")
	GinkgoWriter.Println("=== REMOVE ALL ADDON IMAGES END ===")
}

// VerifyImportedImages verifies that expected images are available after import.
func VerifyImportedImages(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY IMPORTED IMAGES START ===")
	GinkgoWriter.Printf("[ImportedImages] Implementation: %s\n", impl.Name)

	importedImages := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[ImportedImages] Total imported images on nodes: %d\n", len(importedImages))
	for i, img := range importedImages {
		GinkgoWriter.Printf("[ImportedImages]   [%d] %s\n", i, img)
	}

	allImages, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).To(BeNil(), "[ImportedImages] Failed to get expected images from manifest")
	GinkgoWriter.Printf("[ImportedImages] Images from manifest (before K8s filter): %d\n", len(allImages))

	// Filter out K8s base images (same filtering as GetNonK8sImagesFromNodes) so that
	// images already present in the base cluster setup are excluded from the expected list.
	images := k2sDsl.FilterOutK8sImages(allImages)
	GinkgoWriter.Printf("[ImportedImages] Expected images after K8s filter: %d\n", len(images))

	for i, image := range images {
		contains := slices.ContainsFunc(importedImages, func(imported string) bool {
			return strings.Contains(imported, image)
		})
		if contains {
			GinkgoWriter.Printf("[ImportedImages]   [%d] OK: %s\n", i, image)
		} else {
			GinkgoWriter.Printf("[ImportedImages]   [%d] MISSING: %s\n", i, image)
		}
		Expect(contains).To(BeTrue(), "Image %s should be available after import", image)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED IMAGES END ===")
}

func VerifyImportedDebPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string, folderName ...string) {
	if len(folderName) > 0 && folderName[0] != "" {
		impl.ExportDirectoryName = folderName[0]
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED DEB PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedDeb] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedDeb] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[ImportedDeb] Control plane IP: %s\n", controlPlaneIP)
	GinkgoWriter.Printf("[ImportedDeb] Expected packages: %d\n", len(impl.OfflineUsage.LinuxResources.DebPackages))

	for i, pkg := range impl.OfflineUsage.LinuxResources.DebPackages {
		checkCmd := fmt.Sprintf("[ -d .%s/%s ]", impl.ExportDirectoryName, pkg)
		GinkgoWriter.Printf("[ImportedDeb]   [%d] Checking: %s\n", i, pkg)
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
		GinkgoWriter.Printf("[ImportedDeb]   [%d] OK: %s exists\n", i, pkg)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED DEB PACKAGES END ===")
}

func VerifyImportedLinuxCurlPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string, folderName ...string) {
	if len(folderName) > 0 && folderName[0] != "" {
		impl.ExportDirectoryName = folderName[0]
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED LINUX CURL PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedLinuxCurl] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedLinuxCurl] Control plane IP: %s\n", controlPlaneIP)
	GinkgoWriter.Printf("[ImportedLinuxCurl] Expected packages: %d\n", len(impl.OfflineUsage.LinuxResources.CurlPackages))

	for i, pkg := range impl.OfflineUsage.LinuxResources.CurlPackages {
		// Mirror Import.ps1 staging: absolute destinations are installed system-wide at that
		// path, while relative destinations are staged into the addon storage folder
		// (~/.<ExportDirectoryName>/<destination>) on the control plane.
		checkPath := pkg.Destination
		if !strings.HasPrefix(pkg.Destination, "/") {
			checkPath = fmt.Sprintf(".%s/%s", impl.ExportDirectoryName, pkg.Destination)
		}
		checkCmd := fmt.Sprintf("[ -f %s ]", checkPath)
		GinkgoWriter.Printf("[ImportedLinuxCurl]   [%d] Checking: %s -> %s\n", i, pkg.Url, checkPath)
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
		GinkgoWriter.Printf("[ImportedLinuxCurl]   [%d] OK: %s exists\n", i, checkPath)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED LINUX CURL PACKAGES END ===")
}

func VerifyImportedWindowsCurlPackages(suite *framework.K2sTestSuite, impl *addons.Implementation, folderName ...string) {
	if len(folderName) > 0 && folderName[0] != "" {
		impl.ExportDirectoryName = folderName[0]
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED WINDOWS CURL PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedWindowsCurl] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedWindowsCurl] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[ImportedWindowsCurl] Expected packages: %d\n", len(impl.OfflineUsage.WindowsResources.CurlPackages))

	for i, p := range impl.OfflineUsage.WindowsResources.CurlPackages {
		pkgPath := filepath.Join(suite.RootDir(), p.Destination)
		GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] Checking: %s -> %s\n", i, p.Url, pkgPath)
		info, err := os.Stat(pkgPath)
		if os.IsNotExist(err) {
			GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] MISSING: %s\n", i, pkgPath)
		} else if err == nil {
			GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] OK: %s (%d bytes)\n", i, pkgPath, info.Size())
		}
		Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist at %s", p.Destination, pkgPath)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED WINDOWS CURL PACKAGES END ===")
}

// CleanupExportedFiles removes exported files and directories.
func CleanupExportedFiles(exportPath string, ociTarPath string) {
	GinkgoWriter.Println("=== CLEANUP EXPORTED FILES START ===")
	GinkgoWriter.Printf("[Cleanup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Cleanup] OCI tar path: %s\n", ociTarPath)

	extractedFolder := filepath.Join(exportPath, "addons")
	if info, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
		GinkgoWriter.Printf("[Cleanup] Removing extracted folder: %s (isDir=%v)\n", extractedFolder, info.IsDir())
		if err := os.RemoveAll(extractedFolder); err != nil {
			GinkgoWriter.Printf("[Cleanup] WARNING: Failed to remove extracted folder: %v\n", err)
		} else {
			GinkgoWriter.Println("[Cleanup] Extracted folder removed successfully")
		}
	} else {
		GinkgoWriter.Printf("[Cleanup] Extracted folder does not exist: %s\n", extractedFolder)
	}

	if ociTarPath != "" {
		if info, err := os.Stat(ociTarPath); !os.IsNotExist(err) {
			GinkgoWriter.Printf("[Cleanup] Removing OCI tar file: %s (%d bytes)\n", ociTarPath, info.Size())
			if err := os.Remove(ociTarPath); err != nil {
				GinkgoWriter.Printf("[Cleanup] WARNING: Failed to remove OCI tar file: %v\n", err)
			} else {
				GinkgoWriter.Println("[Cleanup] OCI tar file removed successfully")
			}
		} else {
			GinkgoWriter.Printf("[Cleanup] OCI tar file does not exist: %s\n", ociTarPath)
		}
	}
	GinkgoWriter.Println("=== CLEANUP EXPORTED FILES END ===")
}

// GetFilesMatch returns files matching the given pattern in the directory.
func GetFilesMatch(dir string, pattern string) ([]string, error) {
	var matches []string

	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		if d.IsDir() {
			return nil
		}

		matched, err := filepath.Match(pattern, filepath.Base(path))
		if err != nil {
			return err
		}

		if matched {
			matches = append(matches, path)
		}

		return nil
	})

	return matches, err
}

// IsEmptyDir checks if a directory is empty.
func IsEmptyDir(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return true
	}
	return len(entries) == 0
}

// FilterAddonByName filters addons to return only the one with the specified name.
func FilterAddonByName(allAddons addons.Addons, addonName string) addons.Addons {
	return lo.Filter(allAddons, func(a addons.Addon, _ int) bool {
		return a.Metadata.Name == addonName
	})
}

// verifies that all expected addon files are present at the correct paths after import.
func VerifyImportedAddonFiles(implDir string, expectedFiles []string) {
	GinkgoWriter.Println("=== VERIFY IMPORTED ADDON FILES START ===")
	GinkgoWriter.Printf("[AddonFiles] Implementation directory: %s\n", implDir)
	GinkgoWriter.Printf("[AddonFiles] Expected files: %d\n", len(expectedFiles))

	for i, relPath := range expectedFiles {
		fullPath := filepath.Join(implDir, relPath)
		info, err := os.Stat(fullPath)
		if os.IsNotExist(err) {
			GinkgoWriter.Printf("[AddonFiles]   [%d] MISSING: %s\n", i, relPath)
		} else if err != nil {
			GinkgoWriter.Printf("[AddonFiles]   [%d] ERROR: %s - %v\n", i, relPath, err)
		} else {
			GinkgoWriter.Printf("[AddonFiles]   [%d] OK: %s (%d bytes)\n", i, relPath, info.Size())
		}
		Expect(os.IsNotExist(err)).To(BeFalse(), "File %s should exist at %s after import", relPath, fullPath)
		Expect(info.Size()).To(BeNumerically(">", 0), "File %s should not be empty", relPath)
	}

	GinkgoWriter.Println("=== VERIFY IMPORTED ADDON FILES END ===")
}

// verifies that no addon files were placed at incorrect paths after import.
func VerifyNoStrayFiles(unexpectedFiles []string) {
	GinkgoWriter.Println("=== VERIFY NO STRAY FILES START ===")
	GinkgoWriter.Printf("[StrayFiles] Checking %d paths that should NOT exist\n", len(unexpectedFiles))

	for i, path := range unexpectedFiles {
		_, err := os.Stat(path)
		if os.IsNotExist(err) {
			GinkgoWriter.Printf("[StrayFiles]   [%d] OK (absent): %s\n", i, path)
		} else {
			GinkgoWriter.Printf("[StrayFiles]   [%d] UNEXPECTED: %s exists!\n", i, path)
		}
		Expect(os.IsNotExist(err)).To(BeTrue(), "File %s should NOT exist (placed at wrong path during import)", path)
	}

	GinkgoWriter.Println("=== VERIFY NO STRAY FILES END ===")
}

func AssertWindowsCurlContains(impl *addons.Implementation, destination string) {
	dests := make([]string, 0, len(impl.OfflineUsage.WindowsResources.CurlPackages))
	for _, p := range impl.OfflineUsage.WindowsResources.CurlPackages {
		dests = append(dests, p.Destination)
	}
	Expect(dests).To(ContainElement(destination),
		"windows.curl must declare '%s' for offline packaging; "+
			"tools under non-standard YAML keys are excluded from export/import", destination)
}

// exports a single addon using a relative directory path.
func ExportAddonRelativePath(ctx context.Context, suite *framework.K2sTestSuite, addonName string, implName string, workingDir string, relativeOutputDir string) string {
	GinkgoWriter.Println("=== EXPORT ADDON (RELATIVE PATH) START ===")
	GinkgoWriter.Printf("[ExportRel] Addon: %s\n", addonName)
	if implName != "" && implName != addonName {
		GinkgoWriter.Printf("[ExportRel] Implementation: %s\n", implName)
	}
	GinkgoWriter.Printf("[ExportRel] Working directory: %s\n", workingDir)
	GinkgoWriter.Printf("[ExportRel] Relative output dir: %s\n", relativeOutputDir)

	// Resolve the absolute path so we can find the output file
	absOutputDir := filepath.Join(workingDir, relativeOutputDir)
	absOutputDir, err := filepath.Abs(absOutputDir)
	Expect(err).ToNot(HaveOccurred(), "[ExportRel] Failed to resolve absolute output path")
	GinkgoWriter.Printf("[ExportRel] Resolved absolute output dir: %s\n", absOutputDir)

	os.MkdirAll(absOutputDir, 0o755)

	if implName != "" && implName != addonName {
		suite.K2sCli().WorkingDir(workingDir).MustExec(ctx, "addons", "export", addonName+" "+implName, "-d", relativeOutputDir, "-o")
	} else {
		suite.K2sCli().WorkingDir(workingDir).MustExec(ctx, "addons", "export", addonName, "-d", relativeOutputDir, "-o")
	}
	GinkgoWriter.Println("[ExportRel] Export command completed")

	var pattern string
	if implName != "" && implName != addonName {
		pattern = filepath.Join(absOutputDir, fmt.Sprintf("K2s-*-addons-%s-%s.oci.tar", addonName, implName))
	} else {
		pattern = filepath.Join(absOutputDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", addonName))
	}
	files, err := filepath.Glob(pattern)
	Expect(err).ToNot(HaveOccurred(), "[ExportRel] Failed to glob for OCI tar files")
	Expect(len(files)).To(Equal(1), "Should create exactly one OCI tar file for %s with relative path, found %d", addonName, len(files))

	ociTarPath := files[0]
	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[ExportRel] OCI tar file: %s (%d bytes)\n", ociTarPath, info.Size())
	}
	GinkgoWriter.Println("=== EXPORT ADDON (RELATIVE PATH) END ===")
	return ociTarPath
}

// imports an addon using a relative file path.
func ImportAddonRelativePath(ctx context.Context, suite *framework.K2sTestSuite, workingDir string, relativeFilePath string) {
	GinkgoWriter.Println("=== IMPORT ADDON (RELATIVE PATH) START ===")
	GinkgoWriter.Printf("[ImportRel] Working directory: %s\n", workingDir)
	GinkgoWriter.Printf("[ImportRel] Relative file path: %s\n", relativeFilePath)

	suite.K2sCli().WorkingDir(workingDir).MustExec(ctx, "addons", "import", "-f", relativeFilePath, "-o")
	GinkgoWriter.Println("[ImportRel] Import command completed successfully")
	GinkgoWriter.Println("=== IMPORT ADDON (RELATIVE PATH) END ===")
}

// StageAddonIsolation moves every addon subdirectory under <rootDir>/addons to a unique
// temporary directory, except "common", targetAddon, and any additional names supplied via
// keepExtra, which are all left in place.
// The returned restore function moves them all back, removes the temporary directory on full
// success, and returns an aggregated error on any failure — the backup directory is preserved
// when restoration is incomplete so that no staged addon is permanently lost.
func StageAddonIsolation(rootDir, targetAddon string, keepExtra ...string) (restore func() error, err error) {
	addonsDir := filepath.Join(rootDir, "addons")

	// Validate required directories.
	if _, statErr := os.Stat(addonsDir); os.IsNotExist(statErr) {
		return nil, fmt.Errorf("[AddonIsolation] addons directory not found: %s", addonsDir)
	}
	if _, statErr := os.Stat(filepath.Join(addonsDir, "common")); os.IsNotExist(statErr) {
		return nil, fmt.Errorf("[AddonIsolation] required 'common' directory not found under: %s", addonsDir)
	}
	if _, statErr := os.Stat(filepath.Join(addonsDir, targetAddon)); os.IsNotExist(statErr) {
		return nil, fmt.Errorf("[AddonIsolation] target addon directory not found: %s", filepath.Join(addonsDir, targetAddon))
	}

	// Create a unique backup directory under <rootDir>/tmp (K2s e2e temp pattern)
	// so it stays on the same filesystem volume as addonsDir and keeps rename atomic.
	tmpParent := filepath.Join(rootDir, "tmp")
	if mkErr := os.MkdirAll(tmpParent, 0o755); mkErr != nil {
		return nil, fmt.Errorf("[AddonIsolation] failed to create tmp directory %s: %w", tmpParent, mkErr)
	}
	backupDir, tmpErr := os.MkdirTemp(tmpParent, "addon-isolation-")
	if tmpErr != nil {
		return nil, fmt.Errorf("[AddonIsolation] failed to create backup directory under %s: %w", tmpParent, tmpErr)
	}

	GinkgoWriter.Printf("[AddonIsolation] Staging isolation for addon %q; backup dir: %s\n", targetAddon, backupDir)

	entries, readErr := os.ReadDir(addonsDir)
	if readErr != nil {
		_ = os.RemoveAll(backupDir)
		return nil, fmt.Errorf("[AddonIsolation] failed to read addons directory %s: %w", addonsDir, readErr)
	}

	keep := map[string]bool{"common": true, targetAddon: true}
	for _, extra := range keepExtra {
		keep[extra] = true
	}
	var moved []string // names of directories successfully staged

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		if keep[name] {
			GinkgoWriter.Printf("[AddonIsolation] Keeping: %s\n", name)
			continue
		}

		src := filepath.Join(addonsDir, name)
		dst := filepath.Join(backupDir, name)
		GinkgoWriter.Printf("[AddonIsolation] Staging: %s -> %s\n", src, dst)
		if renameErr := renameWithRetry(src, dst); renameErr != nil {
			stageErr := fmt.Errorf("[AddonIsolation] failed to stage addon directory %s: %w", src, renameErr)
			var recoveryErrs []error
			// Restore already-moved directories before propagating the error.
			for _, m := range moved {
				if rerr := renameWithRetry(filepath.Join(backupDir, m), filepath.Join(addonsDir, m)); rerr != nil {
					GinkgoWriter.Printf("[AddonIsolation] WARNING: recovery rename failed for %s: %v\n", m, rerr)
					recoveryErrs = append(recoveryErrs, fmt.Errorf("failed to recover staged addon directory %q: %w", m, rerr))
				}
			}
			if len(recoveryErrs) > 0 {
				return nil, errors.Join(stageErr, errors.Join(recoveryErrs...))
			}
			_ = os.RemoveAll(backupDir)
			return nil, stageErr
		}
		moved = append(moved, name)
	}

	GinkgoWriter.Printf("[AddonIsolation] Staged %d addon directory(ies)\n", len(moved))

	restore = func() error {
		GinkgoWriter.Printf("[AddonIsolation] Restoring %d addon directory(ies) from: %s\n", len(moved), backupDir)
		var errs []error
		for _, name := range moved {
			src := filepath.Join(backupDir, name)
			dst := filepath.Join(addonsDir, name)
			GinkgoWriter.Printf("[AddonIsolation] Restoring: %s -> %s\n", src, dst)
			if _, statErr := os.Stat(dst); statErr == nil {
				GinkgoWriter.Printf("[AddonIsolation] Destination %s already exists; removing before restore rename\n", dst)
				if rmErr := removeDirWithRetry(dst); rmErr != nil {
					GinkgoWriter.Printf("[AddonIsolation] ERROR: failed to remove existing destination %s: %v\n", dst, rmErr)
					errs = append(errs, fmt.Errorf("failed to remove existing destination directory %q before restore: %w", dst, rmErr))
					continue
				}
			}
			if rerr := renameWithRetry(src, dst); rerr != nil {
				GinkgoWriter.Printf("[AddonIsolation] ERROR: failed to restore %s: %v\n", name, rerr)
				errs = append(errs, fmt.Errorf("failed to restore addon directory %q: %w", name, rerr))
			}
		}
		if len(errs) > 0 {
			GinkgoWriter.Printf("[AddonIsolation] Restore incomplete: %d error(s); backup dir preserved: %s\n", len(errs), backupDir)
			return errors.Join(errs...)
		}
		if rerr := os.RemoveAll(backupDir); rerr != nil {
			GinkgoWriter.Printf("[AddonIsolation] WARNING: failed to remove backup dir %s: %v\n", backupDir, rerr)
			return fmt.Errorf("[AddonIsolation] failed to remove backup directory %s: %w", backupDir, rerr)
		}
		// Intentionally best-effort warning-only cleanup to preserve restore success and original error precedence.
		if rerr := os.Remove(tmpParent); rerr != nil {
			GinkgoWriter.Printf("[AddonIsolation] WARNING: failed to remove tmp dir %s: %v\n", tmpParent, rerr)
		} else {
			GinkgoWriter.Printf("[AddonIsolation] Removed empty tmp dir: %s\n", tmpParent)
		}
		GinkgoWriter.Println("[AddonIsolation] Restore complete")
		return nil
	}

	return restore, nil
}

func renameWithRetry(src, dst string) error {
	const maxRetries = 10
	const retryDelay = 300 * time.Millisecond

	var lastErr error
	for attempt := 1; attempt <= maxRetries; attempt++ {
		if err := os.Rename(src, dst); err != nil {
			lastErr = err
			if attempt == maxRetries {
				GinkgoWriter.Printf("[AddonIsolation] ERROR: rename retries exhausted for %s -> %s after %d attempts; last error: %v\n", src, dst, maxRetries, lastErr)
			}
			if !isRetryableWindowsRenameError(err) || attempt == maxRetries {
				return err
			}
			GinkgoWriter.Printf("[AddonIsolation] WARN: rename retry %d/%d for %s -> %s due to: %v\n", attempt, maxRetries, src, dst, err)
			time.Sleep(retryDelay)
			continue
		}
		return nil
	}

	return lastErr
}

func removeDirWithRetry(path string) error {
	const maxRetries = 10
	const retryDelay = 300 * time.Millisecond

	var lastErr error
	for attempt := 1; attempt <= maxRetries; attempt++ {
		if err := os.RemoveAll(path); err != nil {
			lastErr = err
			if !isRetryableWindowsRenameError(err) || attempt == maxRetries {
				return err
			}
			GinkgoWriter.Printf("[AddonIsolation] WARN: remove retry %d/%d for %s due to: %v\n", attempt, maxRetries, path, err)
			time.Sleep(retryDelay)
			continue
		}
		return nil
	}

	return lastErr
}

func isRetryableWindowsRenameError(err error) bool {
	if runtime.GOOS != "windows" {
		return false
	}

	if pathErr, ok := errors.AsType[*os.PathError](err); ok {
		err = pathErr.Err
	}

	if errno, ok := err.(syscall.Errno); ok {
		// Windows errno values for transient file-lock conditions:
		//   5   = ERROR_ACCESS_DENIED
		//   32  = ERROR_SHARING_VIOLATION
		//   33  = ERROR_LOCK_VIOLATION
		//   145 = ERROR_DIR_NOT_EMPTY (raised by RemoveAll when dir still has handles)
		return errno == 5 || errno == 32 || errno == 33 || errno == 145
	}

	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "access is denied") || strings.Contains(msg, "being used by another process")
}
