// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package copy

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
	reverseFlag     = "reverse"
	ipAddressFlag   = "ip-addr"
	sourceFlag      = "source"
	targetFlag      = "target"
	usernameFlag    = "username"
	timeoutFlag     = "timeout"
	portFlag        = "port"
	longDescription = `Copies files/folders to/from nodes (default: to node).

By default this targets the control-plane node; pass --ip-addr to copy to/from a specific node (e.g. a worker node).

The copy command behaves similar to the 'cp' command on Linux:
- If the target file exists, it will be overwritten without prompting.
- If the target folder does not exist, it gets created when the target's parent folder exists.
- If the target contains a folder with the same name as the source folder, all files will be copied into it, overwriting existing files that match the source files.
	
Remote node paths can but do not need to contain a tilde (~) since the working directory will always be the home directory of the node user, e.g.
'~/my-file' equals to 'my-file' equals to '/home/<user>/my-file'. Locally (on the host), the working directory is the current working directory of the command execution.
`
	example = `# Copy a file from host to node, e.g. to home dir
	k2s node copy -i 172.19.1.100 -u remote -s C:\path\to\my-file -t ~/

	- or -

	k2s node copy -i 172.19.1.100 -u remote -s C:\path\to\my-file -t ~/my-file	


# Copy a folder from host to node, e.g. to home dir
	k2s node copy -i 172.19.1.100 -u remote -s C:\path\to\my-folder\ -t ~/


# Copy a file from node to host, e.g. from home dir on node
	k2s node copy -r -i 172.19.1.100 -u remote -s my-file -t C:\temp\my-file


# Copy a folder from node to host, e.g. from home dir on node
	k2s node copy -r -i 172.19.1.100 -u remote -s my-folder/ -t C:\temp\
`
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "copy",
		Short:   "Copies files/folders between host and a node (default: the control-plane node).",
		Long:    longDescription,
		Example: example,
		RunE:    copy,
	}

	cmd.Flags().StringP(ipAddressFlag, "i", "", "[required] Node IP address")
	cmd.Flags().StringP(usernameFlag, "u", "", "[required] Username for remote connection")
	cmd.Flags().StringP(sourceFlag, "s", "", "[required] Source file or folder to copy")
	cmd.Flags().StringP(targetFlag, "t", "", "[required] Target file or folder")

	cmd.MarkFlagRequired(ipAddressFlag)
	cmd.MarkFlagRequired(usernameFlag)
	cmd.MarkFlagRequired(sourceFlag)
	cmd.MarkFlagRequired(targetFlag)

	cmd.Flags().BoolP(reverseFlag, "r", false, "Copy from node to host (i.e. reverse direction)")
	cmd.Flags().Uint16P(portFlag, "p", definitions.SSHDefaultPort, "Port for remote connection")
	cmd.Flags().String(timeoutFlag, definitions.SSHDefaultTimeout.String(), "Connection timeout, e.g. '1m20s', allowed time units are 'ns', 'us' (or 'µs'), 'ms', 's', 'm', 'h'")

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func copy(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	k2sConfig := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()
	_, err := config.ReadRuntimeConfig(k2sConfig.Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, contracts_config.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		if errors.Is(err, contracts_config.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("failed to read setup config: %w", err)
	}

	connectionOptions, err := extractConnectionOptions(cmd.Flags(), k2sConfig.Host().SshConfig().CurrentPrivateKeyPath())
	if err != nil {
		return fmt.Errorf("failed to extract connection options: %w", err)
	}
	source, target, reverse, err := extractCopyOptions(cmd.Flags())
	if err != nil {
		return fmt.Errorf("failed to extract copy options: %w", err)
	}

	sshProvider := ssh.NewSSH(*connectionOptions)

	if reverse {
		err = sshProvider.CopyFromNode(source, target)
	} else {
		err = sshProvider.CopyToNode(source, target)
	}
	if err != nil {
		return fmt.Errorf("failed to copy from '%s' to '%s' (reverse=%t): %w", source, target, reverse, err)
	}

	cmdSession.Finish()

	return nil
}

func extractConnectionOptions(flags *pflag.FlagSet, sshPrivateKeyPath string) (*ssh.ConnectionOptions, error) {
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
		IpAddress:         ipAddress,
		RemoteUser:        username,
		Timeout:           timeout,
		Port:              port,
		SshPrivateKeyPath: sshPrivateKeyPath,
	}, nil
}
func extractCopyOptions(flags *pflag.FlagSet) (source, target string, reverse bool, err error) {
	source, err = flags.GetString(sourceFlag)
	if err != nil {
		return "", "", false, err
	}

	target, err = flags.GetString(targetFlag)
	if err != nil {
		return "", "", false, err
	}

	reverse, err = flags.GetBool(reverseFlag)
	if err != nil {
		return "", "", false, err
	}
	return
}
