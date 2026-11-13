// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package osusers

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/internal/contracts/users"
)

const (
	systemAccountName     = "SYSTEM"
	systemAccountFullName = "NT AUTHORITY\\" + systemAccountName
	systemAccountId       = "S-1-5-18"
)

var systemAccountHomeDir = filepath.Join(os.Getenv("SYSTEMROOT"), "System32\\config\\systemprofile")

func FindByName(name string) (*users.OSUser, error) {
	if isSystemAccountName(name) {
		return users.NewOSUser(systemAccountId, systemAccountFullName, systemAccountHomeDir), nil
	}

	found, err := user.Lookup(name)
	if err != nil {
		return nil, users.ErrUserNotFound(fmt.Errorf("could not find Windows user by name '%s': %w", name, err).Error())
	}
	return users.NewOSUser(found.Uid, found.Username, found.HomeDir), nil
}

func FindById(id string) (*users.OSUser, error) {
	if isSystemAccountId(id) {
		return users.NewOSUser(systemAccountId, systemAccountFullName, systemAccountHomeDir), nil
	}

	found, err := user.LookupId(id)
	if err != nil {
		return nil, users.ErrUserNotFound(fmt.Errorf("could not find Windows user by id '%s': %w", id, err).Error())
	}
	return users.NewOSUser(found.Uid, found.Username, found.HomeDir), nil
}

func CurrentUser() (*users.OSUser, error) {
	current, err := user.Current()
	if err != nil {
		return nil, fmt.Errorf("could not determine current Windows user: %w", err)
	}
	return users.NewOSUser(current.Uid, current.Username, current.HomeDir), nil
}

func isSystemAccountName(name string) bool {
	return strings.EqualFold(name, systemAccountName) || strings.EqualFold(name, systemAccountFullName)
}

func isSystemAccountId(id string) bool {
	return strings.EqualFold(id, systemAccountId)
}
