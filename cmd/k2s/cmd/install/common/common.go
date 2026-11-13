// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	cc "github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"

	"github.com/spf13/cobra"
)

type Installer interface {
	Install(kind ic.Kind, cmd *cobra.Command, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error), cmdSession cc.CmdSession) error
}
