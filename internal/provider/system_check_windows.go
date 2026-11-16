// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

import (
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/healthcheck"
	"github.com/k2s-project/k2s/internal/host"
)

// Check runs the Windows host health checks. Nothing on the system is modified.
func (p *windowsSystemProvider) Check(cfg SystemCheckConfig) (healthcheck.Report, error) {
	return healthcheck.Run(windowsHealthChecks(cfg, p.installDir, p.configDir, windowsHealthCheckFuncs{
		diskInfo:          healthcheck.GetDiskInfo,
		networkInterfaces: healthcheck.GetNetworkInterfaces,
		serviceRunning:    healthcheck.IsServiceRunning,
	})), nil
}

type windowsHealthCheckFuncs struct {
	diskInfo          healthcheck.DiskInfoFunc
	networkInterfaces healthcheck.NetworkInterfacesFunc
	serviceRunning    healthcheck.ServiceRunningFunc
}

func windowsHealthChecks(cfg SystemCheckConfig, installDir, configDir string, funcs windowsHealthCheckFuncs) []healthcheck.Check {
	isBuildOnly := cfg.SetupName == definitions.SetupNameBuildOnlyEnv

	// An APIPA address breaks the creation of the 'cbr0' switch by flannel, which only runs with a Windows node.
	apipaCheck := healthcheck.NewApipaCheck(funcs.networkInterfaces)
	if cfg.LinuxOnly || isBuildOnly {
		apipaCheck = healthcheck.NewSkippedCheck(apipaCheck, "not applicable, the setup has no Windows node")
	}

	hyperVCheck := healthcheck.NewHyperVServiceCheck(funcs.serviceRunning)
	if cfg.WslEnabled {
		hyperVCheck = healthcheck.NewSkippedCheck(hyperVCheck, "not applicable, the control-plane runs in WSL")
	}

	certificatesCheck := healthcheck.NewCertificatesCheck(healthcheck.CertificatesCheckConfig{
		KubeconfigPath: cfg.KubeconfigPath,
		ClusterName:    cfg.ClusterName,
	})
	if isBuildOnly {
		certificatesCheck = healthcheck.NewSkippedCheck(certificatesCheck, "not applicable, the build-only setup has no Kubernetes cluster")
	}

	return []healthcheck.Check{
		healthcheck.NewDiskSpaceCheck([]string{host.SystemDrive(), installDir, configDir}, funcs.diskInfo),
		apipaCheck,
		hyperVCheck,
		certificatesCheck,
	}
}
