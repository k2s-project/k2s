// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package osusers

import (
	"github.com/k2s-project/k2s/internal/contracts/users"
)

type OSUserProvider struct{}

func NewOSUserProvider() *OSUserProvider {
	return &OSUserProvider{}
}

func (*OSUserProvider) FindByName(name string) (*users.OSUser, error) {
	return FindByName(name)
}

func (*OSUserProvider) FindById(id string) (*users.OSUser, error) {
	return FindById(id)
}

func (*OSUserProvider) CurrentUser() (*users.OSUser, error) {
	return CurrentUser()
}
