// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// Package gitopssync provides shared helper functions for GitOps addon-sync e2e tests.
package gitopssync

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

// TarExe returns the tar executable name used on Windows.
func TarExe() string {
	return "tar.exe"
}

// SafeTrim returns at most maxLen characters from the end of s.
func SafeTrim(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return "..." + s[len(s)-maxLen:]
}

// WaitForJobCompletion polls until the named Job reaches Complete or Failed (max 20 min).
// It does NOT assert success; callers should explicitly check the Job condition afterwards.
func WaitForJobCompletion(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) {
	Eventually(func() bool {
		output, exitCode := suite.Kubectl().Exec(ctx,
			"get", "job", jobName,
			"-n", namespace,
			"-o", "jsonpath={.status.conditions[*].type}")
		if exitCode != 0 {
			GinkgoWriter.Printf("[Wait] kubectl get job failed (exit %d)\n", exitCode)
			return false
		}
		done := strings.Contains(output, "Complete") || strings.Contains(output, "Failed")
		if !done {
			GinkgoWriter.Printf("[Wait] Job %s not yet done, conditions: %q\n", jobName, output)
			// Emit pod-level diagnostics to surface image-pull or container failures early.
			podPhase, _ := suite.Kubectl().Exec(ctx,
				"get", "pods", "-n", namespace,
				"-l", "job-name="+jobName,
				"-o", "jsonpath={range .items[*]}{.metadata.name}={.status.phase},{.status.containerStatuses[0].state.waiting.reason}{' '}{end}")
			GinkgoWriter.Printf("[Wait] Job %s pods: %s\n", jobName, podPhase)
		}
		return done
	}, 20*time.Minute, 15*time.Second, ctx).Should(BeTrue(),
		"Job %s should reach Complete or Failed within 20 minutes", jobName)
}

// WaitForJobToFinish polls until the named Job reaches Complete or Failed (max 20 min)
// without asserting success. Used in negative-path tests where pod failure is expected.
func WaitForJobToFinish(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) {
	Eventually(func() bool {
		output, exitCode := suite.Kubectl().Exec(ctx,
			"get", "job", jobName,
			"-n", namespace,
			"-o", "jsonpath={.status.conditions[*].type}")
		if exitCode != 0 {
			return false
		}
		return strings.Contains(output, "Complete") || strings.Contains(output, "Failed")
	}, 20*time.Minute, 15*time.Second, ctx).Should(BeTrue(),
		"Job %s should reach Complete or Failed within 20 minutes", jobName)
}

// GetJobLogs returns the combined stdout logs of all pods owned by the named Job.
func GetJobLogs(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) string {
	output, exitCode := suite.Kubectl().Exec(ctx,
		"logs", "-n", namespace,
		"--selector=job-name="+jobName,
		"--tail=-1")
	if exitCode != 0 {
		GinkgoWriter.Printf("[Logs] kubectl logs exited with %d, retrying with pod list\n", exitCode)
		podsOutput, _ := suite.Kubectl().Exec(ctx,
			"get", "pods", "-n", namespace,
			"-l", "job-name="+jobName,
			"-o", "jsonpath={.items[0].metadata.name}")
		if podsOutput != "" {
			podName := strings.TrimSpace(podsOutput)
			output, _ = suite.Kubectl().Exec(ctx, "logs", podName, "-n", namespace)
		}
	}
	return output
}

// ReadTagFromOCILayout parses the OCI Image Layout index.json in layoutDir and
// returns the first tag found via the org.opencontainers.image.ref.name annotation.
// This avoids hardcoding the addon version in test code.
func ReadTagFromOCILayout(layoutDir string) (string, error) {
	data, err := os.ReadFile(filepath.Join(layoutDir, "index.json"))
	if err != nil {
		return "", fmt.Errorf("read index.json: %w", err)
	}
	var index struct {
		Manifests []struct {
			Annotations map[string]string `json:"annotations"`
		} `json:"manifests"`
	}
	if err = json.Unmarshal(data, &index); err != nil {
		return "", fmt.Errorf("parse index.json: %w", err)
	}
	if len(index.Manifests) == 0 {
		return "", fmt.Errorf("index.json contains no manifests")
	}
	tag, ok := index.Manifests[0].Annotations["org.opencontainers.image.ref.name"]
	if !ok || tag == "" {
		return "", fmt.Errorf("index.json manifest[0] has no org.opencontainers.image.ref.name annotation")
	}
	return tag, nil
}

