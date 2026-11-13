// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

const (
	usernameFlag   = "username"
	passwordFlag   = "password"
	skipVerifyFlag = "skip-verify"
	plainHttpFlag  = "plain-http"
	nodeFlag       = "node"
	nodesFlag      = "nodes"
)

var (
	addExample = `
	# Add registry in K2s (enter credentials afterwards)
	k2s image registry add ghcr.io

	# Add registry only on one selected node (enter credentials afterwards)
	k2s image registry add ghcr.io --node worker-1

	# Add registry on multiple selected nodes (enter credentials afterwards)
	k2s image registry add ghcr.io --nodes worker-1,worker-2

	# Add registry in K2s (enter credentials afterwards) and configure as insecure registry (skips verifying HTTPS certs, and allows falling back to plain HTTP)
	k2s image registry add ghcr.io --skip-verify --plain-http

	# Add registry on one selected node (enter credentials afterwards) and configure as insecure registry (skips verifying HTTPS certs, and allows falling back to plain HTTP)
	k2s image registry add ghcr.io --node worker-1 --skip-verify --plain-http

	# Add registry on multiple selected nodes (enter credentials afterwards) and configure as insecure registry (skips verifying HTTPS certs, and allows falling back to plain HTTP)
	k2s image registry add ghcr.io --nodes worker-1,worker-2 --skip-verify --plain-http

	# Add registry with username and password in K2s 
	k2s image registry add ghcr.io -u testuser -p testpassword

	# Add registry with username and password on one selected node
	k2s image registry add ghcr.io --node worker-1 -u testuser -p testpassword

	# Add registry with username and password on multiple selected nodes
	k2s image registry add ghcr.io --nodes worker-1,worker-2 -u testuser -p testpassword


`

	addCmd = &cobra.Command{
		Use:     "add",
		Short:   "Add container registry",
		RunE:    addRegistry,
		Example: addExample,
	}
)

func init() {
	addCmd.Flags().StringP(usernameFlag, "u", "", usernameFlag)
	addCmd.Flags().StringP(passwordFlag, "p", "", passwordFlag)
	addCmd.Flags().Bool(skipVerifyFlag, false, "Skips verifying HTTPS certs")
	addCmd.Flags().Bool(plainHttpFlag, false, "Allows falling back to plain HTTP")
	addCmd.Flags().String(nodeFlag, "", "Node name to target (e.g. worker-1)")
	addCmd.Flags().String(nodesFlag, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
	addCmd.Flags().SortFlags = false
	addCmd.Flags().PrintDefaults()
}

func addRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry add <registry-name>'")
	}

	cmdSession := common.StartCmdSession(cmd.CommandPath())
	registryName := args[0]

	slog.Info("Adding registry", "registry", registryName)

	pterm.Printfln("🤖 Adding registry '%s' to K2s cluster", registryName)

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	username, err := cmd.Flags().GetString(usernameFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", usernameFlag, err)
	}

	password, err := cmd.Flags().GetString(passwordFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", passwordFlag, err)
	}

	skipVerify, err := strconv.ParseBool(cmd.Flags().Lookup(skipVerifyFlag).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", skipVerifyFlag, err)
	}

	plainHttp, err := strconv.ParseBool(cmd.Flags().Lookup(plainHttpFlag).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", plainHttpFlag, err)
	}

	nodesSelection, err := cmd.Flags().GetString(nodesFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodesFlag, err)
	}

	nodeSelection, err := cmd.Flags().GetString(nodeFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodeFlag, err)
	}

	nodesParam := strings.TrimSpace(nodesSelection)
	if nodesParam == "" {
		nodesParam = strings.TrimSpace(nodeSelection)
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
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

	if err := validateNodeSelector(nodesParam, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.RegistryAdd(provider.ImageRegistryAddConfig{
		RegistryName: registryName,
		Username:     username,
		Password:     password,
		SkipVerify:   skipVerify,
		PlainHttp:    plainHttp,
		Nodes:        nodesParam,
		ShowOutput:   showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
