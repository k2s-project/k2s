// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package addons

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/core/addons"
	sos "github.com/k2s-project/k2s/test/framework/os"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/samber/lo"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
)

type Addon struct {
	Name            string           `json:"name"`
	Description     string           `json:"description"`
	Implementations []Implementation `json:"implementations"`
}

type Implementation struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

type AddonsStatus struct {
	EnabledAddons  []Addon `json:"enabledAddons"`
	DisabledAddons []Addon `json:"disabledAddons"`
}

type AddonsAdditionalInfo struct {
}

const manifestFileName = "addon.manifest.yaml"

func (addonsStatus *AddonsStatus) GetEnabledAddons() []string {
	return lo.Map(addonsStatus.EnabledAddons, func(addon Addon, _ int) string {
		return addon.Name
	})
}

func NewAddonsAdditionalInfo() *AddonsAdditionalInfo {
	return &AddonsAdditionalInfo{}
}

func (info *AddonsAdditionalInfo) AllAddons() addons.Addons {
	rootDir, err := sos.RootDir()
	Expect(err).To(BeNil())

	allAddons, err := addons.LoadAddons(rootDir)
	Expect(err).To(BeNil())

	return allAddons
}

func (info *AddonsAdditionalInfo) GetImagesForAddonImplementation(implementation addons.Implementation) ([]string, error) {
	GinkgoWriter.Println("Collecting images for addon implementation", implementation.Name)
	// collect all yaml files
	yamlFiles, err := sos.GetFilesMatch(implementation.Directory, "*.yaml")
	if err != nil {
		log.Fatal(err)
		return nil, err
	}
	GinkgoWriter.Println("Collected", len(yamlFiles), "yaml files from directory", implementation.Directory)

	// Helm charts part
	tmpChartDir := ""
	// check if directory implementation.Directory/manifests/chart exists
	chartDir := filepath.Join(implementation.Directory, "manifests", "chart")
	if _, err := os.Stat(chartDir); os.IsNotExist(err) {
		GinkgoWriter.Println("Directory %s does not exist, will continue without a helm chart", chartDir)
	} else if err == nil {
		// convert chart to yaml
		GinkgoWriter.Println("Converting chart to yaml")
		chartFiles, err := sos.GetFilesMatch(chartDir, "*.tgz")
		if err != nil {
			// go through all chart files
			log.Fatal(err)
			return nil, err
		}
		// ensure we have only one chart file
		if len(chartFiles) != 1 {
			log.Fatal("Expected only one chart file in the folder", chartDir)
			return nil, fmt.Errorf("Expected only one chart file in the folder %s", chartDir)
		}
		// get a temp directory
		tmpChartDir, err = os.MkdirTemp("", implementation.Name)
		GinkgoWriter.Println("Created temp directory", tmpChartDir)
		if err != nil {
			log.Fatal(err)
			return nil, err
		}
		// convert chart to yaml
		for _, chartFile := range chartFiles {
			// print chart name
			chartName := filepath.Base(chartFile)
			GinkgoWriter.Println("Converting chart", chartName)
			// get the release name from the chart file name
			// kubernetes-dashboard-x.x.x.tgz -> kubernetes-dashboard
			chartNameParts := strings.Split(chartName, "-")
			chartNameParts = chartNameParts[:len(chartNameParts)-1]
			release := strings.Join(chartNameParts, "-")
			// get the path relative to the directory where this file is located
			executable := implementation.Directory + "\\..\\..\\bin\\" + "helm.exe"
			// call helm to template chart
			cmd := []string{executable, "template", release}
			cmd = append(cmd, chartFile)
			cmd = append(cmd, "-f", filepath.Join(chartDir, "values.yaml"))
			cmd = append(cmd, "--output-dir", tmpChartDir)
			// run cmd in order to create yaml files from the helm chart
			GinkgoWriter.Println("Running command", cmd)
			out, err := exec.Command(cmd[0], cmd[1:]...).CombinedOutput()
			if err != nil {
				GinkgoWriter.Println("Command failed with error", err)
				GinkgoWriter.Println("Command output", string(out))
				return nil, err
			}
			// collect all yaml files
			yFiles, err := sos.GetFilesMatch(tmpChartDir, "*.yaml")
			if err != nil {
				return nil, err
			}
			// add yaml files to files
			yamlFiles = append(yamlFiles, yFiles...)
		}
	}

	// exclude files with ## exclude-from-export and manifest
	yamlFiles = lo.Filter(yamlFiles, func(path string, index int) bool {
		if filepath.Base(path) == manifestFileName {
			return false
		}

		content, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}

		yamlContent := string(content)

		return !strings.Contains(yamlContent, "## exclude-from-export")
	})

	// get images from yaml
	images := lo.FlatMap(yamlFiles, func(path string, index int) []string {
		content, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}

		var imagesInFile []string
		decoder := yaml.NewDecoder(strings.NewReader(string(content)))

		for {
			var doc interface{}
			if err := decoder.Decode(&doc); err != nil {
				if err == io.EOF {
					break
				}
				GinkgoWriter.Printf("Warning: Failed to parse YAML document in file %s: %v\n", path, err)
				break
			}
			imagesInFile = append(imagesInFile, extractImagesFromYAMLContent(doc)...)
		}

		return imagesInFile
	})

	// add images from additionalImagesFiles
	var yamlFileImages []string
	if len(implementation.OfflineUsage.LinuxResources.AdditionalImagesFiles) > 0 {
		yamlFileImages = imagesFromAdditionalImagesFiles(implementation)
		images = append(images, yamlFileImages...)
	}

	// add additional images, but skip versionless ones if versioned equivalent exists in YAML files
	if len(implementation.OfflineUsage.LinuxResources.AdditionalImages) > 0 {
		for _, additionalImage := range implementation.OfflineUsage.LinuxResources.AdditionalImages {
			// Check if this is a versionless image (no :tag)
			hasTag := strings.Contains(additionalImage, ":")
			if !hasTag {
				// Check if a versioned variant exists in YAML file images
				hasVersionedVariant := false
				for _, yamlImage := range yamlFileImages {
					// Extract base image name from YAML image (before the :tag)
					parts := strings.Split(yamlImage, ":")
					if len(parts) > 1 {
						yamlBaseName := parts[0]
						if additionalImage == yamlBaseName {
							hasVersionedVariant = true
							GinkgoWriter.Printf("Skipping versionless image '%s' from additionalImages because versioned variant '%s' exists in additionalImagesFiles\n", additionalImage, yamlImage)
							break
						}
					}
				}
				// Only add if no versioned variant found
				if !hasVersionedVariant {
					images = append(images, additionalImage)
				}
			} else {
				// Already versioned, add it
				images = append(images, additionalImage)
			}
		}
	}

	// add Windows images
	windowsImageCount := 0
	if len(implementation.OfflineUsage.WindowsResources.AdditionalImages) > 0 {
		for _, windowsImage := range implementation.OfflineUsage.WindowsResources.AdditionalImages {
			windowsImageCount++
			GinkgoWriter.Printf("  Windows platform image: %s (will be exported as separate _win.tar)\n", windowsImage)
		}
	}

	// delete folder if it was created
	if tmpChartDir != "" {
		GinkgoWriter.Println("Deleting temp directory", tmpChartDir)
		err := os.RemoveAll(tmpChartDir)
		if err != nil {
			log.Fatal(err)
		}
	}

	// add count of Windows platform images
	uniqueLinuxImages := lo.Union(images)
	totalImageCount := len(uniqueLinuxImages) + windowsImageCount

	GinkgoWriter.Printf("  Unique Linux images: %d, Windows platform images: %d, Total: %d\n",
		len(uniqueLinuxImages), windowsImageCount, totalImageCount)

	result := make([]string, 0, totalImageCount)
	result = append(result, uniqueLinuxImages...)
	for i := 0; i < windowsImageCount; i++ {
		result = append(result, implementation.OfflineUsage.WindowsResources.AdditionalImages[i])
	}

	return result, nil
}

