// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package healthcheck

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// IsServiceRunning returns whether the Windows service with the given name is running.
// It only requests query rights, so it also works without administrator privileges.
func IsServiceRunning(name string) (bool, error) {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return false, fmt.Errorf("could not connect to service manager: %w", err)
	}
	defer windows.CloseServiceHandle(manager)

	namePtr, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return false, err
	}

	service, err := windows.OpenService(manager, namePtr, windows.SERVICE_QUERY_STATUS)
	if err != nil {
		return false, fmt.Errorf("could not open service: %w", err)
	}
	defer windows.CloseServiceHandle(service)

	var status windows.SERVICE_STATUS
	if err := windows.QueryServiceStatus(service, &status); err != nil {
		return false, fmt.Errorf("could not query service status: %w", err)
	}
	return status.CurrentState == windows.SERVICE_RUNNING, nil
}
