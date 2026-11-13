// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package powershell

// PsCmd is the PowerShell executable name on Windows (Windows PowerShell 5.1).
const PsCmd = "powershell"

// platformGuard is a no-op on Windows where PowerShell 5.1 is always available.
func platformGuard() error {
	return nil
}
