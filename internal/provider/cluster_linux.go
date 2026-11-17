// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"time"

	"github.com/k2s-project/k2s/internal/linux/lifecycle"
	"github.com/k2s-project/k2s/internal/output"
)

type linuxClusterProvider struct {
	installDir string
	configDir  string
	stdWriter  output.StreamWriter
}

func newLinuxClusterProvider(cfg ProviderConfig) *linuxClusterProvider {
	return &linuxClusterProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *linuxClusterProvider) Install(cfg ClusterInstallConfig) error {
	if cfg.StdWriter == nil {
		return errors.New("install requires a StdWriter")
	}

	return lifecycle.Execute("Install", lifecycle.Operation{
		InstallDir:           cfg.InstallDir,
		ConfigDir:            cfg.ConfigDir,
		Version:              cfg.Version,
		ClusterName:          cfg.ClusterName,
		ControlPlaneHostname: cfg.ControlPlaneHostname,
		Proxy:                cfg.Proxy,
		NoProxy:              cfg.NoProxy,
		SkipStart:            cfg.SkipStart,
		LinuxOnly:            cfg.LinuxOnly,
		WorkerCPUCount:       cfg.WorkerCPUCount,
		WorkerMemory:         cfg.WorkerMemory,
		WorkerDiskSize:       cfg.WorkerDiskSize,
		WindowsQCOW2Path:     cfg.WindowsQCOW2Path,
	}, cfg.StdWriter, cfg.ShowLogs)
}

func (p *linuxClusterProvider) Uninstall(cfg ClusterUninstallConfig) error {
	return lifecycle.Execute("Uninstall", lifecycle.Operation{
		InstallDir: p.installDir,
		ConfigDir:  cfg.ConfigDir,
		LinuxOnly:  cfg.LinuxOnly,
		SkipPurge:  cfg.SkipPurge,
	}, p.stdWriter, cfg.ShowLogs)
}

func (p *linuxClusterProvider) Start(cfg ClusterStartConfig) error {
	return lifecycle.Execute("Start", lifecycle.Operation{
		InstallDir: p.installDir,
		ConfigDir:  p.configDir,
		LinuxOnly:  cfg.LinuxOnly,
	}, p.stdWriter, cfg.ShowLogs)
}

func (p *linuxClusterProvider) Stop(cfg ClusterStopConfig) error {
	return lifecycle.Execute("Stop", lifecycle.Operation{
		InstallDir: p.installDir,
		ConfigDir:  p.configDir,
		LinuxOnly:  cfg.LinuxOnly,
	}, p.stdWriter, cfg.ShowLogs)
}

func (p *linuxClusterProvider) Status(_ ClusterStatusConfig) (*ClusterStatus, error) {
	slog.Debug("[Status] Loading status via kubectl (Linux)")

	status := &ClusterStatus{}
	status.IsRunning = isAPIServerReachable()

	if !status.IsRunning {
		status.Issues = []string{"Kubernetes API server is not reachable"}
		return status, nil
	}

	nodes, err := gatherNodeStatus()
	if err != nil {
		slog.Warn("[Status] Could not gather node info", "error", err)
		status.Issues = append(status.Issues, fmt.Sprintf("cannot list nodes: %v", err))
	} else {
		status.Nodes = nodes
	}

	pods, err := gatherPodStatus()
	if err != nil {
		slog.Warn("[Status] Could not gather pod info", "error", err)
	} else {
		status.Pods = pods
	}

	ver, err := gatherVersionInfo()
	if err != nil {
		slog.Warn("[Status] Could not gather version info", "error", err)
	}
	if ver != nil {
		status.K8sVersionInfo = &K8sVersionInfo{
			K8sServerVersion: ver.server,
			K8sClientVersion: ver.client,
		}
	}

	return status, nil
}

// ---------- kubectl helpers ----------

func isAPIServerReachable() bool {
	cmd := exec.Command("kubectl", "cluster-info", "--request-timeout=5s")
	return cmd.Run() == nil
}

type k8sNodeList struct {
	Items []k8sNodeItem `json:"items"`
}

type k8sNodeItem struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		CreationTimestamp string            `json:"creationTimestamp"`
	} `json:"metadata"`
	Status struct {
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		NodeInfo struct {
			KubeletVersion   string `json:"kubeletVersion"`
			KernelVersion    string `json:"kernelVersion"`
			OsImage          string `json:"osImage"`
			ContainerRuntime string `json:"containerRuntimeVersion"`
		} `json:"nodeInfo"`
		Addresses []struct {
			Type    string `json:"type"`
			Address string `json:"address"`
		} `json:"addresses"`
		Capacity struct {
			CPU              string `json:"cpu"`
			EphemeralStorage string `json:"ephemeral-storage"`
			Memory           string `json:"memory"`
		} `json:"capacity"`
	} `json:"status"`
}

