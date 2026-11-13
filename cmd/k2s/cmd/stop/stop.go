// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package stop

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	cc "github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

var StopK8sCmd = &cobra.Command{
	Use:   "stop",
	Short: "Stops K2s cluster on the host machine",
	RunE:  stopk8s,
}

func init() {
	StopK8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	StopK8sCmd.Flags().BoolP(common.CacheVSwitchFlagName, "", false, common.CacheVSwitchFlagUsage)
	StopK8sCmd.Flags().String(common.NodeFlagName, "", common.NodeFlagUsage)
	StopK8sCmd.Flags().BoolP("no-wait", "", false, "Skip waiting for node readiness transition (skip the ~50 second wait for NotReady state)")
	StopK8sCmd.Flags().SortFlags = false
	StopK8sCmd.Flags().PrintDefaults()
}

func stopk8s(cmd *cobra.Command, args []string) error {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	targetNodeName := strings.TrimSpace(cmd.Flags().Lookup(common.NodeFlagName).Value.String())

	cmdDisplayName := cmd.CommandPath()
	if targetNodeName != "" {
		cmdDisplayName = fmt.Sprintf("%s --node %s", cmdDisplayName, targetNodeName)
	}

	cmdSession := common.StartCmdSession(cmdDisplayName)

	if targetNodeName != "" {
		pterm.Printfln("🛑 Stopping K2s node '%s'", targetNodeName)
	} else {
		pterm.Printfln("🛑 Stopping K2s cluster")
	}
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if targetNodeName != "" {
		if err := stopNodeByName(context, cmd.Flags(), targetNodeName); err != nil {
			return err
		}

		cmdSession.Finish()
		return nil
	}

	err = stopAdditionalNodes(context, cmd.Flags())
	if err != nil {
		// Stop of additional nodes shall not impact the k2s cluster stop, any errors during stop should be treated as warnings.
		slog.Warn("Failures during stopping of additional nodes", "err", err)
	}

	// Read flags
	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	cacheVSwitches, err := strconv.ParseBool(cmd.Flags().Lookup(common.CacheVSwitchFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	setupName := runtimeConfig.InstallConfig().SetupName()
	linuxOnly := runtimeConfig.InstallConfig().LinuxOnly()

	// Stop cluster via provider (handles platform dispatch)
	err = context.Providers().Cluster.Stop(provider.ClusterStopConfig{
		ShowLogs:           outputFlag,
		AdditionalHooksDir: additionalHooksDir,
		CacheVSwitch:       cacheVSwitches,
		SetupName:          setupName,
		LinuxOnly:          linuxOnly,
	})
	if err != nil {
		return err
	}

	cmdSession.Finish()
	return nil
}

func stopNodeByName(context *common.CmdContext, flags *pflag.FlagSet, nodeName string) error {
	clusterConfig, err := cc.Read(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if clusterConfig == nil {
		return fmt.Errorf("node %q not found: no additional nodes configured", nodeName)
	}

	node, found := findNodeByName(clusterConfig.Nodes, nodeName)
	if !found {
		return fmt.Errorf("node %q not found in additional node configuration", nodeName)
	}

	stopNodeCmd := buildNodeStopCmd(flags, node, true)
	slog.Debug("PS command created", "command", stopNodeCmd)

	return powershell.ExecutePs(stopNodeCmd, common.NewPtermWriter())
}

func findNodeByName(nodes []cc.Node, nodeName string) (cc.Node, bool) {
	for _, node := range nodes {
		if strings.EqualFold(strings.TrimSpace(node.Name), nodeName) {
			return node, true
		}
	}

	return cc.Node{}, false
}

func stopAdditionalNodes(context *common.CmdContext, flags *pflag.FlagSet) error {
	systemStatus, err := status.LoadStatus(context)
	if err != nil || !systemStatus.RunningState.IsRunning {
		// Nothing to do if system is not running
		return nil
	}

	clusterConfig, err := cc.Read(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if clusterConfig == nil {
		return nil
	}

	for _, node := range clusterConfig.Nodes {
		startNodeCmd := buildNodeStopCmd(flags, node, false)

		slog.Debug("PS command created", "command", startNodeCmd)

		err = powershell.ExecutePs(startNodeCmd, common.NewPtermWriter())
		if err != nil {
			slog.Warn("Failure during stop of node", "node", node.Name, "err", err)
		}
	}

	return nil
}

func buildNodeStopCmd(flags *pflag.FlagSet, nodeConfig cc.Node, singleNode bool) string {
	outputFlag, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	roleType := string(nodeConfig.Role)
	OsType := string(nodeConfig.OS)

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", roleType, OsType, "bare-metal", "Stop.ps1"))

	if outputFlag {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if nodeConfig.Name != "" {
		cmd += " -NodeName " + nodeConfig.Name
	}

	// -WaitForNotReady (service stop + readiness polling) only applies when
	// targeting a specific node via --node. Full cluster stop does not need it.
	if singleNode {
		cmd += " -SingleNode"

		noWait, _ := strconv.ParseBool(flags.Lookup("no-wait").Value.String())
		if !noWait {
			cmd += " -WaitForNotReady"
		}
	}

	return cmd
}
