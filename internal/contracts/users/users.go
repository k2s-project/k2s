// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package users

type OSUser struct {
	id      string
	name    string
	homeDir string
}

type ErrUserNotFound string

func NewOSUser(id, name, homeDir string) *OSUser {
	return &OSUser{
		id:      id,
		name:    name,
		homeDir: homeDir,
	}
}

func (u *OSUser) Id() string {
	return u.id
}

func (u *OSUser) Name() string {
	return u.name
}

func (u *OSUser) HomeDir() string {
	return u.homeDir
}

func (u *OSUser) Equals(user *OSUser) bool {
	return u.id == user.id &&
		u.name == user.name &&
		u.homeDir == user.homeDir
}

func (e ErrUserNotFound) Error() string {
	return string(e)
}
