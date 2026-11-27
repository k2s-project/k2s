// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package httpproxy_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
	"github.com/k2s-project/k2s/test/framework/dsl"
)

const httpProxyPort = 8181

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestStartHttpProxy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "start httpproxy CLI Command Acceptance Tests", Label("cli", "start", "httpproxy", "acceptance", "setup-required", "invasive", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	if runtime.GOOS != "windows" {
		Skip("httpproxy Windows NSSM tests are supported only on Windows")
	}

	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(20*time.Minute))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)

	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		Skip("Linux-only setup, Windows httpproxy NSSM tests not supported")
	}
})

var _ = Describe("start httpproxy", Ordered, func() {
	It("starts stopped httpproxy service via k2s start and verifies port 8181 ownership", func(ctx context.Context) {
		By("stopping httpproxy service before running k2s start")
		stopHttpProxyService(ctx, suite.RootDir())

		By("running k2s start")
		k2s.Start(ctx).ExpectSuccess()

		By("verifying httpproxy is running, accepting TCP connections on port 8181, and owned by NSSM-managed httpproxy.exe")
		expectHttpProxyRunningAndOwned(ctx, suite.RootDir())
	})

	It("fails k2s start when port 8181 is occupied by an unrelated listener and restores httpproxy on cleanup", func(ctx context.Context) {
		By("stopping httpproxy service and ensuring port 8181 is free")
		stopHttpProxyService(ctx, suite.RootDir())

		By("starting an unrelated TCP listener on 0.0.0.0:8181")
		testListener, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", httpProxyPort))
		Expect(err).NotTo(HaveOccurred(), "expected to bind conflicting listener on port %d", httpProxyPort)

		l := testListener
		acceptDone := make(chan struct{})
		go func() {
			defer close(acceptDone)
			for {
				conn, acceptErr := l.Accept()
				if acceptErr != nil {
					return
				}
				_ = conn.Close()
			}
		}()

		DeferCleanup(func(cleanupCtx context.Context) {
			_ = l.Close()
			<-acceptDone
			expectPort8181Closed(cleanupCtx)
			GinkgoWriter.Println("Restoring httpproxy and K2s cluster via k2s start..")
			k2s.Start(cleanupCtx).ExpectSuccess()
			expectHttpProxyRunningAndOwned(cleanupCtx, suite.RootDir())
		}, NodeTimeout(20*time.Minute))

		By("running k2s start while port 8181 is occupied")
		output, exitCode := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "start")
		Expect(exitCode).To(Equal(int(cli.ExitCodeFailure)))
		Expect(output).To(SatisfyAll(
			ContainSubstring("8181"),
			MatchRegexp("(?i)httpproxy"),
		), "expected actionable diagnostic output referencing httpproxy and port 8181, got:\n%s", output)
	})
})

type httpProxyListenerOwner struct {
	LocalAddress    string `json:"LocalAddress"`
	LocalPort       int    `json:"LocalPort"`
	OwningProcess   int    `json:"OwningProcess"`
	ProcessName     string `json:"ProcessName"`
	ParentProcessId int    `json:"ParentProcessId"`
	ExecutablePath  string `json:"ExecutablePath"`
}

type httpProxyServiceStatus struct {
	ServiceState     string                   `json:"ServiceState"`
	ServiceProcessId int                      `json:"ServiceProcessId"`
	Listeners        []httpProxyListenerOwner `json:"Listeners"`
}

type rawHttpProxyServiceStatus struct {
	ServiceState     string          `json:"ServiceState"`
	ServiceProcessId int             `json:"ServiceProcessId"`
	Listeners        json.RawMessage `json:"Listeners"`
}

