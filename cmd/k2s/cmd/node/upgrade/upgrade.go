// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package upgrade

import (
	systemupgrade "github.com/k2s-project/k2s/cmd/k2s/cmd/system/upgrade"
	"github.com/spf13/cobra"
)

const (
	nodeNameFlag    = "node"
	nodePackageFlag = "path"
)

var upgradeCommandLongDescription = `
Upgrades a single Linux worker node from a node package zip without touching the control plane.
Both full node packages and node delta packages are supported.
The upgrade mode is auto-detected from the ZIP contents:
  - ZIP contains delta-manifest.json with DeltaType=node-package → DELTA mode
    (installs only changed/added packages; purges removed Debian packages)
  - No delta-manifest.json present → FULL mode
    (installs all packages present in the ZIP)

The node is cordoned and drained, the packages and container images of the ZIP are installed,
kubelet is restarted, and the node is uncordoned again before the command waits for it to be Ready.

This command is equivalent to 'k2s system upgrade --node <node-name> --path <node-package.zip>'.
`

var upgradeCommandExample = `
  # Apply a full node package to a worker node
  k2s node upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-v1.8.0.zip" -o

  # Apply a node delta package to a worker node (mode auto-detected)
  k2s node upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-delta-v1.7.0-to-v1.8.0.zip" -o
`

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "upgrade",
		Short:   "Upgrade a worker node from a full node package or a node delta package",
		Long:    upgradeCommandLongDescription,
		Example: upgradeCommandExample,
		Args:    cobra.NoArgs,
		RunE:    upgradeNode,
	}
	cmd.Flags().StringP(nodeNameFlag, "n", "", "Name of the worker node to upgrade, as registered in the cluster")
	cmd.Flags().String(nodePackageFlag, "", "Path to the node package zip (full or node delta package; mode auto-detected)")
	cmd.MarkFlagRequired(nodeNameFlag)
	cmd.MarkFlagRequired(nodePackageFlag)
	return cmd
}

func upgradeNode(cmd *cobra.Command, _ []string) error {
	nodeName, err := cmd.Flags().GetString(nodeNameFlag)
	if err != nil {
		return err
	}
	nodePackagePath, err := cmd.Flags().GetString(nodePackageFlag)
	if err != nil {
		return err
	}
	return systemupgrade.UpgradeNode(cmd, nodeName, nodePackagePath)
}
