// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/k2s-project/k2s/internal/terminal"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	"github.com/k2s-project/k2s/internal/json"
)

type Spinner interface {
	Stop() error
}

type LoadedImages struct {
	common.CmdResult
	ContainerImages   []containerImage `json:"containerimages"`
	ContainerRegistry *string          `json:"containerregistry"`
	PushedImages      []pushedImage    `json:"pushedimages"`
}

type PrintImages struct {
	ContainerImages   []containerImage `json:"containerimages"`
	ContainerRegistry *string          `json:"containerregistry"`
	PushedImages      []pushedImage    `json:"pushedimages"`
	Error             *string          `json:"error"`
}

type containerImage struct {
	ImageId    string `json:"imageid"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Node       string `json:"node"`
	Size       string `json:"size"`
}

type pushedImage struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
	Node string `json:"node"`
}

const (
	includeK8sImages = "include-k8s-images"
	outputFlagName   = "output"
	jsonOption       = "json"

	cmdExample = `
  # List images from the default nodes (Linux control-plane and local Windows host)
  k2s image ls

  # List images including Kubernetes system images from the default nodes
  k2s image ls -A

  # List images in JSON output format
  k2s image ls -o json

  # List images in JSON output format from a specific worker node only
  k2s image ls --node worker-1 -o json

  # List images in JSON output format from multiple specific nodes only
  k2s image ls --nodes worker-1,worker-2 -o json

  # List images from a specific worker node only
  k2s image ls --node worker-1

  # List images from multiple specific nodes only
  k2s image ls --nodes worker-1,worker-2
`
)

var (
	containerImagesTableHeaders = []string{"ImageId", "Repository", "Tag", "Node", "Size"}
	pushedImagesTableHeaders    = []string{"Name", "Tag", "Node"}

	listCmd = &cobra.Command{
		Use:     "ls",
		Short:   "List images",
		RunE:    listImages,
		Example: cmdExample,
	}
)

func init() {
	listCmd.Flags().BoolP(includeK8sImages, "A", false, "Include kubernetes container images if specified")
	listCmd.Flags().String(nodeFlagName, "", "Node name to list images from (e.g. worker-1)")
	listCmd.Flags().String(nodesFlagName, "", "Comma-separated node names to list images from (e.g. worker-1,worker-2)")
	listCmd.Flags().StringP(common.OutputFlagName, common.OutputFlagShorthand, "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func listImages(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	if outputOption != "" && outputOption != jsonOption {
		return fmt.Errorf("parameter '%s' not supported for flag '%s'", outputOption, common.OutputFlagName)
	}

	includeK8sImages, err := strconv.ParseBool(cmd.Flags().Lookup(includeK8sImages).Value.String())
	if err != nil {
		return err
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return err
	}

	terminalPrinter := terminal.NewTerminalPrinter()

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	_, err = config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		return handleListImagesRuntimeConfigErr(err, outputOption, terminalPrinter.Println)
	}

	getImagesFunc := func() (*LoadedImages, error) {
		result, err := context.Providers().Image.List(provider.ImageListConfig{
			IncludeK8sImages: includeK8sImages,
			Nodes:            nodeSelector,
		})
		if err != nil {
			return nil, err
		}
		loaded := &LoadedImages{}
		if result.ContainerRegistry != "" {
			loaded.ContainerRegistry = new(result.ContainerRegistry)
		}
		for _, img := range result.ContainerImages {
			loaded.ContainerImages = append(loaded.ContainerImages, containerImage{
				ImageId:    img.ImageId,
				Repository: img.Repository,
				Tag:        img.Tag,
				Node:       img.Node,
				Size:       img.Size,
			})
		}
		for _, img := range result.PushedImages {
			loaded.PushedImages = append(loaded.PushedImages, pushedImage{
				Name: img.Name,
				Tag:  img.Tag,
				Node: img.Node,
			})
		}
		return loaded, nil
	}

	if outputOption == jsonOption {
		return printImagesAsJson(getImagesFunc, terminalPrinter.Println)
	}
	return printImagesToUser(getImagesFunc, terminalPrinter)
}

func handleListImagesRuntimeConfigErr(err error, outputOption string, printlnFunc func(m ...any)) error {
	if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
		if outputOption == jsonOption {
			return printSystemErrJson(printlnFunc, cconfig.ErrSystemInCorruptedState, common.CreateSystemInCorruptedStateCmdFailure)
		}
		return common.CreateSystemInCorruptedStateCmdFailure()
	}
	if errors.Is(err, cconfig.ErrSystemNotInstalled) {
		if outputOption == jsonOption {
			return printSystemErrJson(printlnFunc, cconfig.ErrSystemNotInstalled, common.CreateSystemNotInstalledCmdFailure)
		}
		return common.CreateSystemNotInstalledCmdFailure()
	}

	return err
}

func printImagesAsJson(getImagesFunc func() (*LoadedImages, error), printlnFunc func(m ...any)) error {
	loadedImages, err := getImagesFunc()
	if err != nil {
		return err
	}

	printImages := PrintImages{
		ContainerImages:   loadedImages.ContainerImages,
		ContainerRegistry: loadedImages.ContainerRegistry,
		PushedImages:      loadedImages.PushedImages,
	}

	var deferredErr error
	if loadedImages.Failure != nil {
		printImages.Error = new(loadedImages.Failure.Code)
		loadedImages.Failure.SuppressCliOutput = true
		deferredErr = loadedImages.Failure
	}

	bytes, err := json.MarshalIndent(printImages)
	if err != nil {
		return fmt.Errorf("error happened during list images: %w", errors.Join(deferredErr, err))
	}

	printlnFunc(string(bytes))

	return deferredErr
}

func printSystemErrJson(printlnFunc func(m ...any), systemError error, systemCmdFailureFunc func() *common.CmdFailure) error {
	printImages := PrintImages{
		Error: new(systemError.Error()),
	}

	bytes, err := json.MarshalIndent(printImages)
	if err != nil {
		return err
	}

	printlnFunc(string(bytes))

	failure := systemCmdFailureFunc()
	failure.SuppressCliOutput = true

	return failure
}

func printImagesToUser(getImagesFunc func() (*LoadedImages, error), printer terminal.TerminalPrinter) error {
	spinner, err := common.StartSpinner(printer)
	if err != nil {
		return err
	}

	images, err := getImagesFunc()

	common.StopSpinner(spinner)

	if err != nil {
		return err
	}

	if images.Failure != nil {
		return images.Failure
	}

	if len(images.ContainerImages) > 0 {
		printAvailableImages(printer, images.ContainerImages)
	} else {
		printer.PrintInfoln("No container images were found in the cluster")
	}

	if images.ContainerRegistry != nil && *images.ContainerRegistry != "" {
		if len(images.PushedImages) == 0 {
			printer.PrintInfoln("No pushed images in registry " + *images.ContainerRegistry)
		} else {
			printAvailableImagesInContainerRegistry(printer, *images.ContainerRegistry, images.PushedImages)
		}
	}

	return nil
}

func printAvailableImages(terminalPrinter terminal.TerminalPrinter, containerImages []containerImage) {
	terminalPrinter.PrintHeader("Available Images")

	containerImagesTable := [][]string{containerImagesTableHeaders}
	for _, containerImage := range containerImages {
		row := []string{containerImage.ImageId, containerImage.Repository, containerImage.Tag, containerImage.Node, containerImage.Size}
		containerImagesTable = append(containerImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(containerImagesTable)
}

func printAvailableImagesInContainerRegistry(terminalPrinter terminal.TerminalPrinter, containerRegistry string, pushedImages []pushedImage) {
	terminalPrinter.PrintHeader(fmt.Sprintf("Images available in registry: %s", containerRegistry))

	pushedImagesTable := [][]string{pushedImagesTableHeaders}
	for _, pushedImage := range pushedImages {
		row := []string{pushedImage.Name, pushedImage.Tag, pushedImage.Node}
		pushedImagesTable = append(pushedImagesTable, row)
	}
	terminalPrinter.PrintTableWithHeaders(pushedImagesTable)
}
