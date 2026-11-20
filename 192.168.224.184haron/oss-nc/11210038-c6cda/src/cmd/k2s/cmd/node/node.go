// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package node

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/add"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/connect"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/copy"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/exec"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/remove"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/rename"
	"github.com/spf13/cobra"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "node",
		Short: "Manage cluster nodes",
	}
	cmd.AddCommand(add.NewCmd())
	cmd.AddCommand(remove.NewCmd())
	cmd.AddCommand(rename.NewCmd())
	cmd.AddCommand(copy.NewCmd())
	cmd.AddCommand(exec.NewCmd())
	cmd.AddCommand(connect.NewCmd())

	return cmd
}
