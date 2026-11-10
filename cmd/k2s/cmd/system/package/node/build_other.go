// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build !linux

package nodepackage

import (
	"fmt"

	"github.com/spf13/pflag"
)

// BuildLinux is only implemented on Linux: it builds a node package natively on the
// build host (no VM), which is required for arm64 since Hyper-V cannot run an arm64
// guest on an x86 host. See build_linux.go.
func BuildLinux(flags *pflag.FlagSet, targetDir, zipName, proxy string) error {
	return fmt.Errorf("native node-package building is only supported on Linux; run this command on a Linux host matching the target --%s", ArchFlagName)
}
