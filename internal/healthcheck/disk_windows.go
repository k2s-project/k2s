// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package healthcheck

import (
	"fmt"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// GetDiskInfo returns the free space of the volume the given path resides on.
func GetDiskInfo(path string) (DiskInfo, error) {
	pathPtr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return DiskInfo{}, fmt.Errorf("invalid path '%s': %w", path, err)
	}

	var freeBytesAvailable, totalBytes, totalFreeBytes uint64
	if err := windows.GetDiskFreeSpaceEx(pathPtr, &freeBytesAvailable, &totalBytes, &totalFreeBytes); err != nil {
		return DiskInfo{}, fmt.Errorf("could not query free disk space: %w", err)
	}

	return DiskInfo{
		VolumeID:  strings.ToUpper(filepath.VolumeName(path)),
		FreeBytes: freeBytesAvailable,
	}, nil
}
