// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common

import (
	"strings"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/utils"
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
