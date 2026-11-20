// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// Package lifecycle defines the installed layout for native Linux lifecycle
// automation. It keeps platform-first script locations out of orchestration.
package lifecycle

import (
	"fmt"
	"path/filepath"
)

const (
	Debian13  = "debian"
	Host      = "host"
	LinuxOnly = "linuxonly"
)

var validOperations = map[string]struct{}{
	"Install":   {},
	"Start":     {},
	"Stop":      {},
	"Status":    {},
	"Uninstall": {},
}

// ScriptPath returns the installed Debian lifecycle entry point for a known
// lifecycle operation and scope.
func ScriptPath(installDir string, scope string, operation string) (string, error) {
	if _, ok := validOperations[operation]; !ok {
		return "", fmt.Errorf("unsupported native Linux lifecycle operation %q", operation)
	}
	if scope != Host && scope != LinuxOnly {
		return "", fmt.Errorf("unsupported native Linux lifecycle scope %q", scope)
	}

	return filepath.Join(installDir, "lib", "scripts", "linux", Debian13, scope, operation+".sh"), nil
}

// ProvisioningScriptPath returns the native Linux entry point that dispatches
// version-pinned Debian package provisioning to retained node-extension assets.
func ProvisioningScriptPath(installDir string) string {
	return filepath.Join(installDir, "lib", "scripts", "linux", Debian13, LinuxOnly, "ProvisionPackages.sh")
}
