// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/image/registry"

	"github.com/spf13/cobra"
)

const (
	nodeFlagName  = "node"
	nodesFlagName = "nodes"
)

var ImageCmd = &cobra.Command{
	Use:   "image",
	Short: "Manage images",
}

func init() {
	ImageCmd.AddCommand(listCmd)
	ImageCmd.AddCommand(cleanCmd)
	ImageCmd.AddCommand(repairCmd)
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

func addNodeSelectionFlags(cmd *cobra.Command) {
	cmd.Flags().String(nodeFlagName, "", "Node name to target (e.g. worker-1)")
	cmd.Flags().String(nodesFlagName, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
}

func parseNodeSelector(cmd *cobra.Command) (string, error) {
	return common.ParseNodeSelector(cmd, nodeFlagName, nodesFlagName)
}
