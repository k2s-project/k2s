// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package start

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/k2s-project/k2s/cmd/k2s/utils/tz"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cc "github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/providers/powershell"
)

var Startk8sCmd = &cobra.Command{
	Use:   "start",
	Short: "Starts K2s cluster on the host machine",
	Long: `Starts K2s.

Default behavior (without --node):
	Starts the full K2s cluster on the host machine.

Node behavior (with --node):
	Starts only the specified additional node.

Related node stop operation:
	Use 'k2s stop --node <node-name>' to stop a specific additional node.`,
	Example: `  # Start full cluster
	k2s start

	# Start only one additional node
	k2s start --node worker

	# Stop only one additional node
	k2s stop --node worker`,
	Args: func(cmd *cobra.Command, args []string) error {
		if len(args) > 0 {
			return fmt.Errorf("unexpected argument(s): %s. Use '%s --node <node-name>' to start a specific additional node", strings.Join(args, " "), cmd.CommandPath())
		}

		return nil
	},
	RunE: startk8s,
}

func init() {
	Startk8sCmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	Startk8sCmd.Flags().BoolP(common.AutouseCachedVSwitchFlagName, "", false, common.AutouseCachedVSwitchFlagUsage)
	Startk8sCmd.Flags().BoolP(common.IgnoreIfRunningFlagName, common.IgnoreIfRunningFlagShort, false, common.IgnoreIfRunningFlagUsage)
	Startk8sCmd.Flags().String(common.NodeFlagName, "", common.NodeFlagUsage)
	Startk8sCmd.Flags().SortFlags = false
	Startk8sCmd.Flags().PrintDefaults()
}