// GetOmittedImagesForFlag resolves the container images declared by the 'omittedImages' block of
// the given enable-command CLI flag. It mirrors exactly what 'k2s addons import --omit <flag>'
// considers prunable: the images referenced by the Kubernetes manifests listed in 'fromFiles'
// plus the 'explicit' escape-hatch entries.
//
// Resolving the images from the shipped manifests instead of hard-coding tags keeps the E2E
// expectations in sync with the addon definitions - an image version bump must not require a
// test change.
func (info *AddonsAdditionalInfo) GetOmittedImagesForFlag(implementation addons.Implementation, flagName string) []string {
	flag := findEnableCliFlag(implementation, flagName)
	Expect(flag).ToNot(BeNil(), "implementation '%s' must declare the enable flag '--%s'", implementation.Name, flagName)
	Expect(flag.OmittedImages).ToNot(BeNil(), "enable flag '--%s' of '%s' must declare omittedImages", flagName, implementation.Name)

	var images []string

	for _, relativePath := range flag.OmittedImages.FromFiles {
		absolutePath := relativePath
		if !filepath.IsAbs(relativePath) {
			absolutePath = filepath.Join(implementation.Directory, relativePath)
		}
		images = append(images, imagesFromYamlFile(absolutePath)...)
	}

	images = append(images, flag.OmittedImages.Explicit...)

	images = lo.Uniq(lo.FilterMap(images, func(image string, _ int) (string, bool) {
		trimmed := strings.Trim(strings.TrimSpace(image), `"'`)
		return trimmed, trimmed != ""
	}))

	Expect(images).ToNot(BeEmpty(),
		"omittedImages of '--%s' (%s) must resolve to at least one image, otherwise '--omit %s' would prune nothing",
		flagName, implementation.Name, flagName)

	GinkgoWriter.Printf("Resolved %d omitted image(s) for '%s --%s': %v\n", len(images), implementation.Name, flagName, images)

	return images
}

