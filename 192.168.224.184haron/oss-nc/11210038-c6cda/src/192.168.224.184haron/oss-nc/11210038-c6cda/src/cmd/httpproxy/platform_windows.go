// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package main

import (
	"fmt"
	"log/slog"
	"path/filepath"
	"syscall"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var setConsoleCtrlHandler = kernel32.NewProc("SetConsoleCtrlHandler")

// Console control event types
const (
	CTRL_C_EVENT        uint32 = 0
	CTRL_BREAK_EVENT    uint32 = 1
	CTRL_CLOSE_EVENT    uint32 = 2
	CTRL_LOGOFF_EVENT   uint32 = 5 // Not sent to services
	CTRL_SHUTDOWN_EVENT uint32 = 6 // Sent to console apps during system shutdown
)

func buildSystemShutdownCmd() (string, []string, error) {
	params := []string{}
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "..", "lib", "scripts", "windows", "host", "system", "shutdown", "Stop-System.ps1"))
	params = append(params, " -ShowLogs")
	return systemPackageCommand, params, nil
}

func buildSystemStartupCmd() (string, []string, error) {
	params := []string{}
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "..", "lib", "scripts", "windows", "host", "system", "startup", "Start-System.ps1"))
	params = append(params, " -ShowLogs")
	return systemPackageCommand, params, nil
}

func systemShutdownCmd() error {
	slog.Info("Build shutdown cmd and execute it")
	systemPackageCommand, params, err := buildSystemShutdownCmd()
	if err != nil {
		return err
	}
	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}
	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}
	slog.Info("Shutdown cmd finalized")
	return nil
}

func systemStartupCmd() error {
	slog.Info("Build startup cmd and execute it")
	systemPackageCommand, params, err := buildSystemStartupCmd()
	if err != nil {
		return err
	}
	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}
	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}
	slog.Info("Startup cmd finalized")
	return nil
}

// consoleCtrlHandler handles Windows console control events.
func consoleCtrlHandler(ctrlType uint32) uintptr {
	switch ctrlType {
	case CTRL_CLOSE_EVENT:
		slog.Info("Console close event received.")
		return 1
	case CTRL_SHUTDOWN_EVENT:
		cleanupWg.Add(1)
		go func() {
			defer cleanupWg.Done()
			slog.Info("Shutdown event received: Attempting cleanup.")

			// Hard timeout slightly below the NSSM AppStopMethodConsole timeout
			// (30s). If Stop-System.ps1 hangs, we still exit cleanly instead of
			// being force-killed by NSSM/Windows with no log output.
			done := make(chan error, 1)
			go func() {
				done <- systemShutdownCmd()
			}()

			select {
			case err := <-done:
				if err != nil {
					slog.Error("Shutdown cmd failed", "error", err)
				} else {
					slog.Info("Shutdown event received: Cleanup finished.")
				}
			case <-time.After(25 * time.Second):
				slog.Warn("Shutdown cleanup timed out after 25s, proceeding with exit")
			}
		}()
		cleanupWg.Wait()
		if listener != nil {
			listener.Close()
		}
		return 1
	case CTRL_C_EVENT:
		slog.Info("Ctrl+C received.")
		return 1
	case CTRL_BREAK_EVENT:
		slog.Info("Ctrl+Break received.")
		return 1
	}
	return 0
}

// registerPlatformHandler registers the Windows console control handler and
// calls the PowerShell startup script.
func registerPlatformHandler() error {
	handler := syscall.NewCallback(consoleCtrlHandler)
	ret, _, err := setConsoleCtrlHandler.Call(handler, 1)
	if ret == 0 {
		return fmt.Errorf("error registering console control handler: %v", err)
	}
	// Call the system startup command
	systemStartupCmd()
	return nil
}