func stopHttpProxyService(ctx context.Context, rootDir string) {
	nssmPath := filepath.Join(rootDir, "bin", "nssm.exe")
	escapedNssmPath := strings.ReplaceAll(nssmPath, "'", "''")
	stopScript := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$svc = Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    throw 'Windows service httpproxy was not found'
}
if ($svc.Status -ne 'Stopped') {
    if (Test-Path '%s') {
        $stopOut = (& '%s' stop httpproxy 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("nssm stop httpproxy exited with {0}: {1}" -f $LASTEXITCODE, $stopOut.Trim())
            Stop-Service -Name 'httpproxy' -Force -ErrorAction Stop
        }
    } else {
        Stop-Service -Name 'httpproxy' -Force -ErrorAction Stop
    }
}
`, escapedNssmPath, escapedNssmPath)

	_, err := runWindowsPowerShell(ctx, stopScript)
	Expect(err).NotTo(HaveOccurred(), "failed to stop httpproxy service")

	Eventually(func(g Gomega) {
		status, queryErr := queryHttpProxyStatus(ctx)
		g.Expect(queryErr).NotTo(HaveOccurred())
		g.Expect(status.ServiceState).To(Equal("Stopped"))
		g.Expect(status.Listeners).To(BeEmpty(), "expected no TCP listeners on port %d after stopping httpproxy", httpProxyPort)
	}, 45*time.Second, 500*time.Millisecond).Should(Succeed())

	expectPort8181Closed(ctx)
}

func expectPort8181Closed(ctx context.Context) {
	Eventually(func(g Gomega) {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", httpProxyPort), 500*time.Millisecond)
		if conn != nil {
			_ = conn.Close()
		}
		g.Expect(err).To(HaveOccurred(), "expected port %d to be closed", httpProxyPort)
	}, 15*time.Second, 250*time.Millisecond).Should(Succeed())
}

func expectHttpProxyRunningAndOwned(ctx context.Context, rootDir string) {
	expectedExePath := filepath.Join(rootDir, "bin", "httpproxy.exe")

	Eventually(func(g Gomega) {
		status, err := queryHttpProxyStatus(ctx)
		g.Expect(err).NotTo(HaveOccurred())
		g.Expect(status.ServiceState).To(Equal("Running"), "expected httpproxy Windows service to be Running")
		g.Expect(status.ServiceProcessId).To(BeNumerically(">", 0), "expected httpproxy NSSM service PID to be > 0")
		g.Expect(status.Listeners).NotTo(BeEmpty(), "expected at least one TCP listener on port %d", httpProxyPort)

		for _, listener := range status.Listeners {
			g.Expect(listener.LocalPort).To(Equal(httpProxyPort))
			g.Expect(strings.ToLower(listener.ProcessName)).To(Equal("httpproxy.exe"),
				"expected listener on %s:%d (PID %d) to be owned by httpproxy.exe, got %q",
				listener.LocalAddress, listener.LocalPort, listener.OwningProcess, listener.ProcessName)
			g.Expect(listener.ParentProcessId).To(Equal(status.ServiceProcessId),
				"expected httpproxy.exe (PID %d) to be a child of NSSM service process (PID %d), got parent PID %d",
				listener.OwningProcess, status.ServiceProcessId, listener.ParentProcessId)
			if listener.ExecutablePath != "" {
				g.Expect(strings.EqualFold(filepath.Clean(listener.ExecutablePath), filepath.Clean(expectedExePath))).To(BeTrue(),
					"expected httpproxy.exe path %q, got %q", expectedExePath, listener.ExecutablePath)
			}
		}

		conn, dialErr := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", httpProxyPort), 3*time.Second)
		g.Expect(dialErr).NotTo(HaveOccurred(), "expected local TCP connection to 127.0.0.1:%d to succeed", httpProxyPort)
		_ = conn.Close()
	}, 30*time.Second, 500*time.Millisecond).Should(Succeed())
}

func queryHttpProxyStatus(ctx context.Context) (*httpProxyServiceStatus, error) {
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='httpproxy'" -ErrorAction Stop
if ($null -eq $svc) {
    throw 'Windows service httpproxy was not found'
}
$listeners = @(Get-NetTCPConnection -LocalPort %d -State Listen -ErrorAction SilentlyContinue)
$owners = @()
foreach ($listener in $listeners) {
    $proc = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f [int]$listener.OwningProcess) -ErrorAction SilentlyContinue
    $owners += [PSCustomObject]@{
        LocalAddress    = [string]$listener.LocalAddress
        LocalPort       = [int]$listener.LocalPort
        OwningProcess   = [int]$listener.OwningProcess
        ProcessName     = if ($null -ne $proc) { [string]$proc.Name } else { '' }
        ParentProcessId = if ($null -ne $proc) { [int]$proc.ParentProcessId } else { 0 }
        ExecutablePath  = if ($null -ne $proc) { [string]$proc.ExecutablePath } else { '' }
    }
}
[PSCustomObject]@{
    ServiceState     = [string]$svc.State
    ServiceProcessId = [int]$svc.ProcessId
    Listeners        = $owners
} | ConvertTo-Json -Depth 4
`, httpProxyPort)

	stdout, err := runWindowsPowerShell(ctx, script)
	if err != nil {
		return nil, err
	}

	var raw rawHttpProxyServiceStatus
	if err := json.Unmarshal([]byte(stdout), &raw); err != nil {
		return nil, fmt.Errorf("parse httpproxy status JSON (%q): %w", stdout, err)
	}

	listeners, err := parseHttpProxyListeners(raw.Listeners)
	if err != nil {
		return nil, fmt.Errorf("parse httpproxy listeners JSON (%q): %w", string(raw.Listeners), err)
	}

	return &httpProxyServiceStatus{
		ServiceState:     raw.ServiceState,
		ServiceProcessId: raw.ServiceProcessId,
		Listeners:        listeners,
	}, nil
}

func parseHttpProxyListeners(raw json.RawMessage) ([]httpProxyListenerOwner, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, nil
	}
	if trimmed[0] == '[' {
		var list []httpProxyListenerOwner
		if err := json.Unmarshal(trimmed, &list); err != nil {
			return nil, err
		}
		return list, nil
	}
	if trimmed[0] == '{' {
		var single httpProxyListenerOwner
		if err := json.Unmarshal(trimmed, &single); err != nil {
			return nil, err
		}
		return []httpProxyListenerOwner{single}, nil
	}
	return nil, errors.New("unexpected JSON shape for Listeners")
}

func runWindowsPowerShell(ctx context.Context, script string) (string, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(cmdCtx, "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.WaitDelay = time.Second

	if err := cmd.Run(); err != nil {
		return stdout.String(), fmt.Errorf("powershell command failed: %w (stderr: %s)", err, strings.TrimSpace(stderr.String()))
	}

	return strings.TrimSpace(stdout.String()), nil
}