// CreateDummyOCILayout builds a minimal OCI Image Layout directory containing
// a single artifact tagged as tag. The manifest layer carries media type
// "application/octet-stream" — intentionally wrong — so that the sync consumer
// fails to find the expected "application/vnd.k2s.addon.manifests.v1.tar+gzip"
// layer. Returns the layout directory; callers must remove it with os.RemoveAll.
func CreateDummyOCILayout(tag string) (string, error) {
	dir, err := os.MkdirTemp("", "k2s-oci-layout-neg-*")
	if err != nil {
		return "", fmt.Errorf("MkdirTemp: %w", err)
	}

	blobsDir := filepath.Join(dir, "blobs", "sha256")
	if mkErr := os.MkdirAll(blobsDir, 0755); mkErr != nil {
		return dir, fmt.Errorf("MkdirAll blobs: %w", mkErr)
	}

	writeBlob := func(content []byte) (string, int64, error) {
		sum := sha256.Sum256(content)
		hexStr := hex.EncodeToString(sum[:])
		if wErr := os.WriteFile(filepath.Join(blobsDir, hexStr), content, 0644); wErr != nil {
			return "", 0, wErr
		}
		return "sha256:" + hexStr, int64(len(content)), nil
	}

	configDigest, configSize, err := writeBlob([]byte("{}"))
	if err != nil {
		return dir, fmt.Errorf("write config blob: %w", err)
	}

	layerDigest, layerSize, err := writeBlob([]byte("not a k2s addon manifests layer"))
	if err != nil {
		return dir, fmt.Errorf("write layer blob: %w", err)
	}

	manifestBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.manifest.v1+json",
		"config": map[string]any{
			"mediaType": "application/vnd.oci.image.config.v1+json",
			"digest":    configDigest,
			"size":      configSize,
		},
		"layers": []any{
			map[string]any{
				// Intentionally wrong — not application/vnd.k2s.addon.manifests.v1.tar+gzip
				"mediaType": "application/octet-stream",
				"digest":    layerDigest,
				"size":      layerSize,
			},
		},
	})
	if err != nil {
		return dir, fmt.Errorf("marshal manifest: %w", err)
	}

	manifestDigest, manifestSize, err := writeBlob(manifestBytes)
	if err != nil {
		return dir, fmt.Errorf("write manifest blob: %w", err)
	}

	indexBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.index.v1+json",
		"manifests": []any{
			map[string]any{
				"mediaType": "application/vnd.oci.image.manifest.v1+json",
				"digest":    manifestDigest,
				"size":      manifestSize,
				"annotations": map[string]string{
					"org.opencontainers.image.ref.name": tag,
				},
			},
		},
	})
	if err != nil {
		return dir, fmt.Errorf("marshal index: %w", err)
	}

	if err = os.WriteFile(filepath.Join(dir, "index.json"), indexBytes, 0644); err != nil {
		return dir, fmt.Errorf("write index.json: %w", err)
	}
	if err = os.WriteFile(filepath.Join(dir, "oci-layout"),
		[]byte(`{"imageLayoutVersion":"1.0.0"}`), 0644); err != nil {
		return dir, fmt.Errorf("write oci-layout: %w", err)
	}
	return dir, nil
}

