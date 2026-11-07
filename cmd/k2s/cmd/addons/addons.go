// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package addons

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/backup"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/export"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/generic"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/importcmd"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/list"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/restore"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons/status"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/internal/core/addonplacement"
	"github.com/k2s-project/k2s/internal/core/addons"

	"github.com/spf13/cobra"
)

func NewCmd() (*cobra.Command, error) {
	var cmd = &cobra.Command{
		Use:   "addons",
		Short: "Manage addons",
		Long:  "Addons add optional functionality to a K8s cluster",
	}

	cmd.AddCommand(importcmd.NewCommand())
	cmd.AddCommand(export.NewCommand())
	cmd.AddCommand(backup.NewCommand())
	cmd.AddCommand(restore.NewCommand())
	cmd.AddCommand(newPlacementRenderCommand())

	if !slices.Contains(os.Args, cmd.Use) {
		return cmd, nil
	}

	addons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return nil, err
	}

	// Note: generic commands are generated from addon manifests.
	cmd.AddCommand(list.NewCommand(addons))
	cmd.AddCommand(status.NewCommand(addons))

	commands, err := generic.NewCommands(addons)
	if err != nil {
		return nil, err
	}

	cmd.AddCommand(commands...)

	return cmd, nil
}

func newPlacementRenderCommand() *cobra.Command {
	var addonName, manifestsDir, inputPath, selector, outputPath string
	var helmPath string
	var storageNode string
	var existingVolume, storageHost string
	var selectorsOnly bool
	cmd := &cobra.Command{
		Use:    "__render-placement-manifests",
		Hidden: true,
		Args:   cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			if existingVolume != "" || storageHost != "" {
				volume, err := os.ReadFile(existingVolume)
				if err != nil {
					return err
				}
				node, err := os.ReadFile(storageHost)
				if err != nil {
					return err
				}
				return addonplacement.ValidatePersistentVolumeHost(volume, node)
			}
			if !addonplacement.SupportsAddon(addonName) {
				if !slices.Contains([]string{"certmanager", "externaldns"}, addonName) {
					return fmt.Errorf("addon '%s' does not support infrastructure placement", addonName)
				}
			}
			if (manifestsDir == "" && inputPath == "") || selector == "" || outputPath == "" {
				return fmt.Errorf("manifest input, selector, and output path are required")
			}
			var rendered []byte
			var err error
			switch addonName {
			case "dashboard":
				if inputPath == "" || manifestsDir != "" {
					return fmt.Errorf("addon '%s' requires its owning rendered input file", addonName)
				}
				input, readErr := os.ReadFile(inputPath)
				if readErr != nil {
					return readErr
				}
				rendered, err = addonplacement.RenderHelmValues(input, selector)
			default:
				if inputPath != "" {
					if manifestsDir != "" {
						return fmt.Errorf("choose either a manifest directory or an owning input file")
					}
					input, readErr := os.ReadFile(inputPath)
					if readErr != nil {
						return readErr
					}
					rendered, _, err = addonplacement.RenderStorageManifestStream(input, selector, storageNode)
				} else {
					rendered, _, err = addonplacement.RenderManifestDirectory(manifestsDir, selector)
				}
			}
			if err != nil {
				return err
			}
			if selectorsOnly {
				if addonName == "dashboard" {
					chart, err := addonplacement.FindHeadlampChart(filepath.Dir(inputPath))
					if err != nil {
						return err
					}
					rendered, err = addonplacement.TemplateHeadlampChart(helmPath, chart, rendered)
					if err != nil {
						return err
					}
				}
				selectors, err := addonplacement.WorkloadSelectors(rendered)
				if err != nil {
					return err
				}
				rendered, err = json.Marshal(selectors)
				if err != nil {
					return err
				}
			}
			return os.WriteFile(outputPath, rendered, 0o600)
		},
	}
	cmd.Flags().StringVar(&addonName, "addon-name", "", "")
	cmd.Flags().StringVar(&manifestsDir, "manifest-directory", "", "")
	cmd.Flags().StringVar(&inputPath, "input-file", "", "")
	cmd.Flags().StringVar(&selector, "selector", "", "")
	cmd.Flags().StringVar(&outputPath, "output", "", "")
	cmd.Flags().BoolVar(&selectorsOnly, "selectors-only", false, "")
	cmd.Flags().StringVar(&helmPath, "helm-path", "helm", "")
	cmd.Flags().StringVar(&storageNode, "storage-node", "", "")
	cmd.Flags().StringVar(&existingVolume, "existing-volume", "", "")
	cmd.Flags().StringVar(&storageHost, "storage-host", "", "")
	return cmd
}
