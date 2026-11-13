// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	"fmt"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/util/validation"
)

// NodeProvider abstracts node management operations.
// On Windows: delegates to PowerShell scripts.
// On Linux: uses SSH + kubeadm join natively.
type NodeProvider interface {
	// Add adds a worker node to the cluster.
	Add(config NodeAddConfig) error

	// Remove removes a worker node from the cluster.
	Remove(config NodeRemoveConfig) error

	// Rename repairs the identity of a managed worker after its OS hostname changed.
	Rename(config NodeRenameConfig) error
}

// NodeAddConfig holds parameters for adding a node.
type NodeAddConfig struct {
	IpAddress       string
	UserName        string
	NodeName        string
	Role            string
	NodePackagePath string
	ShowOutput      bool
	IsLocalVM       bool
}

// NodeRemoveConfig holds parameters for removing a node.
type NodeRemoveConfig struct {
	NodeName   string
	ShowOutput bool
}

type NodeRenameConfig struct {
	OldName string
	NewName string
	Timeout time.Duration
	// Force continues when a partially registered replacement Node carries workloads.
	Force      bool
	ShowOutput bool
}

func (c NodeRenameConfig) Validated() (NodeRenameConfig, error) {
	c.OldName = strings.ToLower(c.OldName)
	c.NewName = strings.ToLower(c.NewName)
	for _, name := range []string{c.OldName, c.NewName} {
		if problems := validation.IsDNS1123Subdomain(name); len(problems) != 0 {
			return c, fmt.Errorf("invalid node name %q: %s", name, strings.Join(problems, "; "))
		}
		for _, label := range strings.Split(name, ".") {
			if problems := validation.IsDNS1123Label(label); len(problems) != 0 {
				return c, fmt.Errorf("invalid node name %q: %s", name, strings.Join(problems, "; "))
			}
		}
	}
	if c.OldName == c.NewName {
		return c, fmt.Errorf("old and new node names must differ")
	}
	if c.Timeout < time.Minute || c.Timeout > 24*time.Hour {
		return c, fmt.Errorf("rename timeout must be between 1m and 24h")
	}
	return c, nil
}
