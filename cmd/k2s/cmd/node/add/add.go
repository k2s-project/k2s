// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package add

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/status"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	MachineName               = "name"
	MachineNameFlagUsage      = "Hostname of the node"
	MachineIPAddress          = "ip-addr"
	MachineIPAddressFlagUsage = "IP address of the node"
	MachineUsername           = "username"
	MachineUsernameFlagUsage  = "Username of the node for remote connection"
	MachineRole               = "role"
	MachineRoleFlagUsage      = "Role of the node (currently only 'worker' is supported)"
	supportedRole             = "worker"
	NodePackagePath           = "node-package"
	NodePackagePathFlagUsage  = "Path to a node package zip (offline installation). When provided, packages and images from the zip are used instead of downloading from the internet. If the package was created with --include-gpu and an NVIDIA GPU is detected on the target node, GPU support is automatically configured (NVIDIA Container Toolkit installed, CRI-O configured, node labeled)."
	systemStatusMaxAttempts   = 5
	systemStatusRetryDelay    = 10 * time.Second
)

var supportedRoles = []string{supportedRole}

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Add a node to the cluster",
		Long:  "Adds a node to an existing K2s cluster. Currently, the supported onboarding workflow covers Linux worker nodes on physical machines or existing VMs. Support for Windows worker nodes will follow.",
		Example: `  # Add a Linux worker node (online installation)
  k2s node add --ip-addr 192.168.1.50 --username admin

  # Add a Linux worker node with a custom hostname
  k2s node add --ip-addr 192.168.1.50 --username admin --name worker-node-1

  # Add a Linux worker node offline using a node package
  k2s node add --ip-addr 192.168.1.50 --username admin --node-package C:\packages\debian13-node.zip

  # GPU support is automatically configured when an NVIDIA GPU is detected on the node.
  # For offline installations with GPU, use a package created with --include-gpu:
  k2s node add --ip-addr 192.168.1.50 --username admin --node-package C:\packages\debian13-node-gpu.zip`,
		PreRunE: func(cmd *cobra.Command, args []string) error {
			role, err := cmd.Flags().GetString(MachineRole)
			if err != nil {
				return err
			}
			return validateRole(role)
		},
		RunE: addNode,
	}
	cmd.Flags().StringP(MachineIPAddress, "i", "", MachineIPAddressFlagUsage)
	cmd.Flags().StringP(MachineUsername, "u", "", MachineUsernameFlagUsage)
	cmd.Flags().StringP(MachineName, "m", "", MachineNameFlagUsage)
	cmd.Flags().StringP(MachineRole, "r", supportedRole, MachineRoleFlagUsage)
	cmd.Flags().StringP(NodePackagePath, "p", "", NodePackagePathFlagUsage)

	cmd.RegisterFlagCompletionFunc(MachineRole, cobra.FixedCompletions(supportedRoles, cobra.ShellCompDirectiveNoFileComp))

	cmd.MarkFlagRequired(MachineIPAddress)
	cmd.MarkFlagRequired(MachineUsername)
	cmd.MarkFlagsRequiredTogether(MachineIPAddress, MachineUsername)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func addNode(ccmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(ccmd.CommandPath())
	cmdContext := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(cmdContext.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if err := cmdContext.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	systemStatus, err := loadSystemStatusWithRetry(
		ccmd.Context(),
		func() (*status.LoadedStatus, error) {
			return status.LoadStatus(cmdContext)
		},
		systemStatusMaxAttempts,
		systemStatusRetryDelay,
	)
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	if runtimeConfig.InstallConfig().SetupName() != definitions.SetupNameK2s {
		return errors.New("adding node is not supported for this setup type. Aborting")
	}

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	machineUserName := ccmd.Flags().Lookup(MachineUsername).Value.String()
	machineIpAddress := ccmd.Flags().Lookup(MachineIPAddress).Value.String()
	machineName := ccmd.Flags().Lookup(MachineName).Value.String()
	nodePackagePath := ccmd.Flags().Lookup(NodePackagePath).Value.String()

	if machineUserName == "" {
		return fmt.Errorf("flag --%s is required", MachineUsername)
	}

	isLocalVM, err := config.DetectLocalVM(machineIpAddress, cmdContext.Config().Host().K2sInstallDir())
	if err != nil {
		return fmt.Errorf("failed to determine node type: %w", err)
	}

	if isLocalVM {
		pterm.Printfln("🖥️  Detected local Hyper-V VM on KubeSwitch network — using local-VM provisioning path")
	}

	pterm.Printfln("🤖 Adding node to K2s cluster")

	if err := cmdContext.Providers().Node.Add(provider.NodeAddConfig{
		IpAddress:       machineIpAddress,
		UserName:        machineUserName,
		NodeName:        machineName,
		NodePackagePath: nodePackagePath,
		ShowOutput:      outputFlag,
		IsLocalVM:       isLocalVM,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func validateRole(role string) error {
	if strings.EqualFold(strings.TrimSpace(role), supportedRole) {
		return nil
	}
	return &common.CmdFailure{
		Severity: common.SeverityWarning,
		Code:     "node-role-not-supported",
		Message: fmt.Sprintf("Adding a node with role '%s' is not supported yet. Supported roles: %s",
			role, strings.Join(supportedRoles, ", ")),
	}
}

func loadSystemStatusWithRetry(
	ctx context.Context,
	loadStatus func() (*status.LoadedStatus, error),
	maxAttempts int,
	retryDelay time.Duration,
) (*status.LoadedStatus, error) {
	if maxAttempts < 1 {
		return nil, errors.New("system status max attempts must be at least one")
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		systemStatus, err := loadStatus()
		if err == nil {
			return systemStatus, nil
		}

		lastErr = err
		if attempt == maxAttempts {
			break
		}

		slog.Warn("Could not determine system status; retrying",
			"error", err,
			"attempt", attempt,
			"maxAttempts", maxAttempts,
			"retryDelay", retryDelay)

		timer := time.NewTimer(retryDelay)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return nil, ctx.Err()
		case <-timer.C:
		}
	}

	return nil, lastErr
}

func buildAddNodeCmd(flags *pflag.FlagSet, setupName string) (string, error) {
	outputFlag, err := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if setupName != definitions.SetupNameK2s {
		return "", errors.New("adding node is not supported for this setup type. Aborting")
	}

	cmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "worker", "linux", "bare-metal", "Add.ps1"))

	if outputFlag {
		cmd += " -ShowLogs"
	}

	// role flag is accepted but only 'worker' is currently implemented

	machineUserName := flags.Lookup(MachineUsername).Value.String()
	machineIpAddress := flags.Lookup(MachineIPAddress).Value.String()
	machineName := flags.Lookup(MachineName).Value.String()
	nodePackagePath := flags.Lookup(NodePackagePath).Value.String()

	cmd += " -UserName " + machineUserName
	cmd += " -IpAddress " + machineIpAddress

	if machineName != "" {
		cmd += " -NodeName " + machineName
	}

	if nodePackagePath != "" {
		cmd += " -NodePackagePath " + utils.EscapeWithSingleQuotes(nodePackagePath)
	}

	return cmd, nil
}
