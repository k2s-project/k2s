// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"net"
	"testing"

	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/healthcheck"
)

func fakeWindowsHealthCheckFuncs(checkedPaths *[]string) windowsHealthCheckFuncs {
	return windowsHealthCheckFuncs{
		diskInfo: func(path string) (healthcheck.DiskInfo, error) {
			*checkedPaths = append(*checkedPaths, path)
			return healthcheck.DiskInfo{VolumeID: path, FreeBytes: healthcheck.LowFreeDiskBytes}, nil
		},
		networkInterfaces: func() ([]healthcheck.NetworkInterface, error) {
			return []healthcheck.NetworkInterface{{Name: "Ethernet", Up: true, Addresses: []net.IP{net.ParseIP("192.168.0.2")}}}, nil
		},
		serviceRunning: func(string) (bool, error) { return true, nil },
	}
}

func resultsByName(report healthcheck.Report) map[string]healthcheck.Result {
	results := make(map[string]healthcheck.Result, len(report.Results))
	for _, result := range report.Results {
		results[result.Name] = result
	}
	return results
}

func TestWindowsHealthChecksForHyperVSetup(t *testing.T) {
	var checkedPaths []string
	checks := windowsHealthChecks(SystemCheckConfig{
		ClusterName:    "k2s-cluster",
		KubeconfigPath: `C:\missing\config`,
		SetupName:      definitions.SetupNameK2s,
	}, `D:\k2s`, `C:\ProgramData\K2s`, fakeWindowsHealthCheckFuncs(&checkedPaths))

	results := resultsByName(healthcheck.Run(checks))

	expectedStatuses := map[string]healthcheck.Status{
		"host-disk-space":      healthcheck.StatusPass,
		"apipa-address":        healthcheck.StatusPass,
		"hyperv-vmms":          healthcheck.StatusPass,
		"cluster-certificates": healthcheck.StatusSkip, // kubeconfig does not exist
	}
	if len(results) != len(expectedStatuses) {
		t.Fatalf("unexpected checks: %v", results)
	}
	for name, status := range expectedStatuses {
		if results[name].Status != status {
			t.Errorf("check %q: expected status %q, got %q (%s)", name, status, results[name].Status, results[name].Message)
		}
	}

	expectedPaths := []string{`C:\`, `D:\k2s`, `C:\ProgramData\K2s`}
	if len(checkedPaths) != len(expectedPaths) {
		t.Fatalf("expected disk paths %v, got %v", expectedPaths, checkedPaths)
	}
	for i := range expectedPaths {
		if checkedPaths[i] != expectedPaths[i] {
			t.Fatalf("expected disk paths %v, got %v", expectedPaths, checkedPaths)
		}
	}
}

func TestWindowsHealthChecksSkipHyperVForWsl(t *testing.T) {
	var checkedPaths []string
	funcs := fakeWindowsHealthCheckFuncs(&checkedPaths)
	funcs.serviceRunning = func(string) (bool, error) {
		t.Fatal("Hyper-V service must not be queried for WSL setups")
		return false, nil
	}

	checks := windowsHealthChecks(SystemCheckConfig{SetupName: definitions.SetupNameK2s, WslEnabled: true}, `C:\k2s`, `C:\ProgramData\K2s`, funcs)

	result := resultsByName(healthcheck.Run(checks))["hyperv-vmms"]
	if result.Status != healthcheck.StatusSkip {
		t.Fatalf("expected Hyper-V check to be skipped for WSL, got %q (%s)", result.Status, result.Message)
	}
}

func TestWindowsHealthChecksSkipCertificatesAndApipaForBuildOnlySetup(t *testing.T) {
	var checkedPaths []string
	checks := windowsHealthChecks(SystemCheckConfig{SetupName: definitions.SetupNameBuildOnlyEnv}, `C:\k2s`, `C:\ProgramData\K2s`, fakeWindowsHealthCheckFuncs(&checkedPaths))

	results := resultsByName(healthcheck.Run(checks))

	if result := results["cluster-certificates"]; result.Status != healthcheck.StatusSkip || result.Message != "not applicable, the build-only setup has no Kubernetes cluster" {
		t.Fatalf("expected certificates check to be skipped for build-only setup, got %q (%s)", result.Status, result.Message)
	}
	if result := results["apipa-address"]; result.Status != healthcheck.StatusSkip {
		t.Fatalf("expected APIPA check to be skipped for build-only setup, got %q (%s)", result.Status, result.Message)
	}
	if result := results["hyperv-vmms"]; result.Status != healthcheck.StatusPass {
		t.Fatalf("expected Hyper-V check to run for build-only setup, got %q (%s)", result.Status, result.Message)
	}
}

func TestWindowsHealthChecksSkipApipaForLinuxOnlySetup(t *testing.T) {
	var checkedPaths []string
	funcs := fakeWindowsHealthCheckFuncs(&checkedPaths)
	funcs.networkInterfaces = func() ([]healthcheck.NetworkInterface, error) {
		t.Fatal("network interfaces must not be listed for Linux-only setups")
		return nil, nil
	}

	checks := windowsHealthChecks(SystemCheckConfig{SetupName: definitions.SetupNameK2s, LinuxOnly: true}, `C:\k2s`, `C:\ProgramData\K2s`, funcs)

	result := resultsByName(healthcheck.Run(checks))["apipa-address"]
	if result.Status != healthcheck.StatusSkip || result.Message != "not applicable, the setup has no Windows node" {
		t.Fatalf("expected APIPA check to be skipped for Linux-only setup, got %q (%s)", result.Status, result.Message)
	}
}