// imagesFromAdditionalImagesFiles resolves the images declared by the manifests listed in
// 'offline_usage.linux.additionalImagesFiles'.
//
// It deliberately uses the same extraction as GetOmittedImagesForFlag, i.e. only container
// 'image:' declarations are considered. Images that a manifest merely references through
// container args (e.g. cert-manager's '--acme-http01-solver-image') are pulled on demand at
// runtime and are therefore not part of the exported OCI artifact - expecting them on a node
// after an import would always fail. Mixing both extraction styles previously put such an
// image into the 'remaining images' set of the '--omit' specs while leaving it out of the
// omitted set.
func imagesFromAdditionalImagesFiles(implementation addons.Implementation) []string {
	var images []string

	for _, relativePath := range implementation.OfflineUsage.LinuxResources.AdditionalImagesFiles {
		absolutePath := relativePath
		if !filepath.IsAbs(relativePath) {
			absolutePath = filepath.Join(implementation.Directory, relativePath)
		}

		images = append(images, imagesFromYamlFile(absolutePath)...)
	}

	return lo.Uniq(images)
}

// findEnableCliFlag returns the 'enable' command CLI flag with the given name, or nil.
func findEnableCliFlag(implementation addons.Implementation, flagName string) *addons.CliFlag {
	if implementation.Commands == nil {
		return nil
	}

	enableCmd, found := (*implementation.Commands)["enable"]
	if !found || enableCmd.Cli == nil {
		return nil
	}

	for i := range enableCmd.Cli.Flags {
		if enableCmd.Cli.Flags[i].Name == flagName {
			return &enableCmd.Cli.Flags[i]
		}
	}

	return nil
}

// imagesFromYamlFile extracts the container images declared in a (possibly multi-document)
// Kubernetes manifest file.
func imagesFromYamlFile(path string) []string {
	content, err := os.ReadFile(path)
	Expect(err).ToNot(HaveOccurred(), "should be able to read manifest '%s'", path)

	var images []string
	decoder := yaml.NewDecoder(strings.NewReader(string(content)))

	for {
		var doc interface{}
		if err := decoder.Decode(&doc); err != nil {
			if err == io.EOF {
				break
			}
			GinkgoWriter.Printf("Warning: Failed to parse YAML document in file %s: %v\n", path, err)
			break
		}
		images = append(images, extractImagesFromYAMLContent(doc)...)
	}

	return images
}

