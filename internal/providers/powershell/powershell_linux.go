// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package powershell

import "fmt"

// PsCmd is the PowerShell executable name on Linux (PowerShell Core).
// On Linux, PowerShell Core ("pwsh") is used when PS scripts need to run
// (e.g., inside a Windows VM via remoting). For native Linux orchestration,
// the Go CLI calls bash/native commands directly instead.
const PsCmd = "pwsh"

// platformGuard returns an error on Linux because the PowerShell scripts in this
// project are written for Windows and depend on Windows-specific APIs (HNS,
// Hyper-V, NSSM, Windows services, etc.). They cannot run on a Linux host even
// if PowerShell Core (pwsh) is installed. Commands that support Linux hosts have
// native Go implementations and never reach this code path.
func platformGuard() error {
	return fmt.Errorf("this operation requires Windows PowerShell and is not available on Linux hosts. " +
		"Supported commands on Linux: install, uninstall, start, stop, status, version, " +
		"addons enable/disable/ls/status/backup/restore, image build/clean/export/import/list/pull/push/remove/tag, " +
		"node add/remove, system dump/reset/reset-network/cert-renew")
}
