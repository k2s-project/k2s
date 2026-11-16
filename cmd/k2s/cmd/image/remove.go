// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
)

type removeOptions struct {
	imageId      string
	imageName    string
	nodes        string
	fromRegistry bool
	force        bool
	showOutput   bool
}

var (
	imageIdFlagName       = "id"
	removeImgNameFlagName = "name"
	fromRegistryFlagName  = "from-registry"
	forceFlagName         = "force"

	removeExample = `
  # Remove image by id from default nodes (Linux control-plane and local Windows host)
  k2s image rm --id 042a816809aa

  # Remove image from a specific worker node only
  k2s image rm --node worker-1 --id 042a816809aa 

  # Remove image from multiple specific nodes (same id is removed on each node independently)
  k2s image rm --nodes worker-1,worker-2 --id 042a816809aa

  # Remove image by name from default nodes
  k2s image rm --name myimage:v1

  # Remove image by name from a specific worker node only
  k2s image rm --node worker-1 --name myimage:v1

  # Remove image by name from multiple specific nodes (same name is removed on each node independently)
  k2s image rm --nodes worker-1,worker-2 --name myimage:v1

  # Remove a pushed image from the local registry
  k2s image rm --name k2s.registry.local/alpine:v1 --from-registry
`

	removeCmd = &cobra.Command{
		Use:     "rm",
		Short:   "Remove container image using image id or image name",
		Example: removeExample,
		RunE:    removeImage,
	}
)

func init() {
	addInitFlagsForRemoveCommand(removeCmd)
}

func addInitFlagsForRemoveCommand(cmd *cobra.Command) {
	cmd.Flags().StringP(imageIdFlagName, "i", "", "Image ID of the container image")
	cmd.Flags().StringP(removeImgNameFlagName, "n", "", "Name of the container image")
	addNodeSelectionFlags(cmd)
	cmd.Flags().Bool(fromRegistryFlagName, false, "Remove image from local registry (when registry addon is enabled)")
	cmd.Flags().BoolP(forceFlagName, "f", false, "Force removal by first removing any containers using the image")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func removeImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Removing container image..")

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

	options, err := extractRemoveOptions(cmd)
	if err != nil {
		return err
	}

	if err := validateNodeSelector(options.nodes, runtimeConfig); err != nil {
		return err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	if err := context.Providers().Image.Remove(provider.ImageRemoveConfig{
		ImageId:      options.imageId,
		ImageName:    options.imageName,
		Nodes:        options.nodes,
		FromRegistry: options.fromRegistry,
		Force:        options.force,
		ShowOutput:   options.showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func extractRemoveOptions(cmd *cobra.Command) (*removeOptions, error) {
	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(removeImgNameFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", removeImgNameFlagName, err)
	}

	nodes, err := parseNodeSelector(cmd)
	if err != nil {
		return nil, err
	}

	fromRegistry, err := strconv.ParseBool(cmd.Flags().Lookup(fromRegistryFlagName).Value.String())
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", fromRegistryFlagName, err)
	}

	force, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlagName).Value.String())
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", forceFlagName, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	return &removeOptions{
		imageId:      imageId,
		imageName:    imageName,
		nodes:        nodes,
		fromRegistry: fromRegistry,
		force:        force,
		showOutput:   showOutput,
	}, nil
}
