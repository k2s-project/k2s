// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"strconv"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/spf13/cobra"
)

var (
	exportCommandExample = `
  # Export image to tar archive; image is looked up on default nodes (Linux control-plane and local Windows host)
  k2s image export --id fcecffc7ad4a -t C:\tmp\exportedImage.tar

  # Export image that resides on a specific worker node
  k2s image export --node worker-1 --id fcecffc7ad4a -t C:\tmp\exportedImage.tar 

  # Export Linux image as docker-archive from a specific worker node
  k2s image export --node worker-1 --id fcecffc7ad4a -t C:\tmp\exportedImage.tar --docker-archive
`

	exportCmd = &cobra.Command{
		Use:     "export",
		Short:   "Export an image to tar archive",
		Example: exportCommandExample,
		RunE:    exportImage,
	}
)

func init() {
	exportCmd.Flags().StringP(imageIdFlagName, "i", "", "Image ID of the container image")
	exportCmd.Flags().StringP(removeImgNameFlagName, "n", "", "Name of the container image including tag")
	addNodeSelectionFlags(exportCmd)
	exportCmd.Flags().StringP(tarFlag, "t", "", "Export tar file path")
	exportCmd.Flags().Bool(dockerArchiveFlag, false, "Export Linux image as docker-archive (default: oci-archive)")
	exportCmd.Flags().SortFlags = false
	exportCmd.Flags().PrintDefaults()
}

func exportImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	imageId, err := cmd.Flags().GetString(imageIdFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", imageIdFlagName, err)
	}

	imageName, err := cmd.Flags().GetString(removeImgNameFlagName)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", removeImgNameFlagName, err)
	}

	exportPath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	if imageId == "" && imageName == "" && len(args) > 0 {
		imageName = args[0]
	}
	if exportPath == "" && len(args) > 1 {
		exportPath = args[1]
	}

	if imageId == "" && imageName == "" {
		return errors.New("no image id or image name provided")
	}

	if exportPath == "" {
		return errors.New("no export path provided")
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return err
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

	if err := context.Providers().Image.Export(provider.ImageExportConfig{
		ImageId:       imageId,
		ImageName:     imageName,
		Nodes:         nodeSelector,
		OutputPath:    exportPath,
		DockerArchive: isDockerArchive,
		ShowOutput:    showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
