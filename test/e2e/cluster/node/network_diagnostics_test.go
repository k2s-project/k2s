// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: MIT

package node

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/internal/definitions"
	v1 "k8s.io/api/core/v1"

	. "github.com/onsi/ginkgo/v2"
)

func podCommandArgs(pod, container string, command ...string) []string {
	args := []string{"exec", pod, "-n", namespace}
	if container != "" {
		args = append(args, "-c", container)
	}
	return append(append(args, "--"), command...)
}

type nodeNetworkDiagnostics struct {
	kubectl string
	sshKey  string
	nodes   []clusterconfig.Node
	run     func(context.Context, string, ...string) (string, error)
}

func collectNodeCommunicationDiagnostics(source, target v1.Pod, container string) {
	// A failed/cancelled spec must not prevent evidence collection.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	setup := suite.SetupInfo()
	diagnostics := nodeNetworkDiagnostics{
		kubectl: suite.Kubectl().Path(),
		sshKey:  setup.Config.Host().SshConfig().CurrentPrivateKeyPath(),
		run:     runNodeNetworkDiagnostic,
	}
	if setup.ClusterConfig != nil {
		diagnostics.nodes = append(diagnostics.nodes, setup.ClusterConfig.Nodes...)
	}
	diagnostics.nodes = append(diagnostics.nodes, clusterconfig.Node{
		Name: setup.RuntimeConfig.ControlPlaneConfig().Hostname(), OS: clusterconfig.OsTypeLinux,
		IpAddress: setup.Config.ControlPlane().IpAddress(), Username: definitions.SSHRemoteUser,
	})
	diagnostics.collect(ctx, source, target, container)
}

func (d nodeNetworkDiagnostics) collect(ctx context.Context, source, target v1.Pod, container string) {
	GinkgoWriter.Printf(">>> NODE-NET DIAG: %s (%s, %s) -> %s (%s, %s)\n",
		source.Name, source.Spec.NodeName, source.Status.PodIP, target.Name, target.Spec.NodeName, target.Status.PodIP)
	kubectl := func(args ...string) (string, error) { return d.run(ctx, d.kubectl, args...) }
	app := target.Labels["app"]
	content, err := kubectl("get", "service", app, "-n", namespace, "-o", "json")
	targets := []string{}
	if err == nil {
		var service v1.Service
		if err := json.Unmarshal([]byte(content), &service); err != nil {
			GinkgoWriter.Printf(">>> NODE-NET DIAG: cannot parse Service: %v\n", err)
		} else if net.ParseIP(service.Spec.ClusterIP) != nil {
			targets = append(targets, service.Spec.ClusterIP)
		}
	}
	if net.ParseIP(target.Status.PodIP) != nil {
		targets = append(targets, target.Status.PodIP)
	}
	// These generated workloads expose both Service and container port 80.
	for _, address := range targets {
		_, _ = kubectl(podCommandArgs(source.Name, container, "curl", "-sS", "-i",
			"--noproxy", "*", "--connect-timeout", "3", "--max-time", "5",
			fmt.Sprintf("http://%s/%s", net.JoinHostPort(address, "80"), app))...)
	}
	_, _ = kubectl("get", "endpointslices", "-n", namespace, "-l", "kubernetes.io/service-name="+app, "-o", "json")
	_, _ = kubectl("get", "pods", "-n", namespace, "-o", "wide")
	_, _ = kubectl("get", "nodes", "-o", "wide")
	for _, pod := range []v1.Pod{source, target} {
		_, _ = kubectl("get", "node", pod.Spec.NodeName, "-o", "json")
		d.collectLinuxRoutes(ctx, pod.Spec.NodeName, targets)
	}
	if container != "" {
		_, _ = kubectl(podCommandArgs(source.Name, container, "ip", "-4", "route", "show", "table", "all")...)
	}
	_, _ = kubectl("logs", "-n", "kube-flannel", "-l", "app=flannel", "--all-containers=true", "--prefix=true", "--tail=60")
	_, _ = kubectl("logs", "-n", "kube-system", "-l", "k8s-app=kube-proxy", "--all-containers=true", "--prefix=true", "--tail=60")
	if runtime.GOOS == "windows" {
		for _, script := range []string{
			"Get-Service kubeproxy,kubelet,flanneld | Format-Table -AutoSize",
			"Get-NetRoute -AddressFamily IPv4 | Format-Table -AutoSize",
			"Import-Module HostNetworkingService; Get-HnsNetwork | ConvertTo-Json -Depth 15",
			"Import-Module HostNetworkingService; Get-HnsEndpoint | ConvertTo-Json -Depth 15",
			"Import-Module HostNetworkingService; Get-HnsPolicyList | ConvertTo-Json -Depth 15",
		} {
			_, _ = d.run(ctx, "powershell.exe", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; "+script)
		}
	}
}

func (d nodeNetworkDiagnostics) collectLinuxRoutes(ctx context.Context, nodeName string, targets []string) {
	for _, node := range d.nodes {
		if !strings.EqualFold(node.Name, nodeName) || node.OS != clusterconfig.OsTypeLinux {
			continue
		}
		if node.Username == "" || net.ParseIP(node.IpAddress) == nil || d.sshKey == "" {
			GinkgoWriter.Printf(">>> NODE-NET DIAG: incomplete SSH configuration for %s; skipping host routes\n", nodeName)
			return
		}
		command := "ip -4 address; ip -4 route show table all; ip rule show"
		for _, address := range targets {
			if net.ParseIP(address) != nil {
				command += "; ip route get " + address
			}
		}
		command += "; sudo -n iptables-save -c"
		_, _ = d.run(ctx, "ssh", "-n", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
			"-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
			"-i", d.sshKey, node.Username+"@"+node.IpAddress, command)
		return
	}
	GinkgoWriter.Printf(">>> NODE-NET DIAG: no Linux SSH configuration for %s; skipping host routes\n", nodeName)
}

func runNodeNetworkDiagnostic(ctx context.Context, executable string, args ...string) (string, error) {
	if err := ctx.Err(); err != nil {
		GinkgoWriter.Printf(">>> NODE-NET DIAG: collection deadline reached: %v\n", err)
		return "", err
	}
	commandCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	GinkgoWriter.Printf(">>> NODE-NET DIAG: %s %s\n", executable, strings.Join(args, " "))
	command := exec.CommandContext(commandCtx, executable, args...)
	command.WaitDelay = time.Second
	output, err := command.CombinedOutput()
	GinkgoWriter.Print(string(output))
	if err != nil {
		GinkgoWriter.Printf(">>> NODE-NET DIAG: command failed: %v (context: %v)\n", err, commandCtx.Err())
	}
	return string(output), err
}
