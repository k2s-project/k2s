// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

const (
	pullForWindowsFlag          = "windows"
	pullForWindowsFlagShorthand = "w"
	pullForWindowsDefault       = false
	pullForWindowsFlagDesc      = "Pull image on Windows node"
)

var (
	pullCommandExample = `
  # Pull a Linux image onto the Linux control-plane (default)
  k2s image pull nginx:latest

  # Pull a Linux image onto a specific Linux worker node
  k2s image pull nginx:latest --node worker-1

  # Pull a Linux image onto multiple specific Linux worker nodes
  k2s image pull nginx:latest --node worker-1,worker-2

  # Pull a Windows image onto the local Windows host (default)
  k2s image pull mcr.microsoft.com/windows:20H2 --windows
  k2s image pull mcr.microsoft.com/windows/nanoserver:ltsc2022 --windows
  OR
  k2s image pull mcr.microsoft.com/windows:20H2 -w

  # Pull a Windows image onto a specific Windows worker node
  k2s image pull mcr.microsoft.com/windows:20H2 -w --node winworker-1

  # Pull a Windows image onto multiple specific Windows worker nodes
  k2s image pull mcr.microsoft.com/windows:20H2 -w --node winworker-1,winworker-2
`
	pullCmd = &cobra.Command{
		Use:     "pull",
		Short:   "Pull an image onto a Kubernetes node",
		Example: pullCommandExample,
		RunE:    pullImage,
	}
)

func init() {
	pullCmd.Flags().BoolP(pullForWindowsFlag, pullForWindowsFlagShorthand, pullForWindowsDefault, pullForWindowsFlagDesc)
	addNodeSelectionFlags(pullCmd)
	pullCmd.Flags().SortFlags = false
	pullCmd.Flags().PrintDefaults()
}

func pullImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Pulling container image..")

	err := validatePullArgs(args)
	if err != nil {
		return fmt.Errorf("invalid arguments provided: %w", err)
	}

	imageToPull := getImageToPull(args)

	pullForWindows, err := strconv.ParseBool(cmd.Flags().Lookup(pullForWindowsFlag).Value.String())
	if err != nil {
		return err
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	psCmd, params := buildPullPsCmd(imageToPull, pullForWindows, showOutput, nodeSelector)

	slog.Debug("PS command created", "command", psCmd, "params", params)

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

	if runtimeConfig.InstallConfig().LinuxOnly() && pullForWindows {
		return fmt.Errorf("pulling Windows container images is not supported on a Linux-only installation")
	}

	if err := validateNodeSelector(nodeSelector, runtimeConfig); err != nil {
		return err
	}

	if err := context.Providers().Image.Pull(provider.ImagePullConfig{
		ImageName:  imageToPull,
		Windows:    pullForWindows,
		Nodes:      nodeSelector,
		ShowOutput: showOutput,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func validatePullArgs(args []string) error {
	if len(args) == 0 {
		return errors.New("no image to pull")
	}

	if len(args) > 1 {
		return errors.New("more than 1 image to pull. Can only pull 1 image at a time")
	}

	return nil
}

func getImageToPull(args []string) string {
	return args[0]
}

func buildPullPsCmd(imageToPull string, pullForWindows bool, showOutput bool, nodeSelector string) (psCmd string, params []string) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "image", "Pull-Image.ps1"))

	params = append(params, " -ImageName "+imageToPull)
	params = appendNodesParam(params, nodeSelector)

	if pullForWindows {
		params = append(params, " -Windows")
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	return
}
