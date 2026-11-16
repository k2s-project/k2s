// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package export

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/k2s-project/k2s/internal/providers/powershell"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	ac "github.com/k2s-project/k2s/cmd/k2s/cmd/addons/common"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cobra "github.com/spf13/cobra"
)

var exportCommandExample = `
  # Export individual addon to specified folder
  k2s addons export ingress nginx -d C:\tmp

  # Export multiple addons to specified folder
  k2s addons export registry ingress nginx -d C:\tmp

  # Export all addons to specified folder
  k2s addons export -d C:\tmp

  # Export addon without container images
  k2s addons export registry -d C:\tmp --omit-images

  # Export addon without packages
  k2s addons export registry -d C:\tmp --omit-packages

  # Export addon without container images and packages
  k2s addons export registry -d C:\tmp --omit-images --omit-packages
`

const (
	directoryLabel    = "directory"
	defaultDirectory  = ""
	errLinuxOnlyMsg   = "linux-only"
	omitImagesLabel   = "omit-images"
	omitPackagesLabel = "omit-packages"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "export ADDON",
		Short: "Export addon as OCI artifact",
		Long: `Export one or more addons as an OCI-compliant artifact containing configuration,
manifests, scripts, container images, and packages.

Use --omit-images to skip pulling and packaging container images (Linux and Windows),
producing a lighter artifact with only config, manifests, scripts, and packages layers.

Use --omit-packages to skip downloading and packaging debian, linux, and windows packages.

Both flags can be combined to export only configuration, manifests, and scripts.`,
		Example: exportCommandExample,
		RunE:    runExport,
	}

	cmd.Flags().StringP(directoryLabel, "d", defaultDirectory, "Directory for addon export")
	cmd.Flags().Bool(omitImagesLabel, false, "Omit container images from export")
	cmd.Flags().Bool(omitPackagesLabel, false, "Omit packages (debian, linux, windows) from export")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runExport(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	allAddons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

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

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}

func buildPsCmd(cmd *cobra.Command, addonsToExport ...string) (psCmd string, params []string, err error) {
	exportPath, err := cmd.Flags().GetString(directoryLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", directoryLabel)
	}
	if exportPath == "" {
		return "", nil, errors.New("no export path provided")
	}

	exportPath, err = filepath.Abs(exportPath)
	if err != nil {
		return "", nil, fmt.Errorf("unable to resolve absolute path for export directory: %w", err)
	}

	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "addons", "Export.ps1"))
	params = append(params, " -ExportDir "+utils.EscapeWithSingleQuotes(exportPath))

	if len(addonsToExport) > 0 {
		names := ""
		for _, addon := range addonsToExport {
			names += utils.EscapeWithSingleQuotes(addon) + ","
		}
		names = names[:len(names)-1]

		params = append(params, " -Names "+names)
	} else {
		params = append(params, " -All")
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	omitImages, err := cmd.Flags().GetBool(omitImagesLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", omitImagesLabel)
	}
	if omitImages {
		params = append(params, " -OmitImages")
	}

	omitPackages, err := cmd.Flags().GetBool(omitPackagesLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", omitPackagesLabel)
	}
	if omitPackages {
		params = append(params, " -OmitPackages")
	}

	return
}
