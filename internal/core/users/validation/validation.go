// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package validation

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/contracts/users"
)

func ValidateUser(currentUser, targetUser *users.OSUser) error {
	slog.Debug("Validating user", "name", targetUser.Name(), "id", targetUser.Id())

	if targetUser.Equals(currentUser) {
		return fmt.Errorf("cannot overwrite access of current user (name='%s', id='%s')", currentUser.Name(), currentUser.Id())
	}

	slog.Debug("User validated", "name", targetUser.Name(), "id", targetUser.Id())
	return nil
}
