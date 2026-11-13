// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package users

import (
	"fmt"
	"log/slog"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users/cluster"
	"github.com/k2s-project/k2s/internal/core/users/controlplane"
	"github.com/k2s-project/k2s/internal/core/users/naming"
	"github.com/k2s-project/k2s/internal/core/users/validation"
	"github.com/k2s-project/k2s/internal/primitives/concurrency"
	"github.com/k2s-project/k2s/internal/providers/osusers"
	"github.com/k2s-project/k2s/internal/providers/ssh"
)

type OSUserProvider interface {
	CurrentUser() (*users.OSUser, error)
	FindByName(name string) (*users.OSUser, error)
	FindById(id string) (*users.OSUser, error)
}

type UserAdmission struct {
	userProvider          OSUserProvider
	controlPlaneAdmission *controlplane.ControlPlaneAdmission
	clusterAdmission      *cluster.ClusterAdmission
}

func NewUserAdmission(k2sConfig *config.K2sConfig, clusterName string, connectionOptions ssh.ConnectionOptions, userProviders ...OSUserProvider) *UserAdmission {
	controlPlaneAdmission := controlplane.NewControlPlaneAdmission(k2sConfig, connectionOptions)
	clusterAdmission := cluster.NewClusterAdmission(clusterName, k2sConfig.Host(), connectionOptions)

	if len(userProviders) == 0 {
		userProviders = []OSUserProvider{osusers.NewOSUserProvider()}
	}

	return &UserAdmission{
		userProvider:          userProviders[0],
		controlPlaneAdmission: controlPlaneAdmission,
		clusterAdmission:      clusterAdmission,
	}
}

func (a *UserAdmission) AddById(userId string) error {
	return a.add(func() (*users.OSUser, error) { return a.userProvider.FindById(userId) })
}

func (a *UserAdmission) AddByName(userName string) error {
	return a.add(func() (*users.OSUser, error) { return a.userProvider.FindByName(userName) })
}

func (a *UserAdmission) add(findUserFunc func() (*users.OSUser, error)) error {
	user, err := findUserFunc()
	if err != nil {
		return err
	}

	slog.Debug("Adding user to K2s", "name", user.Name(), "id", user.Id())

	currentUser, err := a.userProvider.CurrentUser()
	if err != nil {
		return fmt.Errorf("failed to determine current user: %w", err)
	}

	if err := validation.ValidateUser(currentUser, user); err != nil {
		return fmt.Errorf("failed to validate user '%s': %w", user.Name(), err)
	}

	k2sUserName := naming.DetermineK2sUserName(user)

	return concurrency.RunAll(
		func() error {
			return a.controlPlaneAdmission.GrantAccess(user, k2sUserName)
		},
		func() error {
			return a.clusterAdmission.GrantAccess(user, k2sUserName)
		},
	)
}
