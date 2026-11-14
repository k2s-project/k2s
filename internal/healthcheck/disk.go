// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck

import (
	"fmt"
	"strings"

	"github.com/k2s-project/k2s/internal/primitives/units"
)

const (
	// MinFreeDiskBytes is the free space below which the disk check fails.
	// The troubleshooting guide asks for at least 10 GB on every disk used by K2s.
	MinFreeDiskBytes uint64 = 10 * 1024 * 1024 * 1024
	// LowFreeDiskBytes is the free space below which the disk check warns.
	LowFreeDiskBytes uint64 = 20 * 1024 * 1024 * 1024

	diskSpaceHint = "Free up space on the affected drive, e.g. by removing unused images with 'k2s image rm' (see 'Known Issues > Disk Pressure' in the K2s documentation)"
)

// DiskInfo describes the volume a path resides on.
type DiskInfo struct {
	// VolumeID identifies the volume, so that paths on the same volume are checked only once.
	VolumeID string
	// FreeBytes is the space available to the current user.
	FreeBytes uint64
}

// DiskInfoFunc returns volume information for a path.
type DiskInfoFunc func(path string) (DiskInfo, error)

// NewDiskSpaceCheck returns a check that verifies that every volume holding one of the
// given paths has enough free space. Paths on the same volume are evaluated once.
func NewDiskSpaceCheck(paths []string, diskInfoFunc DiskInfoFunc) Check {
	return Check{
		Name:        "host-disk-space",
		Description: "Enough free disk space on the host",
		Run: func() Outcome {
			return checkDiskSpace(paths, diskInfoFunc)
		},
	}
}

func checkDiskSpace(paths []string, diskInfoFunc DiskInfoFunc) Outcome {
	var low, critical, ok, unreadable []string
	seenVolumes := make(map[string]bool)

	for _, path := range paths {
		info, err := diskInfoFunc(path)
		if err != nil {
			unreadable = append(unreadable, fmt.Sprintf("%s (%v)", path, err))
			continue
		}
		if seenVolumes[info.VolumeID] {
			continue
		}
		seenVolumes[info.VolumeID] = true

		entry := fmt.Sprintf("%s: %s free", path, units.BytesQuantity(info.FreeBytes))

		switch {
		case info.FreeBytes < MinFreeDiskBytes:
			critical = append(critical, entry)
		case info.FreeBytes < LowFreeDiskBytes:
			low = append(low, entry)
		default:
			ok = append(ok, entry)
		}
	}

	var problems []string
	if len(critical) > 0 {
		problems = append(problems, fmt.Sprintf("less than %s free on %s", units.BytesQuantity(MinFreeDiskBytes), strings.Join(critical, ", ")))
	}
	if len(low) > 0 {
		problems = append(problems, fmt.Sprintf("less than %s free on %s", units.BytesQuantity(LowFreeDiskBytes), strings.Join(low, ", ")))
	}
	if len(unreadable) > 0 {
		problems = append(problems, fmt.Sprintf("could not determine free disk space for %s", strings.Join(unreadable, ", ")))
	}

	switch {
	case len(critical) > 0:
		return fail(strings.Join(problems, "; "), diskSpaceHint)
	case len(low) > 0:
		return warn(strings.Join(problems, "; "), diskSpaceHint)
	case len(ok) == 0:
		return skip(strings.Join(problems, "; "))
	case len(unreadable) > 0:
		return warn(strings.Join(append([]string{strings.Join(ok, ", ")}, problems...), "; "), "Check that the K2s directories exist and are accessible")
	default:
		return pass(strings.Join(ok, ", "))
	}
}
