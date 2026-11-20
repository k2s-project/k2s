// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package connect

import (
	"errors"
	"fmt"
	"time"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	contracts_config "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	ipAddressFlag   = "ip-addr"
	usernameFlag    = "username"
	timeoutFlag     = "timeout"
	portFlag        = "port"
	longDescription = `Connects to a remote node.

By default this targets the control-plane node; pass --ip-addr to connect to a specific node (e.g. a worker node).

This command uses the pre-installed Windows OpenSSH client to connect to a remote node.

Since K2s does not maintain this ssh.exe, make sure it is up-to-date.
Check the client version with 'ssh -V'.
See also the OpenSSH release notes at https://www.openssh.com/releasenotes.html.
`
	example = `# Connect to a remote node
k2s node connect -i 172.19.1.100 -u remote
`
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "connect",
		Short:   "Connects to a remote node.",
		Long:    longDescription,
		Example: example,
		RunE:    connect,
	}

	cmd.Flags().StringP(ipAddressFlag, "i", "", "[required] Node IP address")
	cmd.Flags().StringP(usernameFlag, "u", "", "[required] Username for remote connection")

	cmd.MarkFlagRequired(ipAddressFlag)
	cmd.MarkFlagRequired(usernameFlag)

	cmd.Flags().Uint16P(portFlag, "p", definitions.SSHDefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, definitions.SSHDefaultTimeout.String(), "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func connect(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	connectionOptions, err := extractOptions(cmd.Flags())
	if err != nil {
		return fmt.Errorf("failed to extract connection options: %w", err)
	}

	runtimeConfig := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()
	_, err = config.ReadRuntimeConfig(runtimeConfig.Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, contracts_config.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, contracts_config.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("failed to read setup config: %w", err)
	}

	connectionOptions.SshPrivateKeyPath = runtimeConfig.Host().SshConfig().CurrentPrivateKeyPath()

	err = ssh.ConnectInteractively(*connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to connect: %w", err)
	}

	cmdSession.Finish()

	return nil
}

func extractOptions(flags *pflag.FlagSet) (*ssh.ConnectionOptions, error) {
	ipAddress, err := flags.GetString(ipAddressFlag)
	if err != nil {
		return nil, err
	}

	username, err := flags.GetString(usernameFlag)
	if err != nil {
		return nil, err
	}

	port, err := flags.GetUint16(portFlag)
	if err != nil {
		return nil, err
	}

	timeoutValue, err := flags.GetString(timeoutFlag)
	if err != nil {
		return nil, err
	}

	timeout, err := time.ParseDuration(timeoutValue)
	if err != nil {
		return nil, err
	}

	return &ssh.ConnectionOptions{
		IpAddress:  ipAddress,
		RemoteUser: username,
		Timeout:    timeout,
		Port:       port,
	}, nil
}