// recursively extracts container image references from parsed YAML content
func extractImagesFromYAMLContent(content interface{}) []string {
	var images []string

	switch v := content.(type) {
	case map[string]interface{}:
		for key, value := range v {
			if key == "image" {
				// Only extract if the value is a string (actual image reference)
				if imageStr, ok := value.(string); ok && imageStr != "" {
					images = append(images, imageStr)
				}
			}
			// Recursively process nested structures
			images = append(images, extractImagesFromYAMLContent(value)...)
		}
	case []interface{}:
		// Process arrays
		for _, item := range v {
			images = append(images, extractImagesFromYAMLContent(item)...)
		}
	}

	return images
}

func Foreach(addons addons.Addons, iteratee func(addonName, implementationName, cmdName string)) {
	for _, addon := range addons {
		for _, implementation := range addon.Spec.Implementations {
			implementationName := ""
			if addon.Metadata.Name != implementation.Name {
				implementationName = implementation.Name
			}

			GinkgoWriter.Println("Looping at", implementation.AddonsCmdName)

			iteratee(addon.Metadata.Name, implementationName, implementation.AddonsCmdName)
		}
	}
}

// loadK2sCACertFromCluster fetches the CA certificate directly from the Kubernetes
// cluster secret, bypassing the Windows cert store entirely. This avoids issues with
// Go's x509.SystemCertPool() caching and Windows CryptoAPI cert store round-trips.
func loadK2sCACertFromCluster() *x509.CertPool {
	rootDir, err := sos.RootDir()
	if err != nil {
		GinkgoWriter.Printf("Warning: Failed to get root dir for kubectl: %v\n", err)
		return nil
	}

	kubectlPath := filepath.Join(rootDir, "bin", "kube", "kubectl.exe")
	out, err := exec.Command(kubectlPath, "-n", "cert-manager", "get", "secrets",
		"ca-issuer-root-secret", "-o", "jsonpath={.data.ca\\.crt}").Output()
	if err != nil {
		GinkgoWriter.Printf("Warning: Failed to get CA cert from cluster: %v\n", err)
		return nil
	}

	caCertPEM, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		GinkgoWriter.Printf("Warning: Failed to decode CA cert: %v\n", err)
		return nil
	}

	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caCertPEM) {
		GinkgoWriter.Printf("Warning: Failed to parse CA cert PEM\n")
		return nil
	}

	GinkgoWriter.Printf("Successfully loaded K2s CA cert from cluster secret\n")
	return pool
}

// createHTTPClientWithWindowsCerts creates an HTTP client that trusts the K2s CA.
// It fetches the CA cert directly from the Kubernetes cluster secret to avoid
// Windows cert store read-back issues and Go cert pool caching.
func createHTTPClientWithWindowsCerts(timeout time.Duration) *http.Client {
	rootCAs := loadK2sCACertFromCluster()
	if rootCAs == nil {
		// Fallback to system cert pool if kubectl is not available
		var err error
		rootCAs, err = x509.SystemCertPool()
		if err != nil {
			GinkgoWriter.Printf("Warning: Failed to load system cert pool: %v. Using default TLS.\n", err)
			return &http.Client{Timeout: timeout}
		}
	}

	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs: rootCAs,
			},
		},
	}
}

