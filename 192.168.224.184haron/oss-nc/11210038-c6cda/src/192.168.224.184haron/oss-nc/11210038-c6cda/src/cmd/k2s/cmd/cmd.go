// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package cmd

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/addons"
	cc "github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	im "github.com/k2s-project/k2s/cmd/k2s/cmd/image"
	in "github.com/k2s-project/k2s/cmd/k2s/cmd/install"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/start"
	stat "github.com/k2s-project/k2s/cmd/k2s/cmd/status"
	stop "github.com/k2s-project/k2s/cmd/k2s/cmd/stop"
	sys "github.com/k2s-project/k2s/cmd/k2s/cmd/system"
	un "github.com/k2s-project/k2s/cmd/k2s/cmd/uninstall"
	ve "github.com/k2s-project/k2s/cmd/k2s/cmd/version"
	"github.com/k2s-project/k2s/cmd/k2s/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	"github.com/k2s-project/k2s/internal/cli"
	cConfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/host"
	bl "github.com/k2s-project/k2s/internal/logging"
	"github.com/k2s-project/k2s/internal/provider"

	"github.com/spf13/cobra"
)

func CreateRootCmd(logger *logging.Slogger) (*cobra.Command, error) {
	verbosity := bl.LevelToLowerString(slog.LevelInfo)
	showLog := false

	cmd := &cobra.Command{
		Use:               common.CliName,
		Short:             "k2s – command-line tool to interact with the K2s cluster",
		SilenceErrors:     true,
		SilenceUsage:      true,
		CompletionOptions: cobra.CompletionOptions{DisableDefaultCmd: true},
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if err := logger.SetVerbosity(verbosity); err != nil {
				return err
			}

			fileHandler := logging.NewFileHandler(bl.GlobalLogFilePath())

			// Initialize file logging before configuration and provider setup.
			logger.SetHandlers(fileHandler).SetGlobally()
			slog.Info("<*********************************>")
			slog.Info("CLI invocation", "cmd", formatCLIInvocation(os.Args))
			slog.Debug("log level set", "level", verbosity)

			// Set up full handler chain including CLI handler if requested
			if showLog {
				logger.SetHandlers(fileHandler, logging.NewCliHandler()).SetGlobally()
			}

			// TODO: always load setup config and determine PS version?

			configDir := utils.InstallDir()
			k2sConfig, err := config.ReadK2sConfig(configDir)
			if err != nil {
				// Config not found at executable directory — check if running from a delta
				// package directory and resolve the actual install dir from setup.json
				actualDir, resolveErr := resolveInstallDirForDelta(configDir)
				if resolveErr == nil && actualDir != configDir {
					slog.Info("Config not found at exe dir, using actual install dir", "exe-dir", configDir, "install-dir", actualDir)
					k2sConfig, err = config.ReadK2sConfig(actualDir)
				}
			}
			if err != nil {
				return err
			}

			slog.Debug("config loaded", "config", k2sConfig)

			registry := provider.NewRegistry(provider.ProviderConfig{
				InstallDir: utils.InstallDir(),
				ConfigDir:  k2sConfig.Host().K2sSetupConfigDir(),
				StdWriter:  cc.NewPtermWriter(),
			})

			cmd.SetContext(context.WithValue(cmd.Context(), cc.ContextKeyCmdContext, cc.NewCmdContext(k2sConfig, logger, registry)))

			return nil
		},
	}

	addonsCmd, err := addons.NewCmd()
	if err != nil {
		return nil, err
	}

	cmd.AddCommand(start.StartK8sCmd)
	cmd.AddCommand(stop.StopK8sCmd)
	cmd.AddCommand(in.InstallCmd)
	cmd.AddCommand(un.UninstallK8sCmd)
	cmd.AddCommand(im.ImageCmd)
	cmd.AddCommand(stat.StatusCmd)
	cmd.AddCommand(addonsCmd)
	cmd.AddCommand(ve.VersionCmd)
	cmd.AddCommand(sys.SystemCmd)
	cmd.AddCommand(node.NewCmd())

	persistentFlags := cmd.PersistentFlags()
	persistentFlags.BoolVarP(&showLog, cc.OutputFlagName, cc.OutputFlagShorthand, showLog, cc.OutputFlagUsage)
	persistentFlags.StringVarP(&verbosity, cli.VerbosityFlagName, cli.VerbosityFlagShorthand, verbosity, cli.VerbosityFlagHelp())

	return cmd, nil
}

