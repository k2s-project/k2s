// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package verification

import (
	"fmt"

	"github.com/samber/lo"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/k8s"
)

func VerifyUser(userName string, userInfo *k8s.UserInfo) error {
	if !lo.Contains(userInfo.Groups, definitions.K2sUserGroup) {
		return fmt.Errorf("user '%s' not part of the group '%s'", userName, definitions.K2sUserGroup)
	}
	if userInfo.Name != userName {
		return fmt.Errorf("user name '%s' does not match expected user name '%s'", userInfo.Name, userName)
	}
	return nil
}