// VerifyManifestsLayerContent extracts the manifests layer from an OCI layout
// directory (the first layer whose media type matches manifestsMediaType) and
// verifies that the extracted content contains the expected gitops-sync files
// with correct placeholder substitution.
//
// Returns a list of file paths found inside the manifests layer for diagnostic logging.
func VerifyManifestsLayerContent(layoutDir, manifestsMediaType, expectedAddonName string) ([]string, error) {
	indexData, err := os.ReadFile(filepath.Join(layoutDir, "index.json"))
	if err != nil {
		return nil, fmt.Errorf("read index.json: %w", err)
	}

	var index struct {
		Manifests []struct {
			Digest string `json:"digest"`
		} `json:"manifests"`
	}
	if err = json.Unmarshal(indexData, &index); err != nil {
		return nil, fmt.Errorf("parse index.json: %w", err)
	}
	if len(index.Manifests) == 0 {
		return nil, fmt.Errorf("index.json contains no manifests")
	}

	manifestDigest := index.Manifests[0].Digest
	manifestBlobPath := filepath.Join(layoutDir, "blobs", strings.Replace(manifestDigest, ":", "/", 1))
	manifestData, err := os.ReadFile(manifestBlobPath)
	if err != nil {
		return nil, fmt.Errorf("read manifest blob %s: %w", manifestDigest, err)
	}

	var imageManifest struct {
		Layers []struct {
			Digest    string `json:"digest"`
			MediaType string `json:"mediaType"`
		} `json:"layers"`
	}
	if err = json.Unmarshal(manifestData, &imageManifest); err != nil {
		return nil, fmt.Errorf("parse image manifest: %w", err)
	}

	var manifestsLayerDigest string
	for _, layer := range imageManifest.Layers {
		if layer.MediaType == manifestsMediaType {
			manifestsLayerDigest = layer.Digest
			break
		}
	}
	if manifestsLayerDigest == "" {
		layerTypes := make([]string, 0, len(imageManifest.Layers))
		for _, l := range imageManifest.Layers {
			layerTypes = append(layerTypes, l.MediaType)
		}
		return nil, fmt.Errorf("no layer with media type %q found; available types: %v",
			manifestsMediaType, layerTypes)
	}

	layerBlobPath := filepath.Join(layoutDir, "blobs", strings.Replace(manifestsLayerDigest, ":", "/", 1))
	layerFile, err := os.Open(layerBlobPath)
	if err != nil {
		return nil, fmt.Errorf("open manifests layer blob %s: %w", manifestsLayerDigest, err)
	}
	defer layerFile.Close()

	gzReader, err := gzip.NewReader(layerFile)
	if err != nil {
		return nil, fmt.Errorf("gzip reader for manifests layer: %w", err)
	}
	defer gzReader.Close()

	tarReader := tar.NewReader(gzReader)
	var filePaths []string
	var syncJobContent string
	var kustomizationContent string
	foundGitopsSync := false

	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return filePaths, fmt.Errorf("read tar entry: %w", err)
		}

		cleanPath := filepath.ToSlash(strings.TrimPrefix(header.Name, "./"))
		filePaths = append(filePaths, cleanPath)

		if strings.HasPrefix(cleanPath, "gitops-sync/") {
			foundGitopsSync = true
		}

		if cleanPath == "gitops-sync/sync-job.yaml" && header.Typeflag == tar.TypeReg {
			data, readErr := io.ReadAll(tarReader)
			if readErr != nil {
				return filePaths, fmt.Errorf("read sync-job.yaml: %w", readErr)
			}
			syncJobContent = string(data)
		}
		if cleanPath == "gitops-sync/kustomization.yaml" && header.Typeflag == tar.TypeReg {
			data, readErr := io.ReadAll(tarReader)
			if readErr != nil {
				return filePaths, fmt.Errorf("read kustomization.yaml: %w", readErr)
			}
			kustomizationContent = string(data)
		}
	}

	if !foundGitopsSync {
		return filePaths, fmt.Errorf("manifests layer does not contain gitops-sync/ directory; found: %v", filePaths)
	}
	if syncJobContent == "" {
		return filePaths, fmt.Errorf("manifests layer does not contain gitops-sync/sync-job.yaml; found: %v", filePaths)
	}
	if kustomizationContent == "" {
		return filePaths, fmt.Errorf("manifests layer does not contain gitops-sync/kustomization.yaml; found: %v", filePaths)
	}

	expectedJobName := "addon-sync-" + expectedAddonName
	if !strings.Contains(syncJobContent, "name: "+expectedJobName) {
		return filePaths, fmt.Errorf("sync-job.yaml does not contain 'name: %s'; ADDON_NAME_PLACEHOLDER may not have been substituted.\nContent (last 500 chars): %s",
			expectedJobName, SafeTrim(syncJobContent, 500))
	}
	if strings.Contains(syncJobContent, "ADDON_NAME_PLACEHOLDER") {
		return filePaths, fmt.Errorf("sync-job.yaml still contains unsubstituted ADDON_NAME_PLACEHOLDER")
	}
	if strings.Contains(syncJobContent, "EXPORT_TIMESTAMP_PLACEHOLDER") {
		return filePaths, fmt.Errorf("sync-job.yaml still contains unsubstituted EXPORT_TIMESTAMP_PLACEHOLDER")
	}

	if !strings.Contains(kustomizationContent, "sync-job.yaml") {
		return filePaths, fmt.Errorf("kustomization.yaml does not reference sync-job.yaml")
	}

	return filePaths, nil
}

