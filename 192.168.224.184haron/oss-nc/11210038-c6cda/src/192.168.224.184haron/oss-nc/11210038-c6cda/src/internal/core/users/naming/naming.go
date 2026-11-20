// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package naming

import (
	"strings"

	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/definitions"
)

func DetermineK2sUserName(user *users.OSUser) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(user.Name(), " ", "-"), "\\", "-")

	return definitions.K2sUsersPrefix + beautifiedUsername
}
