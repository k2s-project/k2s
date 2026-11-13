// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/image/registry"

	"github.com/spf13/cobra"
)

var ImageCmd = &cobra.Command{
	Use:   "image",
	Short: "Manage images",
}

func init() {
	ImageCmd.AddCommand(listCmd)
	ImageCmd.AddCommand(cleanCmd)
	ImageCmd.AddCommand(removeCmd)
	ImageCmd.AddCommand(exportCmd)
	ImageCmd.AddCommand(importCmd)
	ImageCmd.AddCommand(registry.Cmd)
	ImageCmd.AddCommand(resetWinStorageCmd)
	ImageCmd.AddCommand(buildCmd)
	ImageCmd.AddCommand(pullCmd)
	ImageCmd.AddCommand(pushCmd)
	ImageCmd.AddCommand(tagCmd)
}
