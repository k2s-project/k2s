// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// enableVirtualTerminalProcessing turns on ANSI/VT escape-sequence handling for
// the console attached to stdout. Without it, styled output (e.g. pterm warning
// banners) emitted before any PowerShell child process runs would be printed as
// raw escape codes in the Windows console. The call is idempotent and a no-op
// when stdout is not a console (e.g. redirected to a file or pipe).
func enableVirtualTerminalProcessing() {
	handle := windows.Handle(os.Stdout.Fd())

	var mode uint32
	if err := windows.GetConsoleMode(handle, &mode); err != nil {
		return
	}

	_ = windows.SetConsoleMode(handle, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
}
