// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package status

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
)

type LoadedStatus struct {
	common.CmdResult
	RunningState   *RunningState   `json:"runningState"`
	Nodes          []Node          `json:"nodes"`
	Pods           []Pod           `json:"pods"`
	K8sVersionInfo *K8sVersionInfo `json:"k8sVersionInfo"`
}

type Pod struct {
	Status    string `json:"status"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Ready     string `json:"ready"`
	Restarts  string `json:"restarts"`
	Age       string `json:"age"`
	Ip        string `json:"ip"`
	Node      string `json:"node"`
	IsRunning bool   `json:"isRunning"`
}

type Node struct {
	Status           string   `json:"status"`
	Name             string   `json:"name"`
	Role             string   `json:"role"`
	Age              string   `json:"age"`
	KubeletVersion   string   `json:"kubeletVersion"`
	KernelVersion    string   `json:"kernelVersion"`
	OsImage          string   `json:"osImage"`
	ContainerRuntime string   `json:"containerRuntime"`
	InternalIp       string   `json:"internalIp"`
	IsReady          bool     `json:"isReady"`
	Capacity         Capacity `json:"capacity"`
}

type RunningState struct {
	IsRunning bool     `json:"isRunning"`
	Issues    []string `json:"issues"`
}

type K8sVersionInfo struct {
	K8sServerVersion string `json:"k8sServerVersion"`
	K8sClientVersion string `json:"k8sClientVersion"`
}

type Capacity struct {
	Cpu     string `json:"cpu"`
	Storage string `json:"storage"`
	Memory  string `json:"memory"`
}

// LoadStatus delegates status loading to the platform provider.
// The provider returns domain types which are mapped back to the command-local
// types used by the printer chain.
func LoadStatus(ctx *common.CmdContext) (*LoadedStatus, error) {
	clusterStatus, err := ctx.Providers().Cluster.Status(provider.ClusterStatusConfig{})
	if err != nil {
		return nil, err
	}

	result := &LoadedStatus{
		CmdResult: common.CmdResult{},
		RunningState: &RunningState{
			IsRunning: clusterStatus.IsRunning,
			Issues:    clusterStatus.Issues,
		},
	}

	for _, n := range clusterStatus.Nodes {
		result.Nodes = append(result.Nodes, Node{
			Status:           n.Status,
			Name:             n.Name,
			Role:             n.Role,
			Age:              n.Age,
			KubeletVersion:   n.KubeletVersion,
			KernelVersion:    n.KernelVersion,
			OsImage:          n.OsImage,
			ContainerRuntime: n.ContainerRuntime,
			InternalIp:       n.InternalIp,
			IsReady:          n.IsReady,
			Capacity: Capacity{
				Cpu:     n.Capacity.Cpu,
				Storage: n.Capacity.Storage,
				Memory:  n.Capacity.Memory,
			},
		})
	}

	for _, p := range clusterStatus.Pods {
		result.Pods = append(result.Pods, Pod{
			Status:    p.Status,
			Namespace: p.Namespace,
			Name:      p.Name,
			Ready:     p.Ready,
			Restarts:  p.Restarts,
			Age:       p.Age,
			Ip:        p.Ip,
			Node:      p.Node,
			IsRunning: p.IsRunning,
		})
	}

	if clusterStatus.K8sVersionInfo != nil {
		result.K8sVersionInfo = &K8sVersionInfo{
			K8sServerVersion: clusterStatus.K8sVersionInfo.K8sServerVersion,
			K8sClientVersion: clusterStatus.K8sVersionInfo.K8sClientVersion,
		}
	}

	return result, nil
}
