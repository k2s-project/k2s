// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package provider

// NewRegistry creates a Registry populated with Windows-specific providers.
// Windows providers delegate to PowerShell scripts, preserving existing behavior.
func NewRegistry(cfg ProviderConfig) *Registry {
	return &Registry{
		Cluster: newWindowsClusterProvider(cfg),
		Image:   newWindowsImageProvider(cfg),
		Node:    newWindowsNodeProvider(cfg),
		System:  newWindowsSystemProvider(cfg),
		Addon:   newWindowsAddonProvider(cfg),
	}
}
