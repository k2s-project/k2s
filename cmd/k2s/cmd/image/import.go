// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/spf13/cobra"
)

const (
	windowsFlag       = "windows"
	dockerArchiveFlag = "docker-archive"
	tarFlag           = "tar"
	dirFlag           = "dir"
)

var (
	importCmd = &cobra.Command{
		Use:     "import",
		Short:   "Import an image from a tar archive",
		Example: importCommandExample,
		RunE:    importImage,
	}

	importCommandExample = `
  # Import a Linux image onto the Linux control-plane (default)
  k2s image import -t C:\tmp\image.tar

  # Import a Linux image from a docker tar archive onto the Linux control-plane (default)
  k2s image import -t C:\tmp\dockerimage.tar --docker-archive

  # Import all Linux images of a multi-image docker tar archive (e.g. 'docker save img1 img2') onto the Linux control-plane (default)
  k2s image import -t C:\tmp\dockerimages.tar --docker-archive

  # Import Linux images from a directory onto the Linux control-plane (default)
  k2s image import -d C:\tmp\images

  # Import a Windows image onto the local Windows host (default)
  k2s image import -t C:\tmp\image.tar -w

  # Import all Windows images of a multi-image docker tar archive onto the local Windows host
  k2s image import -t C:\tmp\windowsimages.tar -w

  # Import a Linux image onto a specific worker node
  k2s image import --node worker-1 -t C:\tmp\image.tar 

  # Import a Linux image onto multiple specific nodes 
  k2s image import --nodes worker-1,worker-2 -t C:\tmp\image.tar 

  # Import a Linux image from a docker tar archive onto a specific worker node
  k2s image import --node worker-1 -t C:\tmp\image.tar --docker-archive

  # Import a Linux image from a docker tar archive onto multiple specific nodes 
  k2s image import --nodes worker-1,worker-2 -t C:\tmp\image.tar --docker-archive 

  # Import a Windows image onto a specific Windows worker node
  k2s image import --node winworker-1 -t C:\tmp\image.tar -w 

  # Import a Windows image onto multiple specific Windows worker nodes 
  k2s image import --nodes winworker-1,winworker-2 -t C:\tmp\image.tar -w 
`
)

func init() {
	importCmd.Flags().StringP(tarFlag, "t", "", "oci archive (tar)")
	importCmd.Flags().StringP(dirFlag, "d", "", "Path to directory with oci archives (tar) to import")
	addNodeSelectionFlags(importCmd)
	importCmd.Flags().BoolP(windowsFlag, "w", false, "Windows image")
	importCmd.Flags().Bool(dockerArchiveFlag, false, "Import Linux image from docker-archive tar (default: oci-archive)")
	importCmd.Flags().SortFlags = false
	importCmd.Flags().PrintDefaults()
}

func importImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	isWindowsImage, err := strconv.ParseBool(cmd.Flags().Lookup(windowsFlag).Value.String())
	if err != nil {
		return err
	}

	imagePath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	dir, err := cmd.Flags().GetString(dirFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", dirFlag, err)
	}

	if imagePath == "" && dir == "" {
		return errors.New("no path to oci archive provided")
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

	if runtimeConfig.InstallConfig().LinuxOnly() && isWindowsImage {
		return fmt.Errorf("importing Windows container images is not supported on a Linux-only installation")
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	if err := validateNodeSelector(nodeSelector, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.Import(provider.ImageImportConfig{
		TarPath:       imagePath,
		DirPath:       dir,
		Windows:       isWindowsImage,
		Nodes:         nodeSelector,
		DockerArchive: isDockerArchive,
		ShowOutput:    showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildImportPsCmd(cmd *cobra.Command, isWindowsImage bool) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "Import-Image.ps1"))

	imagePath, err := cmd.Flags().GetString(tarFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", tarFlag, err)
	}

	dir, err := cmd.Flags().GetString(dirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", dirFlag, err)
	}

	if imagePath != "" && dir != "" {
		params = append(params, " -ImagePath '"+imagePath+"'")
	} else if imagePath != "" {
		params = append(params, " -ImagePath '"+imagePath+"'")
	} else if dir != "" {
		params = append(params, " -ImageDir '"+dir+"'")
	} else {
		return "", nil, errors.New("no path to oci archive provided")
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	isDockerArchive, err := strconv.ParseBool(cmd.Flags().Lookup(dockerArchiveFlag).Value.String())
	if err != nil {
		return "", nil, err
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return "", nil, err
	}
	params = appendNodesParam(params, nodeSelector)

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if isWindowsImage {
		params = append(params, " -Windows")
	}

	if isDockerArchive {
		params = append(params, " -DockerArchive")
	}

	return
}