func formatCLIInvocation(args []string) string {
	if runtime.GOOS != "linux" {
		return strings.Join(args, " ")
	}
	return formatLinuxCLIInvocation(args)
}

func formatLinuxCLIInvocation(args []string) string {
	quotedArgs := make([]string, 0, len(args))
	for _, arg := range args {
		if arg != "" && !strings.ContainsAny(arg, " \t\n\r'\"\\$`;&|<>()[]{}*?!") {
			quotedArgs = append(quotedArgs, arg)
			continue
		}
		quotedArgs = append(quotedArgs, "'"+strings.ReplaceAll(arg, "'", "'\"'\"'")+"'")
	}
	return strings.Join(quotedArgs, " ")
}

// resolveInstallDirForDelta checks if the executable is running from a delta package
// directory (indicated by delta-manifest.json) and resolves the actual K2s install
// directory from setup.json at the well-known system location. If the setup.json is
// not present there (e.g. because the installed K2s uses a customized 'configDir.k2s'),
// the installed K2s is discovered via PATH as fallback.
func resolveInstallDirForDelta(exeDir string) (string, error) {
	deltaManifest := filepath.Join(exeDir, "delta-manifest.json")
	if _, err := os.Stat(deltaManifest); err != nil {
		return exeDir, err
	}

	slog.Info("Delta package detected, resolving actual install directory")

	// Read install folder from setup.json at the well-known ProgramData location,
	// consistent with Start-ClusterUpdate.ps1 behavior.
	// Note: must use host.SystemDrive() (returns "C:\") instead of os.Getenv("SystemDrive")
	// (returns "C:") because Go's filepath.Join does not add a separator after a bare
	// drive letter — see https://github.com/golang/go/issues/26953
	setupConfigDir := filepath.Join(host.SystemDrive(), "ProgramData", "k2s")

	installFolder, err := config.ReadInstallFolder(setupConfigDir)
	if err != nil {
		slog.Warn("Could not read setup.json", "dir", setupConfigDir, "error", err)

		return resolveInstallDirFromPath(exeDir, err)
	}

	if installFolder == "" {
		slog.Warn("InstallFolder not set in setup.json")
		return exeDir, nil
	}

	slog.Info("Resolved actual install directory from setup.json", "install-dir", installFolder)
	return installFolder, nil
}

// resolveInstalledK2s wraps config.ResolveInstalledK2s so that the PATH-based
// discovery can be substituted in unit tests.
var resolveInstalledK2s = config.ResolveInstalledK2s

// resolveInstallDirFromPath discovers the installed K2s via the PATH environment
// variable. It preserves the original error/behavior if no installation was found.
//
// NOTE: config.ResolveInstalledK2s may return a valid installation together with
// ErrSystemInCorruptedState. A corrupted installation is still an existing installation,
// therefore its install dir must be used (consistent with the upgrade cmd).
func resolveInstallDirFromPath(exeDir string, originalErr error) (string, error) {
	installed, resolveErr := resolveInstalledK2s()
	if resolveErr != nil && !errors.Is(resolveErr, cConfig.ErrSystemInCorruptedState) {
		slog.Warn("Could not discover installed K2s via PATH", "error", resolveErr)
		return exeDir, originalErr
	}
	if installed == nil {
		slog.Warn("No installed K2s discovered via PATH")
		return exeDir, originalErr
	}

	slog.Info("Resolved actual install directory via PATH", "install-dir", installed.InstallDir)
	return installed.InstallDir, nil
}