func waitForKeycloakReady(keycloakServer, realm string) error {
	realmUrl := fmt.Sprintf("%s/keycloak/realms/%s", keycloakServer, realm)
	tokenUrl := fmt.Sprintf("%s/keycloak/realms/%s/protocol/openid-connect/token", keycloakServer, realm)
	maxRetries := 30 // Wait up to 5 minutes (30 * 10s)

	GinkgoWriter.Printf("Checking Keycloak readiness at %s\n", realmUrl)

	// Create HTTP client with Windows certificate store trust
	client := createHTTPClientWithWindowsCerts(10 * time.Second)

	for attempt := 1; attempt <= maxRetries; attempt++ {
		resp, err := client.Get(realmUrl)
		if err != nil {
			GinkgoWriter.Printf("Readiness check %d/%d: Failed to connect to Keycloak: %v\n", attempt, maxRetries, err)
		} else {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				// Verify client auth actually works — Keycloak may be pod-Ready but still
				// committing client config from PostgreSQL, causing unauthorized_client errors.
				data := url.Values{}
				data.Set("client_id", "demo-client")
				data.Set("client_secret", "1f3QCCQoDQXEwU7ngw9X8kaSe1uX8EIl")
				data.Set("username", "demo-user")
				data.Set("password", "password")
				data.Set("grant_type", "password")

				req, reqErr := http.NewRequest("POST", tokenUrl, strings.NewReader(data.Encode()))
				if reqErr != nil {
					GinkgoWriter.Printf("Readiness check %d/%d: Failed to build token request: %v\n", attempt, maxRetries, reqErr)
				} else {
					req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
					tokenResp, tokenErr := client.Do(req)
					if tokenErr != nil {
						GinkgoWriter.Printf("Readiness check %d/%d: Token request failed: %v\n", attempt, maxRetries, tokenErr)
					} else {
						tokenResp.Body.Close()
						if tokenResp.StatusCode == http.StatusOK {
							GinkgoWriter.Printf("Keycloak is ready (realm accessible and client auth successful) after %d attempts\n", attempt)
							return nil
						}
						GinkgoWriter.Printf("Readiness check %d/%d: Client auth not yet ready (status: %d)\n", attempt, maxRetries, tokenResp.StatusCode)
					}
				}
			} else {
				GinkgoWriter.Printf("Readiness check %d/%d: Realm not ready (status: %d)\n", attempt, maxRetries, resp.StatusCode)
			}
		}

		if attempt < maxRetries {
			backoffTime := 10 * time.Second
			GinkgoWriter.Printf("Waiting %v before next readiness check...\n", backoffTime)
			time.Sleep(backoffTime)
		}
	}

	return fmt.Errorf("keycloak did not become ready after %d attempts", maxRetries)
}

func GetKeycloakToken() (string, error) {
	keycloakServer := "https://k2s.cluster.local"
	realm := "demo-app"
	clientId := "demo-client"
	clientSecret := "1f3QCCQoDQXEwU7ngw9X8kaSe1uX8EIl"
	username := "demo-user"
	password := "password"
	tokenUrl := fmt.Sprintf("%s/keycloak/realms/%s/protocol/openid-connect/token", keycloakServer, realm)

	// First, wait for Keycloak to be fully operational
	if err := waitForKeycloakReady(keycloakServer, realm); err != nil {
		return "", fmt.Errorf("keycloak is not ready: %v", err)
	}

	data := url.Values{}
	data.Set("client_id", clientId)
	data.Set("client_secret", clientSecret)
	data.Set("username", username)
	data.Set("password", password)
	data.Set("grant_type", "password")

	GinkgoWriter.Printf("Getting Keycloak token from %s\n", tokenUrl)

	maxRetries := 15 // Increased from 10 to handle sporadic failures
	// Create HTTP client with Windows certificate store trust
	client := createHTTPClientWithWindowsCerts(30 * time.Second)

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequest("POST", tokenUrl, strings.NewReader(data.Encode()))
		if err != nil {
			return "", fmt.Errorf("failed to create request: %v", err)
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		resp, err := client.Do(req)
		if err != nil {
			if attempt == maxRetries {
				return "", fmt.Errorf("failed to get token after %d attempts: %v", maxRetries, err)
			}
			GinkgoWriter.Printf("Attempt %d/%d: Failed to get token: %v\n", attempt, maxRetries, err)
			// Add jitter to avoid thundering herd
			backoffTime := time.Duration(attempt*5) * time.Second
			jitter := time.Duration(attempt*500) * time.Millisecond
			totalWait := backoffTime + jitter
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", totalWait)
			time.Sleep(totalWait)
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			responseBody := new(strings.Builder)
			io.Copy(responseBody, resp.Body)

			if attempt == maxRetries {
				return "", fmt.Errorf("failed to get token after %d attempts: %s - Response: %s",
					maxRetries, resp.Status, responseBody.String())
			}
			GinkgoWriter.Printf("Attempt %d/%d: Unexpected status code: %s\n", attempt, maxRetries, resp.Status)
			GinkgoWriter.Printf("Response headers: %v\n", resp.Header)
			GinkgoWriter.Printf("Response body: %s\n", responseBody.String())

			// Use the same improved backoff with jitter for HTTP errors
			backoffTime := time.Duration(attempt*5) * time.Second
			jitter := time.Duration(attempt*500) * time.Millisecond
			totalWait := backoffTime + jitter
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", totalWait)
			time.Sleep(totalWait)
			continue
		}

		var result map[string]interface{}
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			return "", fmt.Errorf("failed to parse token response: %v", err)
		}
		accessToken, ok := result["access_token"].(string)
		if !ok {
			return "", fmt.Errorf("failed to parse access token")
		}

		// Log token expiration if available
		if exp, ok := result["expires_in"].(float64); ok {
			GinkgoWriter.Printf("Token expires in %.0f seconds\n", exp)
		}

		tokenLength := len(accessToken)
		GinkgoWriter.Printf("Successfully got token (length: %d chars) on attempt %d/%d\n",
			tokenLength, attempt, maxRetries)
		if tokenLength > 20 {
			GinkgoWriter.Printf("Token preview: %s...\n", accessToken[:20])
		}

		return accessToken, nil
	}

	return "", fmt.Errorf("failed to get token after %d attempts", maxRetries)
}

