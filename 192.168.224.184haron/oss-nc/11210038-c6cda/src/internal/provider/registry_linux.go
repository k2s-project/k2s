// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"fmt"
	"log/slog"
	"os"
)

// NewRegistry creates a Registry populated with Linux-specific providers.
// Linux providers use native commands (kubeadm, kubectl, crictl, virsh, ssh).
//
// NOTE: Linux host support is EXPERIMENTAL. The warning below is intentional
// and should be kept until the feature is promoted to stable.
func NewRegistry(cfg ProviderConfig) *Registry {
	slog.Warn("[EXPERIMENTAL] Linux host support is experimental — some features may be incomplete or change without notice")
	fmt.Fprintln(os.Stderr, "WARNING: [EXPERIMENTAL] Linux host support is experimental — some features may be incomplete or change without notice")

	return &Registry{
		Cluster: newLinuxClusterProvider(cfg),
		Image:   newLinuxImageProvider(cfg),
		Node:    newLinuxNodeProvider(cfg),
		System:  newLinuxSystemProvider(cfg),
		Addon:   newLinuxAddonProvider(cfg),
	}
}