func gatherNodeStatus() ([]NodeStatus, error) {
	output, err := exec.Command("kubectl", "get", "nodes", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get nodes: %w", err)
	}

	var nodeList k8sNodeList
	if err := json.Unmarshal(output, &nodeList); err != nil {
		return nil, fmt.Errorf("parsing node JSON: %w", err)
	}

	var nodes []NodeStatus
	for _, n := range nodeList.Items {
		node := NodeStatus{
			Name:             n.Metadata.Name,
			KubeletVersion:   n.Status.NodeInfo.KubeletVersion,
			KernelVersion:    n.Status.NodeInfo.KernelVersion,
			OsImage:          n.Status.NodeInfo.OsImage,
			ContainerRuntime: n.Status.NodeInfo.ContainerRuntime,
			Capacity: NodeCapacity{
				Cpu:     n.Status.Capacity.CPU,
				Storage: n.Status.Capacity.EphemeralStorage,
				Memory:  n.Status.Capacity.Memory,
			},
		}

		for label := range n.Metadata.Labels {
			if strings.HasPrefix(label, "node-role.kubernetes.io/") {
				node.Role = strings.TrimPrefix(label, "node-role.kubernetes.io/")
				break
			}
		}

		for _, cond := range n.Status.Conditions {
			if cond.Type == "Ready" {
				node.IsReady = cond.Status == "True"
				if node.IsReady {
					node.Status = "Ready"
				} else {
					node.Status = "NotReady"
				}
				break
			}
		}

		for _, addr := range n.Status.Addresses {
			if addr.Type == "InternalIP" {
				node.InternalIp = addr.Address
				break
			}
		}

		if n.Metadata.CreationTimestamp != "" {
			if created, err := time.Parse(time.RFC3339, n.Metadata.CreationTimestamp); err == nil {
				node.Age = formatDuration(time.Since(created))
			}
		}

		nodes = append(nodes, node)
	}

	return nodes, nil
}

type k8sPodListItems struct {
	Items []k8sPodItem `json:"items"`
}

type k8sPodItem struct {
	Metadata struct {
		Name              string `json:"name"`
		Namespace         string `json:"namespace"`
		CreationTimestamp string `json:"creationTimestamp"`
	} `json:"metadata"`
	Spec struct {
		NodeName string `json:"nodeName"`
	} `json:"spec"`
	Status struct {
		Phase             string `json:"phase"`
		PodIP             string `json:"podIP"`
		ContainerStatuses []struct {
			Ready        bool `json:"ready"`
			RestartCount int  `json:"restartCount"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

func gatherPodStatus() ([]PodStatus, error) {
	output, err := exec.Command("kubectl", "get", "pods", "--all-namespaces", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get pods: %w", err)
	}

	var podList k8sPodListItems
	if err := json.Unmarshal(output, &podList); err != nil {
		return nil, fmt.Errorf("parsing pod JSON: %w", err)
	}

	var pods []PodStatus
	for _, p := range podList.Items {
		pod := PodStatus{
			Name:      p.Metadata.Name,
			Namespace: p.Metadata.Namespace,
			Status:    p.Status.Phase,
			Ip:        p.Status.PodIP,
			Node:      p.Spec.NodeName,
			IsRunning: p.Status.Phase == "Running",
		}

		total := len(p.Status.ContainerStatuses)
		ready := 0
		restarts := 0
		for _, cs := range p.Status.ContainerStatuses {
			if cs.Ready {
				ready++
			}
			restarts += cs.RestartCount
		}
		pod.Ready = fmt.Sprintf("%d/%d", ready, total)
		pod.Restarts = fmt.Sprintf("%d", restarts)

		if p.Metadata.CreationTimestamp != "" {
			if created, err := time.Parse(time.RFC3339, p.Metadata.CreationTimestamp); err == nil {
				pod.Age = formatDuration(time.Since(created))
			}
		}

		pods = append(pods, pod)
	}

	return pods, nil
}

type versionResult struct {
	client string
	server string
}

func gatherVersionInfo() (*versionResult, error) {
	info := &versionResult{}

	if output, err := exec.Command("kubectl", "version", "--client", "-o", "json").Output(); err == nil {
		var v struct {
			ClientVersion struct {
				GitVersion string `json:"gitVersion"`
			} `json:"clientVersion"`
		}
		if json.Unmarshal(output, &v) == nil {
			info.client = v.ClientVersion.GitVersion
		}
	}

	if output, err := exec.Command("kubectl", "version", "-o", "json").Output(); err == nil {
		var v struct {
			ServerVersion struct {
				GitVersion string `json:"gitVersion"`
			} `json:"serverVersion"`
		}
		if json.Unmarshal(output, &v) == nil {
			info.server = v.ServerVersion.GitVersion
		}
	}

	return info, nil
}

func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}
