// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
)

type setupConfigProvider interface {
	ReadConfig(configDir string) (*cconfig.K2sRuntimeConfig, error)
}

type setupConfigProviderImpl struct{}

func (s *setupConfigProviderImpl) ReadConfig(configDir string) (*cconfig.K2sRuntimeConfig, error) {
	return config.ReadRuntimeConfig(configDir)
}

func newSetupConfigProvider() setupConfigProvider {
	return &setupConfigProviderImpl{}
}

const (
	containerdDirFlag     = "containerd"
	dockerDirFlag         = "docker"
	maxRetryFlag          = "max-retry"
	forceZapFlag          = "force-zap"
	forceZapFlagShorthand = "z"
	forceFlag             = "force"
	forceFlagShorthand    = "f"

	defaultMaxRetry = 1

	resetWinStorageCommandExample = `
  # Clean up containerd storage. This presents a user prompt before proceeding.
  k2s image reset-win-storage --containerd C:\containerd

  # Clean up docker storage. This presents a user prompt before proceeding.
  k2s image reset-win-storage --docker C:\docker

  # Clean up containerd storage without user prompts.
  k2s image reset-win-storage --containerd C:\containerd --force

  # Clean up both containerd and docker storages
  k2s image reset-win-storag --containerd C:\containerd --docker C:\docker

  # Clean up containerd storage with retries
  k2s image reset-win-storage --containerd C:\containerd --max-retry 5

  # Clean up containerd storage with additional zap.exe after all retries are exhausted.
  k2s image reset-win-storage --containerd C:\containerd --max-retry 5 --force-zap
`
)

var (
	// defaultContainerdDir and defaultDockerDir are intentionally empty: an empty value
	// signals the platform provider to resolve the configured/default storage path.
	defaultContainerdDir = ""
	defaultDockerDir     = ""

	resetWinStorageCmd = &cobra.Command{
		Use:     "reset-win-storage",
		Short:   "Resets the containerd and docker image storage on windows nodes",
		RunE:    resetWinStorage,
		Example: resetWinStorageCommandExample,
	}

	getSetupConfigProvider func() setupConfigProvider
)

func init() {
	resetWinStorageCmd.Flags().String(containerdDirFlag, defaultContainerdDir, "Containerd directory")
	resetWinStorageCmd.Flags().String(dockerDirFlag, defaultDockerDir, "Docker directory")
	resetWinStorageCmd.Flags().Int(maxRetryFlag, defaultMaxRetry, "Max retries for deleting the directories")
	resetWinStorageCmd.Flags().BoolP(forceZapFlag, "z", false, "Use zap.exe to forcefully remove the directory after all retries are exhausted.")
	resetWinStorageCmd.Flags().BoolP(forceFlag, forceFlagShorthand, false, "Trigger clean-up of windows container storage without user prompts")
	resetWinStorageCmd.Flags().SortFlags = false
	resetWinStorageCmd.Flags().PrintDefaults()

	getSetupConfigProvider = newSetupConfigProvider
}

func resetWinStorage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	cfg, err := buildResetWinStorageConfig(cmd)
	if err != nil {
		return err
	}

	setupConfigProvider := getSetupConfigProvider()
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := setupConfigProvider.ReadConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if !(errors.Is(err, cconfig.ErrSystemNotInstalled) || errors.Is(err, cconfig.ErrSystemInCorruptedState)) {
			return err
		}
	} else if runtimeConfig.InstallConfig().LinuxOnly() {
		return errors.New("Resetting WinContainerStorage for Linux-only setup is not supported.")
	}

	if err := context.Providers().Image.ResetWinStorage(cmd.Context(), cfg); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

func buildResetWinStorageConfig(cmd *cobra.Command) (provider.ImageResetWinStorageConfig, error) {
	force, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlag).Value.String())
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", forceFlag, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	containerdDir, err := cmd.Flags().GetString(containerdDirFlag)
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", containerdDirFlag, err)
	}

	if containerdDir == "" {
		slog.Info("No containerd directory provided; provider will resolve the configured storage path")
	}

	dockerDir, err := cmd.Flags().GetString(dockerDirFlag)
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", dockerDirFlag, err)
	}

	if dockerDir == "" {
		slog.Info("No docker directory provided; provider will resolve the default storage path")
	}

	maxRetries, err := cmd.Flags().GetInt(maxRetryFlag)
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", maxRetryFlag, err)
	}

	if maxRetries <= 0 {
		return provider.ImageResetWinStorageConfig{}, errors.New("illegal value for Max retries. Value of Max retries should be greater than or equal to 1")
	}

	useZap, err := strconv.ParseBool(cmd.Flags().Lookup(forceZapFlag).Value.String())
	if err != nil {
		return provider.ImageResetWinStorageConfig{}, fmt.Errorf("unable to parse flag '%s': %w", forceZapFlag, err)
	}

	return provider.ImageResetWinStorageConfig{
		Containerd: containerdDir,
		Docker:     dockerDir,
		MaxRetry:   maxRetries,
		ForceZap:   useZap,
		Force:      force,
		ShowOutput: showOutput,
	}, nil
}
