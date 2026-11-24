// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package exportimport

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type probeResult struct {
	label     string
	url       string
	reachable bool
	detail    string
}

func (p probeResult) String() string { return p.label + " " + p.url }

// probeInternetConnectivity probes the connectivity the offline import relies on: the Windows host (direct and via
// the K2s HTTP proxy, as used by Invoke-DownloadFile) and the control plane (via the K2s HTTP proxy, as used by
// apt/curl, and directly). It never fails on reachability, it only reports.
func probeInternetConnectivity(ctx context.Context, suite *framework.K2sTestSuite, controlPlaneIP string) []probeResult {
	kubeSwitch, err := config.ReadKubeSwitchConfig(suite.RootDir())
	Expect(err).ToNot(HaveOccurred(), "[AirGap] failed to read the K2s host (KubeSwitch) address")
	k2sProxy := fmt.Sprintf("http://%s:8181", kubeSwitch.Address)
	GinkgoWriter.Printf("[AirGap] K2s HTTP proxy: %s, probe targets: %v\n", k2sProxy, airGapProbeUrls)

	var results []probeResult

	// Host probes (Windows PowerShell, TLS 1.2, 15s timeout).
	quotedUrls := make([]string, len(airGapProbeUrls))
	for i, url := range airGapProbeUrls {
		quotedUrls[i] = "'" + url + "'"
	}
	script := fmt.Sprintf(`$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Test-Probe([string]$Label, [string]$Url, [string]$Proxy) {
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = 15000
        if ($Proxy) { $request.Proxy = New-Object System.Net.WebProxy($Proxy) } else { $request.Proxy = $null }
        $response = $request.GetResponse()
        $response.Close()
        Write-Output ('%[1]s|{0}|{1}|REACHABLE|' -f $Label, $Url)
    } catch {
        Write-Output ('%[1]s|{0}|{1}|BLOCKED|{2}' -f $Label, $Url, ($_.Exception.Message -replace '[\r\n]+', ' '))
    }
}
foreach ($url in @(%[2]s)) {
    Test-Probe 'host-direct' $url ''
    Test-Probe 'host-via-k2s-proxy' $url '%[3]s'
}`, airGapProbeMarker, strings.Join(quotedUrls, ","), k2sProxy)

	hostOutput := suite.Cli("powershell").MustExec(ctx, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script)
	hostMatches := hostProbeRegex.FindAllStringSubmatch(hostOutput, -1)
	Expect(hostMatches).To(HaveLen(2*len(airGapProbeUrls)), "[AirGap] every host connectivity probe must report a result, output: %s", hostOutput)
	for _, m := range hostMatches {
		results = append(results, probeResult{label: m[1], url: m[2], reachable: m[3] == "REACHABLE", detail: strings.TrimSpace(m[4])})
	}

	// Control plane probes: exit code 0 of curl means the internet is reachable.
	vmProbes := []struct{ label, curlArgs string }{
		{"vm-via-k2s-proxy", "-x " + k2sProxy},
		{"vm-direct", "--noproxy '*'"},
	}
	for _, probe := range vmProbes {
		for _, url := range airGapProbeUrls {
			cmd := fmt.Sprintf("curl -sS -I -m 10 %s -o /dev/null %s; echo \"%s label=%s exit=$?\"", probe.curlArgs, url, airGapProbeMarker, probe.label)
			output, _ := suite.K2sCli().Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", cmd, "-r")

			match := vmProbeRegex.FindStringSubmatch(output)
			Expect(match).ToNot(BeNil(), "[AirGap] probe %s %s must report a result, output: %s", probe.label, url, output)
			Expect(match[2]).ToNot(Equal("127"), "[AirGap] curl must be available on the control plane to probe connectivity")
			results = append(results, probeResult{label: probe.label, url: url, reachable: match[2] == "0", detail: "curl exit " + match[2]})
		}
	}

	for _, r := range results {
		state := "BLOCKED"
		if r.reachable {
			state = "REACHABLE"
		}
		GinkgoWriter.Printf("[AirGap] probe %-20s %-28s -> %s %s\n", r.label, r.url, state, r.detail)
	}
	return results
}

var k2sProxyRegex = regexp.MustCompile(`(?m)^\s*Proxy:\s*(\S+)`)

// DetectProxyUsage determines whether the machine is behind a proxy. This is the case when a K2s upstream proxy is
// configured (k2s system proxy show) or a proxy was handed to the test process via environment variables.
// Call it BEFORE RemoveProxyEnvironment, which unsets those variables.
func DetectProxyUsage(ctx context.Context, suite *framework.K2sTestSuite) (inUse bool, reasons []string) {
	for _, key := range proxyEnvironmentKeys {
		if value := os.Getenv(key); value != "" {
			reasons = append(reasons, fmt.Sprintf("environment variable %s=%s", key, value))
		}
	}

	output := suite.K2sCli().NoStdOut().MustExec(ctx, "system", "proxy", "show")
	if match := k2sProxyRegex.FindStringSubmatch(output); match != nil && !strings.HasPrefix(match[1], "<") {
		reasons = append(reasons, "K2s upstream proxy configured: "+match[1])
	}

	inUse = len(reasons) > 0
	GinkgoWriter.Printf("[AirGap] Proxy in use on this machine: %v %v\n", inUse, reasons)
	return inUse, reasons
}

