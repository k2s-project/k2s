// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	targetImageNameFlagName = "target-name"
	tagCommandExample       = `
  # Tag image on default nodes (Linux control-plane and local Windows host)
  k2s image tag -n k2s.registry.local/myimage:v1 -t k2s.registry.local/myimage:release
  k2s image tag --id 7ca25e0fabd39 -t k2s.registry.local/myimage:release

  # Tag an image on a specific worker node
  k2s image tag --id 7ca25e0fabd39 -t k2s.registry.local/myimage:release --node worker-1
  k2s image tag -n k2s.registry.local/myimage:v1 -t k2s.registry.local/myimage:release --node worker-1

  # Tag an image on multiple specific nodes
  k2s image tag --id 7ca25e0fabd39 -t k2s.registry.local/myimage:release --nodes worker-1,worker-2
  k2s image tag -n k2s.registry.local/myimage:v1 -t k2s.registry.local/myimage:release --nodes worker-1,worker-2
`
	tagCmd = &cobra.Command{
		Use:     "tag",
		Short:   "Tag an image",
		Example: tagCommandExample,
		RunE:    tagImage,
	}
)

func init() {
	tagCmd.Flags().String(imageIdFlagName, "", "Image ID of the container image")
	tagCmd.Flags().StringP(imageNameFlagName, "n", "", "Name of the container image including tag")
	addNodeSelectionFlags(tagCmd)
	tagCmd.Flags().StringP(targetImageNameFlagName, "t", "", "New name of the container image including tag")
	tagCmd.Flags().SortFlags = false
	tagCmd.Flags().PrintDefaults()
}

func tagImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	pterm.Println("🤖 Tagging container image..")

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageNameFlagName, err)
	}

	targetImageName, err := cmd.Flags().GetString(targetImageNameFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", targetImageNameFlagName, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	if imageId == "" && imageName == "" {
		return errors.New("no image id or image name provided")
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

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	if err := validateNodeSelector(nodeSelector, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.Tag(provider.ImageTagConfig{
		ImageId:         imageId,
		ImageName:       imageName,
		Nodes:           nodeSelector,
		TargetImageName: targetImageName,
		ShowOutput:      showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