// DumpFluxControllerLogs captures the last N lines of source-controller and
// kustomize-controller logs from the Flux deployment namespace (typically "rollout").
// Useful for diagnosing reconciliation failures in CI.
func DumpFluxControllerLogs(ctx context.Context, suite *framework.K2sTestSuite, fluxNamespace string, tailLines int) {
	for _, controller := range []string{"source-controller", "kustomize-controller"} {
		GinkgoWriter.Printf("[Diag] === %s logs (last %d lines, namespace %s) ===\n",
			controller, tailLines, fluxNamespace)
		logs, exitCode := suite.Kubectl().Exec(ctx,
			"logs", "-n", fluxNamespace,
			"-l", "app="+controller,
			"--tail", fmt.Sprintf("%d", tailLines))
		if exitCode != 0 {
			GinkgoWriter.Printf("[Diag] Failed to get %s logs (exit %d)\n", controller, exitCode)
			continue
		}
		GinkgoWriter.Printf("%s\n", SafeTrim(logs, 3000))
	}
}

// DumpSourceControllerDiagnostics emits source-controller pod status, the
// OCIRepository full status (artifact URL, conditions), and the source-controller
// service. Call this when kustomize-controller reports "Source artifact not found".
func DumpSourceControllerDiagnostics(ctx context.Context, suite *framework.K2sTestSuite, fluxNamespace, ociRepoNamespace, ociRepoName string) {
	GinkgoWriter.Printf("[Diag] === source-controller pod status (namespace %s) ===\n", fluxNamespace)
	podStatus, _ := suite.Kubectl().Exec(ctx,
		"get", "pods", "-n", fluxNamespace,
		"-l", "app=source-controller",
		"-o", `jsonpath={range .items[*]}{.metadata.name} phase={.status.phase} ready={.status.containerStatuses[0].ready}{"\n"}{end}`)
	GinkgoWriter.Printf("%s\n", podStatus)

	GinkgoWriter.Printf("[Diag] === source-controller service (namespace %s) ===\n", fluxNamespace)
	svcInfo, _ := suite.Kubectl().Exec(ctx,
		"get", "service", "source-controller", "-n", fluxNamespace,
		"-o", `jsonpath=ClusterIP={.spec.clusterIP} Port={.spec.ports[0].port}`)
	GinkgoWriter.Printf("%s\n", svcInfo)

	GinkgoWriter.Printf("[Diag] === OCIRepository %s/%s full status ===\n", ociRepoNamespace, ociRepoName)
	ociStatus, _ := suite.Kubectl().Exec(ctx,
		"get", "ocirepository", ociRepoName, "-n", ociRepoNamespace,
		"-o", `jsonpath=Ready={.status.conditions[?(@.type=='Ready')].status} msg={.status.conditions[?(@.type=='Ready')].message} url={.status.artifact.url} rev={.status.artifact.revision} lastUpdate={.status.artifact.lastUpdateTime}`)
	GinkgoWriter.Printf("%s\n", ociStatus)
}

// WaitForKustomizationCondition polls the Flux Kustomization until its Ready
// condition is populated (True or False). Returns the Ready status and message.
func WaitForKustomizationCondition(ctx context.Context, suite *framework.K2sTestSuite, namespace, name string, timeout time.Duration) (status, message string) {
	Eventually(func() string {
		s, _ := suite.Kubectl().Exec(ctx,
			"get", "kustomization", name,
			"-n", namespace,
			"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
		if s == "" {
			GinkgoWriter.Printf("[Wait] Kustomization %s has no Ready condition yet\n", name)
		}
		return s
	}, timeout, 10*time.Second, ctx).ShouldNot(BeEmpty(),
		"Kustomization %s should report a Ready condition within %v", name, timeout)

	status, _ = suite.Kubectl().Exec(ctx,
		"get", "kustomization", name,
		"-n", namespace,
		"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
	message, _ = suite.Kubectl().Exec(ctx,
		"get", "kustomization", name,
		"-n", namespace,
		"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].message}")
	return status, message
}
