//// SPDX-FileCopyrightText:  © 2024 The K2s Authors
//// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
)

type buildOptions struct {
	InputFolder string
	Dockerfile  string
	Windows     bool
	ImageName   string
	ImageTag    string
	Output      bool
	Push        bool
	BuildArgs   map[string]string
}

const (
	defaultInputFolder        = "."
	defaultDockerfile         = ""
	defaultWindowsFlag        = false
	defaultPushFlag           = false
	defaultImageNameToBeBuilt = ""
	defaultImageTagToBeBuilt  = ""

	inputFolderFlagName = "input-folder"
	dockerfileFlagName  = "dockerfile"
	windowsFlagName     = "windows"
	imageNameFlagName   = "image-name"
	imageTagFlagName    = "image-tag"
	pushFlagName        = "push"
	buildArgsFlagName   = "build-arg"

	inputFolderShortHand = "d"
	imageTagShortHand    = "t"
	imageNameShortHand   = "n"
	pushShortHand        = "p"
	dockerfileShortHand  = "f"
)

var (
	defaultBuildArgs = make([]string, 0)

	buildCommandShortDescription = "Build container images"

	buildCommandLongDescription = `
Build container images.

- Linux images are built inside the Linux VM (Control plane).
- Windows images are built on the host.
- For GO projects, the GOPRIVATE, GOPROXY, and GOSUMDB environment variables are used.
- Builds a Linux container image by default.

Registry Options:
- Supports pushing to local or remote registries.
- Enable local registry: 'k2s addons enable registry --default-credentials'.
- Add remote registry: 'k2s image registry add'.
- Specify the registry with '--image-name' (e.g., '--image-name k2s.registry.local/<myimage>').

`

	buildCommandExample = `
  # Build a linux container image using Dockerfile present in the current working directory
  k2s image build

  # Build a linux container image using a directory with the dockerfile
  k2s image build --input-folder C:\myFolder

  # Build a linux container image using a directory with the dockerfile with some build arguments
  k2s image build --input-folder C:\myFolder --build-arg="buildArg1=buildArgValue1" --build-arg="buildArg2=buildArgValue2"

  # Build a windows container image using Dockerfile present in the current working directory
  k2s image build --windows

  # Build a windows container image using a directory with the dockerfile
  k2s image build --input-folder C:\myFolder --windows

  # Build a linux container image using a directory with the dockerfile, image name and image tag
  k2s image build --input-folder C:\myFolder --image-name myimage --image-tag tag1

  # Build a linux container image using a directory with the dockerfile, image name, image tag and push to private registry
  k2s image build --input-folder C:\myFolder --image-name k2s.registry.local/<myimage> --image-tag tag1 --push
`

	buildCmd = &cobra.Command{
		Use:     "build",
		Short:   buildCommandShortDescription,
		Long:    buildCommandLongDescription,
		RunE:    buildImage,
		Example: buildCommandExample,
	}
)

func init() {
	addInitFlagsForBuildCommand(buildCmd)
}

func addInitFlagsForBuildCommand(cmd *cobra.Command) {
	cmd.Flags().StringP(inputFolderFlagName, inputFolderShortHand, defaultInputFolder, "Directory with the build context")
	cmd.Flags().StringP(dockerfileFlagName, dockerfileShortHand, defaultDockerfile, "Location of the dockerfile. ")
	cmd.Flags().BoolP(windowsFlagName, "w", defaultWindowsFlag, "Build a Windows container image")
	cmd.Flags().BoolP(pushFlagName, pushShortHand, defaultPushFlag, "Push to private registry (--image-name must be named accordingly! e.g k2s.registry.local/<myimage>, shsk2s.azurecr.io/<myimage>)")
	cmd.Flags().StringP(imageNameFlagName, imageNameShortHand, defaultImageNameToBeBuilt, "Name of the image")
	cmd.Flags().StringP(imageTagFlagName, imageTagShortHand, defaultImageNameToBeBuilt, "Tag of the image")
	cmd.Flags().StringSlice(buildArgsFlagName, defaultBuildArgs, "Build arguments needed to build the container image.")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func buildImage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Building container image..")
	buildOptions, err := extractBuildOptions(cmd)
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

	if runtimeConfig.InstallConfig().LinuxOnly() && buildOptions.Windows {
		return fmt.Errorf("building Windows container images is not supported on a Linux-only installation")
	}

	if err := context.Providers().Image.Build(provider.ImageBuildConfig{
		InputFolder: buildOptions.InputFolder,
		Dockerfile:  buildOptions.Dockerfile,
		ImageName:   buildOptions.ImageName,
		ImageTag:    buildOptions.ImageTag,
		Push:        buildOptions.Push,
		Windows:     buildOptions.Windows,
		BuildArgs:   buildOptions.BuildArgs,
		ShowOutput:  buildOptions.Output,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func extractBuildOptions(cmd *cobra.Command) (*buildOptions, error) {
	inputFolder, err := cmd.Flags().GetString(inputFolderFlagName)
	if err != nil {
		return nil, err
	}

	dockerfile, err := cmd.Flags().GetString(dockerfileFlagName)
	if err != nil {
		return nil, err
	}

	windows, err := strconv.ParseBool(cmd.Flags().Lookup(windowsFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	output, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	push, err := strconv.ParseBool(cmd.Flags().Lookup(pushFlagName).Value.String())
	if err != nil {
		return nil, err
	}

	imageName, err := cmd.Flags().GetString(imageNameFlagName)
	if err != nil {
		return nil, err
	}

	imageTag, err := cmd.Flags().GetString(imageTagFlagName)
	if err != nil {
		return nil, err
	}

	buildArguments, err := cmd.Flags().GetStringSlice(buildArgsFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag '%s': %w", buildArgsFlagName, err)
	}

	parsedBuildArguments, err := parseBuildArguments(buildArguments)
	if err != nil {
		return nil, fmt.Errorf("unable to parse build arguments: %w", err)
	}

	slog.Info("Build arguments", "args", parsedBuildArguments)

	return &buildOptions{
		InputFolder: inputFolder,
		Dockerfile:  dockerfile,
		Windows:     windows,
		ImageName:   imageName,
		ImageTag:    imageTag,
		Output:      output,
		Push:        push,
		BuildArgs:   parsedBuildArguments,
	}, nil
}

func parseBuildArguments(arguments []string) (map[string]string, error) {
	buildArgsMap := make(map[string]string, len(arguments))

	for _, argument := range arguments {
		name, value, ok := strings.Cut(argument, "=")
		if !ok {
			errMsg := "the build argument was not specified in correct format. The format of the build argument should be of format argumentName=argumentValue"
			return nil, errors.New(errMsg)
		}
		buildArgsMap[name] = value
	}
	return buildArgsMap, nil
}
