// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package effectiveconfig

import (
	"fmt"

	"github.com/k2s-project/k2s/internal/providers/acl"
	"github.com/k2s-project/k2s/internal/providers/osusers"
	"golang.org/x/sys/windows"
)

func restrictFile(path string) error {
	currentUser, err := osusers.CurrentUser()
	if err != nil {
		return fmt.Errorf("failed to determine owner for effective install configuration: %w", err)
	}
	if err := acl.TransferFileOwnership(path, currentUser); err != nil {
		return fmt.Errorf("failed to restrict effective install configuration: %w", err)
	}
	return nil
}

func atomicReplace(source string, target string) error {
	sourcePath, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	targetPath, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(sourcePath, targetPath, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}
