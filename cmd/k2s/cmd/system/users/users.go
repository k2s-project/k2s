// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package users

import (
	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "users",
		Short: "K2s users management (host only)",
	}

	cmd.AddCommand(newAddCommand())

	return cmd
}
