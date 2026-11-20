// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package healthcheck

import (
	"fmt"
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

	volumeID, err := getVolumeID(pathPtr)
	if err != nil {
		return DiskInfo{}, err
	}

	return DiskInfo{
		VolumeID:  volumeID,
		FreeBytes: freeBytesAvailable,
	}, nil
}

// getVolumeID returns the unique volume name (e.g. \\?\Volume{GUID}\) of the volume backing the path,
// which also resolves volumes mounted into a folder of another volume.
func getVolumeID(path *uint16) (string, error) {
	mountPoint := make([]uint16, windows.MAX_PATH+1)
	if err := windows.GetVolumePathName(path, &mountPoint[0], uint32(len(mountPoint))); err != nil {
		return "", fmt.Errorf("could not determine volume mount point: %w", err)
	}

	volumeName := make([]uint16, windows.MAX_PATH+1)
	if err := windows.GetVolumeNameForVolumeMountPoint(&mountPoint[0], &volumeName[0], uint32(len(volumeName))); err != nil {
		return "", fmt.Errorf("could not determine volume name: %w", err)
	}

	return strings.ToUpper(windows.UTF16ToString(volumeName)), nil
}
