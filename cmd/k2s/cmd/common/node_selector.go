// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
)

// ParseNodeSelector reads the nodes/node flags (identified by nodeFlagName and nodesFlagName) and
// returns the trimmed node name(s) (empty when not set). When both flags are specified, the
// nodes flag takes precedence over the node flag.
func ParseNodeSelector(cmd *cobra.Command, nodeFlagName, nodesFlagName string) (string, error) {
	nodesOption, err := cmd.Flags().GetString(nodesFlagName)
	if err != nil {
		return "", err
	}

	nodeOption, err := cmd.Flags().GetString(nodeFlagName)
	if err != nil {
		return "", err
	}

	nodeSelector := strings.TrimSpace(nodesOption)
	if IsNodeSelectorEmpty(nodeSelector) {
		nodeSelector = strings.TrimSpace(nodeOption)
	}

	return nodeSelector, nil
}

// AppendNodesParam appends the -Nodes parameter to the PS call only when a node selector is provided.
func AppendNodesParam(params []string, nodes string) []string {
	if IsNodeSelectorEmpty(nodes) {
		return params
	}

	return append(params, " -Nodes "+utils.EscapeWithSingleQuotes(nodes))
}

// IsNodeSelectorEmpty reports whether a comma-separated node selector contains no non-blank entries.
func IsNodeSelectorEmpty(selector string) bool {
	parts := strings.Split(selector, ",")
	for _, p := range parts {
		if strings.TrimSpace(p) != "" {
			return false
		}
	}
	return true
}

// ValidateNodeSelector validates a node selector against the runtime configuration.
// On Linux-only installations, it rejects multi-node selectors, Windows-worker selectors,
// and unknown non-local hostnames.
func ValidateNodeSelector(nodeSelector string, runtimeConfig *contracts.K2sRuntimeConfig) error {
	if IsNodeSelectorEmpty(nodeSelector) {
		return nil
	}

	if runtimeConfig == nil || runtimeConfig.InstallConfig() == nil || !runtimeConfig.InstallConfig().LinuxOnly() {
		return nil
	}

	if strings.Contains(nodeSelector, ",") {
		return fmt.Errorf("multi-node selection '%s' is not supported on a Linux-only installation; only the local Linux host is available", nodeSelector)
	}

	lower := strings.ToLower(strings.TrimSpace(nodeSelector))
	if isWindowsWorkerSelector(lower) {
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

	return nil
}

func isWindowsWorkerSelector(lower string) bool {
	return lower == "windows" ||
		lower == "win-worker" ||
		lower == "k2s-win-worker" ||
		strings.HasPrefix(lower, "win-worker-") ||
		strings.HasPrefix(lower, "winworker")
}