func startk8s(ccmd *cobra.Command, args []string) error {
	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	targetNodeName := strings.TrimSpace(ccmd.Flags().Lookup(common.NodeFlagName).Value.String())

	cmdSession := common.StartCmdSession(buildStartCmdDisplayName(ccmd, targetNodeName))

	printStartBanner(targetNodeName)

	skipStartIfRunning, err := handleIgnoreIfRunningForClusterStart(ccmd, context, targetNodeName)
	if err != nil {
		return err
	}
	if skipStartIfRunning {
		cmdSession.Finish()
		return nil
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

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	startedSingleNode, err := StartSingleNode(context, ccmd.Flags(), targetNodeName)
	if err != nil {
		return err
	}
	if startedSingleNode {
		cmdSession.Finish()
		return nil
	}

	tzConfigHandle, err := createTimezoneConfigHandle(context.Config().Host().KubeConfig())
	if err != nil {
		return err
	}
	defer tzConfigHandle.Release()

	// Read flags
	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	additionalHooksDir := ccmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	autouseCachedVSwitch, err := strconv.ParseBool(ccmd.Flags().Lookup(common.AutouseCachedVSwitchFlagName).Value.String())
	if err != nil {
		return err
	}

	// Determine setup info from runtime config
	setupName := runtimeConfig.InstallConfig().SetupName()
	linuxOnly := runtimeConfig.InstallConfig().LinuxOnly()

	// Start cluster via provider (handles platform dispatch)
	err = context.Providers().Cluster.Start(provider.ClusterStartConfig{
		ShowLogs:            outputFlag,
		AdditionalHooksDir:  additionalHooksDir,
		UseCachedK2sVSwitch: autouseCachedVSwitch,
		SetupName:           setupName,
		LinuxOnly:           linuxOnly,
	})
	if err != nil {
		return err
	}

	err = startAdditionalNodes(context, ccmd.Flags(), runtimeConfig)
	if err != nil {
		// Start of additional nodes shall not impact the k2s cluster, any errors during startup should be treated as warnings.
		slog.Warn("Failures during starting of additional nodes", "err", err)
	}

	cmdSession.Finish()
	return nil
}

func buildStartCmdDisplayName(ccmd *cobra.Command, targetNodeName string) string {
	cmdDisplayName := ccmd.CommandPath()
	if targetNodeName != "" {
		cmdDisplayName = fmt.Sprintf("%s --node %s", cmdDisplayName, targetNodeName)
	}
	return cmdDisplayName
}

func handleIgnoreIfRunningForClusterStart(ccmd *cobra.Command, context *common.CmdContext, targetNodeName string) (bool, error) {
	if targetNodeName != "" {
		return false, nil
	}

	return HandleIgnoreIfRunning(ccmd, func() (bool, error) {
		return isClusterRunning(context)
	})
}

func StartSingleNode(context *common.CmdContext, flags *pflag.FlagSet, targetNodeName string) (bool, error) {
	if targetNodeName == "" {
		return false, nil
	}

	if err := startNodeByName(context, flags, targetNodeName); err != nil {
		return false, err
	}

	return true, nil
}

func printStartBanner(targetNodeName string) {
	if targetNodeName != "" {
		pterm.Printfln("🤖 Starting K2s node '%s'", targetNodeName)
		return
	}

	pterm.Printfln("🤖 Starting K2s on %s", utils.Platform())
}

func startNodeByName(context *common.CmdContext, flags *pflag.FlagSet, nodeName string) error {
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

	startNodeCmd := buildNodeStartCmd(flags, node, true)
	slog.Debug("PS command created", "command", startNodeCmd)

	return powershell.ExecutePs(startNodeCmd, common.NewPtermWriter())
}

func findNodeByName(nodes []cc.Node, nodeName string) (cc.Node, bool) {
	for _, node := range nodes {
		if strings.EqualFold(strings.TrimSpace(node.Name), nodeName) {
			return node, true
		}
	}

	return cc.Node{}, false
}

func startAdditionalNodes(context *common.CmdContext, flags *pflag.FlagSet, config *cconfig.K2sRuntimeConfig) error {
	clusterConfig, err := cc.Read(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	if clusterConfig == nil {
		return nil
	}

	for _, node := range clusterConfig.Nodes {
		startNodeCmd := buildNodeStartCmd(flags, node, false)

		slog.Debug("PS command created", "command", startNodeCmd)

		err = powershell.ExecutePs(startNodeCmd, common.NewPtermWriter())
		if err != nil {
			slog.Warn("Failure during start of node", "node", node.Name, "err", err)
		}
	}

	return nil
}

func isClusterRunning(ctx *common.CmdContext) (bool, error) {

	clusterStatus, err := status.LoadStatus(ctx)
	if err != nil {
		slog.Error("Failed to load cluster status", "error", err)
		return false, err
	}

	if clusterStatus != nil && clusterStatus.RunningState.IsRunning {
		return clusterStatus.RunningState != nil && clusterStatus.RunningState.IsRunning, nil
	}

	return false, nil
}

func HandleIgnoreIfRunning(ccmd *cobra.Command, clusterIsRunning func() (bool, error)) (bool, error) {
	ignoreIfRunning, err := strconv.ParseBool(ccmd.Flags().Lookup(common.IgnoreIfRunningFlagName).Value.String())
	if err != nil {
		return false, err
	}

	if ignoreIfRunning {
		isRunning, err := clusterIsRunning()
		if err != nil {
			return false, err
		}
		if isRunning {
			pterm.Printfln("🚀 K2s cluster is already running. Skipping start.")
			return true, nil
		}
	}

	return false, nil
}

func buildNodeStartCmd(flags *pflag.FlagSet, nodeConfig cc.Node, singleNode bool) string {
	outputFlag, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())

	additionalHooksDir := flags.Lookup(common.AdditionalHooksDirFlagName).Value.String()

	roleType := string(nodeConfig.Role)
	OsType := string(nodeConfig.OS)

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", roleType, OsType, "bare-metal", "Start.ps1"))

	if outputFlag {
		cmd += " -ShowLogs"
	}

	if additionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}

	if nodeConfig.IpAddress != "" {
		cmd += " -IpAddress " + nodeConfig.IpAddress
	}

	if nodeConfig.Name != "" {
		cmd += " -NodeName " + nodeConfig.Name
	}

	if singleNode {
		cmd += " -SingleNode"
	}

	return cmd
}

func createTimezoneConfigHandle(config *contracts.KubeConfig) (tz.ConfigWorkspaceHandle, error) {
	tzConfigWorkspace, err := tz.NewTimezoneConfigWorkspace(config)
	if err != nil {
		return nil, err
	}
	tzConfigHandle, err := tzConfigWorkspace.CreateHandle()
	if err != nil {
		return nil, err
	}
	return tzConfigHandle, nil
}