func VerifyDeploymentReachableFromHostWithStatusCode(ctx context.Context, expectedStatusCode int, url string, headers ...map[string]string) {
	// Create an HTTP client with Windows certificate store trust for proper TLS handling
	client := createHTTPClientWithWindowsCerts(30 * time.Second)

	// Retry mechanism
	maxRetries := 5
	for attempt := 1; attempt <= maxRetries; attempt++ {
		// Create a new HTTP request
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		Expect(err).ToNot(HaveOccurred(), "Failed to create HTTP request")

		// Add headers if provided
		if len(headers) > 0 {
			for key, value := range headers[0] {
				req.Header.Add(key, value)
				// For Authorization headers, log a truncated version for debugging
				if key == "Authorization" && strings.HasPrefix(value, "Bearer ") {
					tokenLength := len(value) - 7 // "Bearer " is 7 chars
					truncLength := 20
					if tokenLength > truncLength {
						GinkgoWriter.Printf("Using token: Bearer %s...\n", value[7:7+truncLength])
					} else {
						GinkgoWriter.Printf("Using token: %s\n", value)
					}
				}
			}
		}

		// Perform the HTTP request
		resp, err := client.Do(req)
		if err != nil {
			GinkgoWriter.Printf("Attempt %d/%d: Failed to perform HTTP request: %v\n", attempt, maxRetries, err)
		} else {
			defer resp.Body.Close()

			// Read response body for error reporting
			responseBody, readErr := strings.Builder{}, error(nil)
			if resp.StatusCode != expectedStatusCode {
				bodyBytes := make([]byte, 1024) // Read up to 1KB of response
				n, err := resp.Body.Read(bodyBytes)
				if err != nil && err.Error() != "EOF" {
					readErr = err
				}
				responseBody.Write(bodyBytes[:n])
			}

			// Check the status code
			if resp.StatusCode == expectedStatusCode {
				GinkgoWriter.Printf("Attempt %d/%d: Received expected status code %d\n", attempt, maxRetries, expectedStatusCode)
				return
			}

			GinkgoWriter.Printf("Attempt %d/%d: Unexpected status code: %d %s (expected %d)\n",
				attempt, maxRetries, resp.StatusCode, resp.Status, expectedStatusCode)
			GinkgoWriter.Printf("Response headers: %v\n", resp.Header)

			if readErr != nil {
				GinkgoWriter.Printf("Failed to read response body: %v\n", readErr)
			} else if responseBody.Len() > 0 {
				GinkgoWriter.Printf("Response body: %s\n", responseBody.String())
			}
		}

		// Pause before the next attempt with exponential backoff
		if attempt < maxRetries {
			backoffTime := time.Duration(attempt*5) * time.Second
			GinkgoWriter.Printf("Waiting %v before next attempt...\n", backoffTime)
			time.Sleep(backoffTime)
		}
	}

	// Fail the test if all retries are exhausted
	Fail(fmt.Sprintf("Failed to receive expected status code %d after %d attempts", expectedStatusCode, maxRetries))
}
