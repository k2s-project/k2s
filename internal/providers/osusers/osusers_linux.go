// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package osusers

import (
	"fmt"
	"os/user"

	"github.com/k2s-project/k2s/internal/contracts/users"
)

func CurrentUser() (*users.OSUser, error) {
	u, err := user.Current()
	if err != nil {
		return nil, fmt.Errorf("failed to get current user: %w", err)
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func FindByName(name string) (*users.OSUser, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return nil, users.ErrUserNotFound(fmt.Errorf("user '%s' not found: %w", name, err).Error())
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}

func FindById(id string) (*users.OSUser, error) {
	u, err := user.LookupId(id)
	if err != nil {
		return nil, users.ErrUserNotFound(fmt.Errorf("user with id '%s' not found: %w", id, err).Error())
	}
	return users.NewOSUser(u.Uid, u.Username, u.HomeDir), nil
}
