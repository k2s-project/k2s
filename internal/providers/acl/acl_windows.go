// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package acl

import (
	"fmt"
	"log/slog"

	acl_pkg "github.com/hectane/go-acl"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"golang.org/x/sys/windows"
)

const (
	replaceExistingEntries = true
	doNotInheritACEs       = false
	adminGroupSidString    = "S-1-5-32-544"
)

func TransferFileOwnership(path string, user *users.OSUser) error {
	slog.Debug("Transferring file ownership", "path", path, "user", user.Name())

	adminGroupSid, err := windows.StringToSid(adminGroupSidString)
	if err != nil {
		return fmt.Errorf("failed to convert SID string '%s' to SID: %w", adminGroupSidString, err)
	}

	if err := acl_pkg.Apply(
		path,
		replaceExistingEntries,
		doNotInheritACEs,
		acl_pkg.GrantName(windows.GENERIC_ALL, user.Name()),
		acl_pkg.GrantSid(windows.GENERIC_ALL, adminGroupSid),
	); err != nil {
		return fmt.Errorf("failed to transfer ownership of '%s' to user '%s': %w", path, user.Name(), err)
	}

	slog.Debug("File ownership transferred", "path", path, "user", user.Name())
	return nil
}
