// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package host

// SystemDrive returns hard-coded 'C:\' drive string instead of the actual system drive,
// because some containers are also hard-coded to this drive.
//
// Note: This string has already the backslash '\' attached, because Go's filepath.Join()
// would otherwise not be able to correctly join the drive and other path components
// (see https://github.com/golang/go/issues/26953).
func SystemDrive() string {
	return "C:\\"
}

// K2sConfigDir returns the K2s configuration/state directory on Windows.
func K2sConfigDir() string {
	return "C:\\ProgramData\\K2s"
}
