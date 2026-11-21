// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package healthcheck

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// GetDiskInfo returns the free space of the file system the given path resides on.
func GetDiskInfo(path string) (DiskInfo, error) {
	var stat unix.Stat_t
	if err := unix.Stat(path, &stat); err != nil {
		return DiskInfo{}, fmt.Errorf("could not stat path: %w", err)
	}

	var fsStat unix.Statfs_t
	if err := unix.Statfs(path, &fsStat); err != nil {
		return DiskInfo{}, fmt.Errorf("could not query free disk space: %w", err)
	}

	return DiskInfo{
		VolumeID:  fmt.Sprintf("%d", stat.Dev),
		FreeBytes: fsStat.Bavail * uint64(fsStat.Bsize),
	}, nil
}
