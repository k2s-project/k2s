// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dump

import (
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
)

var (
	skipOpenDumpFlagName = "skip-open"
	nodeFlagName         = "node"
	nodesFlagName        = "nodes"
	dumpCommandExample   = `
	# Create a system dump and keep Explorer closed afterwards
	k2s system dump --skip-open

	# Create a dump including additional diagnostics for one node:
	k2s system dump --node worker-1

	# Create a dump including additional diagnostics for multiple nodes:
	k2s system dump --nodes worker-1,worker-2 --skip-open
`
)

var DumpCmd = &cobra.Command{
	Use:     "dump",
	Short:   "Dump system status",
	Long:    "Dump system status to target folder",
	RunE:    dumpSystemStatus,
	Example: dumpCommandExample,
}

func init() {
	DumpCmd.Flags().BoolP(skipOpenDumpFlagName, "S", false, "If set to true, opening the dump target folder will be skipped")
	DumpCmd.Flags().String(nodeFlagName, "", "Additional node name to collect diagnostics for (e.g. worker-1)")
	DumpCmd.Flags().String(nodesFlagName, "", "Comma-separated additional node names to collect diagnostics for (e.g. worker-1,worker-2)")
	DumpCmd.Flags().SortFlags = false
	DumpCmd.Flags().PrintDefaults()
}

func dumpSystemStatus(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	skipOpenDumpFlag, err := strconv.ParseBool(cmd.Flags().Lookup(skipOpenDumpFlagName).Value.String())
	if err != nil {
		return err
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	nodesOption, err := cmd.Flags().GetString(nodesFlagName)
	if err != nil {
		return err
	}

	nodeOption, err := cmd.Flags().GetString(nodeFlagName)
	if err != nil {
		return err
	}

	nodeSelector := strings.TrimSpace(nodesOption)
	if nodeSelector == "" {
		nodeSelector = strings.TrimSpace(nodeOption)
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	if err := context.Providers().System.Dump(provider.SystemDumpConfig{
		SkipOpenDump: skipOpenDumpFlag,
		ShowOutput:   outputFlag,
		Nodes:        nodeSelector,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
