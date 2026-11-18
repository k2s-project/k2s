// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
)

const (
	nodeFlagName  = "node"
	nodesFlagName = "nodes"
)

func addNodeSelectionFlags(cmd *cobra.Command) {
	cmd.Flags().String(nodeFlagName, "", "Node name to target (e.g. worker-1)")
	cmd.Flags().String(nodesFlagName, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
}

func parseNodeSelector(cmd *cobra.Command) (string, error) {
	return common.ParseNodeSelector(cmd, nodeFlagName, nodesFlagName)
}

func appendNodesParam(params []string, nodes string) []string {
	return common.AppendNodesParam(params, nodes)
}

func validateNodeSelector(nodeSelector string, runtimeConfig *contracts.K2sRuntimeConfig) error {
	if nodeSelector == "" {
		return nil
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		if strings.Contains(nodeSelector, ",") {
			return fmt.Errorf("multi-node selection '%s' is not supported on a Linux-only installation; only the local Linux host is available", nodeSelector)
		}

		lower := strings.ToLower(nodeSelector)
		if strings.Contains(lower, "win") {
			return fmt.Errorf("node '%s' is a Windows worker node; Linux-only installations do not contain Windows worker nodes", nodeSelector)
		}

		var cpHostname string
		if runtimeConfig.ControlPlaneConfig() != nil {
			cpHostname = strings.ToLower(runtimeConfig.ControlPlaneConfig().Hostname())
		}
		localHost, _ := os.Hostname()
		localHost = strings.ToLower(localHost)

		if lower != "linux" && (cpHostname == "" || lower != cpHostname) && (localHost == "" || lower != localHost) {
			hostname := ""
			if runtimeConfig.ControlPlaneConfig() != nil {
				hostname = runtimeConfig.ControlPlaneConfig().Hostname()
			}
			if hostname == "" {
				hostname = localHost
			}
			return fmt.Errorf("node '%s' is not part of this cluster; Linux-only installation only targets the local host node ('%s')", nodeSelector, hostname)
		}
	}

	return nil
}
