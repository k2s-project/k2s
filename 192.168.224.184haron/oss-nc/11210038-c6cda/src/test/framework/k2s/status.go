// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package k2s

import (
	"context"
	"fmt"
	"strings"

	"github.com/k2s-project/k2s/test/framework/os"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"golang.org/x/text/encoding/unicode"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

type StatusChecker struct {
	newCliFunc func(cliPath string) *os.CliExecutor
	setupInfo  *SetupInfo
}

var winServices = []string{"flanneld", "kubelet", "kubeproxy"}

func NewStatusChecker(newCliFunc func(cliPath string) *os.CliExecutor, setupInfo *SetupInfo) *StatusChecker {
	return &StatusChecker{
		newCliFunc: newCliFunc,
		setupInfo:  setupInfo,
	}
}

// IsK2sRunning checks whether the K2s system is running and prints the status to GinkgoWriter.
func (sc *StatusChecker) IsK2sRunning(ctx context.Context) bool {
	GinkgoWriter.Println("Checking K2s system status..")

	sc.setupInfo.ReloadRuntimeConfig()

	var controlPlaneRunning bool
	if sc.setupInfo.RuntimeConfig.InstallConfig().WslEnabled() {
		controlPlaneRunning = sc.isWslRunning(ctx)
	} else {
		controlPlaneRunning = sc.isVmRunning(ctx)
	}

	if sc.setupInfo.RuntimeConfig.InstallConfig().LinuxOnly() {
		return controlPlaneRunning
	}

	isRunning := controlPlaneRunning && areWinServicesRunning()

	GinkgoWriter.Println("K2s system running:", isRunning)

	return isRunning
}

func (sc *StatusChecker) isVmRunning(ctx context.Context) bool {
	GinkgoWriter.Println("Checking VM status for control-plane..")

	cmd := fmt.Sprintf("(Get-VM -Name %s).State", sc.setupInfo.RuntimeConfig.ControlPlaneConfig().Hostname())

	output := sc.newCliFunc("powershell").NoStdOut().MustExec(ctx, cmd)

	isRunning := strings.TrimSuffix(output, "\r\n") == "Running"

	GinkgoWriter.Println("VM running:", isRunning)

	return isRunning
}

func (sc *StatusChecker) isWslRunning(ctx context.Context) bool {
	GinkgoWriter.Println("Checking WSL status for control-plane..")

	output := sc.newCliFunc("wsl.exe").MustExec(ctx, "-l", "-q", "--running")

	utf8Bytes, err := unicode.UTF16(unicode.LittleEndian, unicode.IgnoreBOM).NewDecoder().String(output)
	Expect(err).ToNot(HaveOccurred())

	distros := strings.Split(string(utf8Bytes), "\r\n")

	isRunning := false

	for _, distro := range distros {
		if strings.EqualFold(distro, sc.setupInfo.RuntimeConfig.ControlPlaneConfig().Hostname()) {
			isRunning = true
			break
		}
	}

	GinkgoWriter.Println("WSL running:", isRunning)

	return isRunning
}

func areWinServicesRunning() bool {
	manager, err := mgr.Connect()
	Expect(err).ToNot(HaveOccurred())
	defer manager.Disconnect()

	for _, serviceName := range winServices {
		isRunning := isWinServiceRunning(manager, serviceName)

		if !isRunning {
			return false
		}
	}
	return true
}

func isWinServiceRunning(manager *mgr.Mgr, serviceName string) bool {
	GinkgoWriter.Println("Checking Windows service <", serviceName, ">..")

	service, err := manager.OpenService(serviceName)
	Expect(err).ToNot(HaveOccurred())
	defer service.Close()

	status, err := service.Query()
	Expect(err).ToNot(HaveOccurred())

	isRunning := status.State == svc.Running

	GinkgoWriter.Println("Windows service <", serviceName, "> running:", isRunning)

	return isRunning
}
