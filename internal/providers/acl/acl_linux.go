// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package acl

import (
	"fmt"
	"os"
	"strconv"

	"github.com/k2s-project/k2s/internal/contracts/users"
)

func TransferFileOwnership(path string, targetUser *users.OSUser) error {
	uid, err := strconv.Atoi(targetUser.Id())
	if err != nil {
		return fmt.Errorf("invalid UID '%s': %w", targetUser.Id(), err)
	}
	return os.Chown(path, uid, -1)
}
