// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package host

// SystemDrive returns the filesystem root on Linux.
func SystemDrive() string {
	return "/"
}

// K2sConfigDir returns the K2s configuration/state directory on Linux.
func K2sConfigDir() string {
	return "/var/lib/k2s"
}
