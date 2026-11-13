// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

// Package provider defines platform-agnostic interfaces for all K2s operations.
// Each host platform (Windows, Linux) supplies its own implementation via
// build-tagged factory files. The cmd layer uses these interfaces exclusively,
// eliminating the need for platform-specific dispatch logic in command handlers.
package provider

import (
	"github.com/k2s-project/k2s/internal/output"
)

// Registry holds all platform-specific providers.
// It is created once during CLI initialization and passed to command handlers
// via the Cobra context.
type Registry struct {
	Cluster ClusterProvider
	Image   ImageProvider
	Node    NodeProvider
	System  SystemProvider
	Addon   AddonProvider
}

// ProviderConfig holds initialization parameters for provider creation.
type ProviderConfig struct {
	// InstallDir is the K2s installation directory (where k2s.exe lives).
	InstallDir string
	// ConfigDir is the K2s setup config directory (e.g. C:\ProgramData\K2s or /var/lib/k2s).
	ConfigDir string
	// StdWriter is used for streaming output to the terminal.
	StdWriter output.StreamWriter
}