// VerifyNoInternetConnectivity checks that no connectivity probe succeeds.
//
// On machines behind a proxy (proxyInUse) reachable internet is a precondition violation and fails the test.
// On machines without a proxy the internet cannot be cut off by the test and is expected to be reachable: the
// test continues, but a prominent warning is logged and added to the report, because an import that silently
// downloads missing content would then not be detected.
func VerifyNoInternetConnectivity(ctx context.Context, suite *framework.K2sTestSuite, controlPlaneIP string, proxyInUse bool) {
	GinkgoWriter.Println("=== VERIFY NO INTERNET CONNECTIVITY START ===")

	var reachable []string
	for _, r := range probeInternetConnectivity(ctx, suite, controlPlaneIP) {
		if r.reachable {
			reachable = append(reachable, r.String())
		}
	}

	switch {
	case len(reachable) == 0:
		GinkgoWriter.Println("[AirGap] VERIFIED: no internet connectivity from host and control plane")
	case proxyInUse:
		Fail(fmt.Sprintf("air-gapped precondition violated: internet is reachable although a proxy is used (%v). "+
			"Block the internet access behind the proxy or disconnect the machine before running this test", reachable))
	default:
		warning := fmt.Sprintf("NO PROXY IS USED ON THIS MACHINE AND REAL INTERNET CONNECTIVITY IS STILL AVAILABLE (%v). "+
			"The air-gapped precondition 'no internet' is NOT met: an import that downloads missing content from the "+
			"internet instead of using the OCI artifact will NOT be detected by this test. Run it on a proxy-based or "+
			"disconnected machine to get a reliable result.", reachable)
		banner := strings.Repeat("!", 100)
		GinkgoWriter.Printf("\n%s\n[AirGap] WARNING: %s\n%s\n\n", banner, warning, banner)
		AddReportEntry("AIR-GAP WARNING: internet connectivity available", warning)
	}

	GinkgoWriter.Println("=== VERIFY NO INTERNET CONNECTIVITY END ===")
}

// LogAirGapState logs, without asserting, the state the import is about to start from: internet connectivity,
// the addon folder and Windows packages in the K2s directory, the staged packages on the control plane, the
// container runtime contents (images of all nodes) and the registry mirror configuration.
// Call it right before the import so that a failing import can be correlated with its preconditions.
func LogAirGapState(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, addon *addons.Addon, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== AIR-GAP STATE BEFORE IMPORT START ===")

	GinkgoWriter.Println("[AirGapState] --- internet connectivity ---")
	if proxyInUse, reasons := DetectProxyUsage(ctx, suite); proxyInUse {
		GinkgoWriter.Printf("[AirGapState] proxy in use: %v\n", reasons)
	} else {
		GinkgoWriter.Println("[AirGapState] no proxy in use: internet is expected to stay reachable on this machine")
	}
	reachable := 0
	for _, r := range probeInternetConnectivity(ctx, suite, controlPlaneIP) {
		if r.reachable {
			reachable++
		}
	}
	if reachable == 0 {
		GinkgoWriter.Println("[AirGapState] internet connectivity: OFFLINE (all probes blocked)")
	} else {
		GinkgoWriter.Printf("[AirGapState] internet connectivity: ONLINE, %d probe(s) reachable (air-gap precondition NOT met)\n", reachable)
	}

	GinkgoWriter.Println("[AirGapState] --- addon folder and Windows packages in the K2s directory ---")
	logPathState("addon folder", AddonFolderPath(suite.RootDir(), addon, impl))
	for _, path := range windowsCurlPackagePaths(suite.RootDir(), impl) {
		logPathState("windows curl package", path)
	}

	GinkgoWriter.Println("[AirGapState] --- staged packages on the control plane ---")
	checkCmd := fmt.Sprintf("if [ -d .%[1]s ]; then echo \"present: .%[1]s\"; ls -la .%[1]s; else echo \"absent: .%[1]s\"; fi", impl.ExportDirectoryName)
	suite.K2sCli().Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd, "-r")

	GinkgoWriter.Println("[AirGapState] --- container runtime contents (non-core images on all nodes) ---")
	images := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[AirGapState] non-core images: %d\n", len(images))
	for i, image := range images {
		GinkgoWriter.Printf("[AirGapState]   [%d] %s\n", i, image)
	}
	// Must not read the addon folder when it is absent: that terminates the test process.
	if addonImages, known := addonNonCoreImages(suite, k2sDsl, addon, impl); known {
		for _, image := range addonImages {
			present := false
			for _, onNode := range images {
				if strings.Contains(onNode, image) {
					present = true
					break
				}
			}
			GinkgoWriter.Printf("[AirGapState] addon image %s -> present=%v\n", image, present)
		}
	} else {
		GinkgoWriter.Println("[AirGapState] addon images not listed: addon folder is absent and its images were not determined earlier")
	}

	GinkgoWriter.Println("[AirGapState] --- registry mirror configuration (cfg/config.json, CRI-O drop-ins) ---")
	mirrors := ConfigJsonMirrorRegistries(suite)
	GinkgoWriter.Printf("[AirGapState] configured mirror registries: %d\n", len(mirrors))
	mirrorCmd := `grep -R "^[[:space:]]*\[\[registry\.mirror\]\]" /etc/containers/registries.conf.d 2>/dev/null || echo "no CRI-O mirror drop-ins"`
	suite.K2sCli().Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", mirrorCmd, "-r")

	GinkgoWriter.Println("=== AIR-GAP STATE BEFORE IMPORT END ===")
}

func logPathState(kind, path string) {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		GinkgoWriter.Printf("[AirGapState] %s: ABSENT %s\n", kind, path)
	case err != nil:
		GinkgoWriter.Printf("[AirGapState] %s: ERROR %s: %v\n", kind, path, err)
	case info.IsDir():
		entries, _ := os.ReadDir(path)
		GinkgoWriter.Printf("[AirGapState] %s: PRESENT %s (%d entries)\n", kind, path, len(entries))
	default:
		GinkgoWriter.Printf("[AirGapState] %s: PRESENT %s (%d bytes)\n", kind, path, info.Size())
	}
}
