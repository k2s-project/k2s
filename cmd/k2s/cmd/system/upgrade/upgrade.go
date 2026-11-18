// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package upgrade

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	installconfig "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/k2s-project/k2s/cmd/k2s/utils/logging"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/effectiveconfig"
	bl "github.com/k2s-project/k2s/internal/logging"
	kos "github.com/k2s-project/k2s/internal/os"

	"github.com/k2s-project/k2s/cmd/k2s/utils"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/provider"
)

var upgradeCommandShortDescription = "Upgrades the installed K2s cluster to this version (full upgrade, in-place delta update, or worker node upgrade)"

var upgradeCommandLongDescription = `
Upgrades the installed K2s cluster to this version.

⚠  This command automatically detects whether to perform:
   - FULL UPGRADE: if executed from a full K2s package directory (no delta-manifest.json)
   - DELTA UPDATE: if executed from an extracted delta package directory (delta-manifest.json present)

FULL UPGRADE:
  ⚠  Call this command within the folder containing the new K2s version, e.g. '<new-version-dir>\k2s.exe system upgrade'
  
  The following tasks will be executed:
  1. Export of current workloads (global resources and all namespaced resources)
  2. Uninstall existing cluster
  3. Install a new cluster based on this version
  4. Import previously exported workloads
  5. Re-enable previously enabled addons
  6. Check if all workloads are running
  7. Finally check K2s cluster availability

  ⚠  NOTE: Addon data/persistence is NOT automatically restored during upgrade.
     To backup and restore addon data, use the separate mechanisms:
     - k2s addons export / k2s addons import

DELTA UPDATE:
  ⚠  Extract the delta package and call this command from within the extracted directory:
     1. Extract: Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
     2. Navigate: cd .\delta
     3. Update: .\k2s.exe system upgrade
  
  The following tasks will be executed:
  1. Detect delta package root (current directory with delta-manifest.json)
  2. Detect target installation folder (from setup.json)
  3. Update all Windows executables and scripts from delta to target installation
  4. Update all Debian packages from delta (if cluster is running)
  5. Update all container images from delta
  6. Automatically stop and restart the cluster if it was running

NODE UPGRADE:
  Upgrades a single Linux worker node without touching the control plane.
  Both full node packages and node delta packages are supported.
  The upgrade mode is auto-detected from the ZIP contents:
    - ZIP contains delta-manifest.json with DeltaType=node-package → DELTA mode
      (installs only changed/added packages; purges removed Debian packages)
    - No delta-manifest.json present → FULL mode
      (installs all packages present in the ZIP)

  Required flags: --node <node-name> --path <node-package.zip>
  Both flags must always be specified together.
`

var upgradeCommandExample = `
  # Full upgrade: Upgrades the cluster to this version
  k2s system upgrade

  # Full upgrade: Skips takeover of existing cluster resources
  k2s system upgrade -s

  # Full upgrade: Deleting downloaded files after upgrade
  k2s system upgrade -d
  
  # Delta update: From extracted delta package
  Expand-Archive k2s-delta-v1.5.0-to-v1.6.0.zip -Destination .\delta
  cd .\delta
  .\k2s.exe system upgrade

  # Node upgrade: Apply a full node package to a worker node
  k2s system upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-v1.8.0.zip" -o

  # Node upgrade: Apply a node delta package to a worker node (mode auto-detected)
  k2s system upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-delta-v1.7.0-to-v1.8.0.zip" -o
`

const (
	configFileFlagName = "config"
	skipK8sResources   = "skip-resources"
	deleteFiles        = "delete-files"
	proxy              = "proxy"
	defaultProxy       = ""
	skipImagesFlag     = "skip-images"
	backupDir          = "backup-dir"
	force              = "force"
	defaultBackupDir   = ""
	nodeNameFlag       = "node"
	nodePackageFlag    = "path"
)

var UpgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   upgradeCommandShortDescription,
	Long:    upgradeCommandLongDescription,
	RunE:    upgradeCluster,
	Example: upgradeCommandExample,
}

func init() {
	AddInitFlags(UpgradeCmd)
}

func AddInitFlags(cmd *cobra.Command) {
	cmd.Flags().BoolP(skipK8sResources, "s", false, "Skip takeover of K8s resources from old cluster to new cluster")
	cmd.Flags().BoolP(deleteFiles, "d", false, "Delete downloaded files")
	cmd.Flags().StringP(configFileFlagName, "c", "", "Path to config file to load. This configuration overwrites other CLI parameters")
	cmd.Flags().StringP(proxy, "p", defaultProxy, "HTTP Proxy")
	cmd.Flags().StringP(backupDir, "b", defaultBackupDir, "Backup directory")
	cmd.Flags().BoolP(skipImagesFlag, "i", false, "Skip takeover of container images from old cluster to new cluster")
	cmd.Flags().BoolP(force, "f", false, "Forces the upgrade, even if the previous and current versions are not consecutive")
	cmd.Flags().String(common.AdditionalHooksDirFlagName, "", common.AdditionalHooksDirFlagUsage)
	cmd.Flags().StringP(nodeNameFlag, "n", "", "Name of the worker node to upgrade (requires --path)")
	cmd.Flags().String(nodePackageFlag, "", "Path to node package zip for offline node upgrade (requires --node)")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func upgradeCluster(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🤖 Analyze current cluster and check prerequisites ...")

	showLog, err := cmd.Flags().GetBool(common.OutputFlagName)
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	runtimeConfig, resolvedConfigDir, err := readConfigLegacyAware(context.Config())
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

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return err
	}

	skip, _ := cmd.Flags().GetBool(skipK8sResources)
	delete, _ := cmd.Flags().GetBool(deleteFiles)
	configFile := cmd.Flags().Lookup(configFileFlagName).Value.String()
	proxyVal := cmd.Flags().Lookup(proxy).Value.String()
	skipImages, _ := cmd.Flags().GetBool(skipImagesFlag)
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	backupDirVal := cmd.Flags().Lookup(backupDir).Value.String()
	forceVal, _ := cmd.Flags().GetBool(force)
	nodeNameVal, _ := cmd.Flags().GetString(nodeNameFlag)
	nodePackageVal, _ := cmd.Flags().GetString(nodePackageFlag)

	if (nodeNameVal == "") != (nodePackageVal == "") {
		return errors.New("--node and --path must be specified together")
	}

	if err := installconfig.ValidateProxy(proxyVal); err != nil {
		return err
	}

	cleanupUpgradeConfig := func() error { return nil }
	if nodeNameVal == "" {
		configFile, cleanupUpgradeConfig, err = prepareUpgradeInstallConfig(configFile, resolvedConfigDir)
		if err != nil {
			return fmt.Errorf("failed to prepare install configuration: %w", err)
		}
		defer func() {
			if cleanupErr := cleanupUpgradeConfig(); cleanupErr != nil {
				slog.Warn("Failed to clean staged install configuration", "error", cleanupErr)
			}
		}()
	}

	switchToUpgradeLogFile(showLog, context.Logger())

	if err := applySetupConfigDirOverride(resolvedConfigDir, context.Config().Host().K2sSetupConfigDir()); err != nil {
		switchToDefaultLogFile(showLog, context.Logger())
		return err
	}

	psErr := context.Providers().System.Upgrade(provider.SystemUpgradeConfig{
		SkipResources:      skip,
		SkipImages:         skipImages,
		DeletePackage:      delete,
		ConfigFile:         configFile,
		Proxy:              proxyVal,
		BackupDir:          backupDirVal,
		AdditionalHooksDir: additionalHooksDir,
		Force:              forceVal,
		NodeName:           nodeNameVal,
		NodePackagePath:    nodePackageVal,
		ShowOutput:         showLog,
	})

	switchToDefaultLogFile(showLog, context.Logger())

	if psErr != nil {
		return psErr
	}

	cmdSession.Finish()

	return nil
}

func prepareUpgradeInstallConfig(requestedPath string, setupConfigDir string) (string, func() error, error) {
	configPath := requestedPath
	linkedConfig := configPath == ""
	if linkedConfig {
		setupPath := filepath.Join(setupConfigDir, definitions.K2sRuntimeConfigFileName)
		content, err := os.ReadFile(setupPath)
		if err != nil {
			return "", nil, fmt.Errorf("failed to read installed setup configuration: %w", err)
		}
		var setup map[string]any
		if err := json.Unmarshal(content, &setup); err != nil {
			return "", nil, fmt.Errorf("failed to parse installed setup configuration: %w", err)
		}
		linkedPath, _ := setup[definitions.EffectiveInstallConfigPathKey].(string)
		if linkedPath == "" {
			return "", func() error { return nil }, nil
		}
		configPath = linkedPath
	}

	config, err := installconfig.LoadFile(configPath)
	if err != nil {
		if linkedConfig && errors.Is(err, os.ErrNotExist) {
			return "", func() error { return nil }, nil
		}
		return "", nil, err
	}
	content, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return "", nil, fmt.Errorf("failed to serialize replacement install configuration: %w", err)
	}

	stagingDir, err := os.MkdirTemp("", "k2s-upgrade-config-")
	if err != nil {
		return "", nil, fmt.Errorf("failed to create replacement install configuration staging directory: %w", err)
	}
	snapshot, err := effectiveconfig.Stage(stagingDir, content)
	if err != nil {
		_ = os.RemoveAll(stagingDir)
		return "", nil, err
	}

	cleanup := func() error {
		return errors.Join(snapshot.Abort(), os.RemoveAll(stagingDir))
	}
	return snapshot.Path(), cleanup, nil
}

func readConfigLegacyAware(k2sConfig *cconfig.K2sConfig) (*cconfig.K2sRuntimeConfig, string, error) {
	slog.Info("Trying to read the config file", "config-dir", k2sConfig.Host().K2sSetupConfigDir())

	setupConfigDir := k2sConfig.Host().K2sSetupConfigDir()

	runtimeConfig, err := config.ReadRuntimeConfig(setupConfigDir)
	if err != nil {
		if !errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return nil, "", err
		}

		slog.Info("Config file not found, trying to read the config file from legacy dir", "legacy-dir", k2sConfig.Host().KubeConfig().CurrentDir())

		runtimeConfig, err = config.ReadRuntimeConfig(k2sConfig.Host().KubeConfig().CurrentDir())
		if err != nil {
			if !errors.Is(err, cconfig.ErrSystemNotInstalled) {
				return nil, "", err
			}

			// The currently running package may be configured with a different
			// 'configDir.k2s' than the installed K2s (e.g. an upgrade package with
			// default config vs. an installation with a customized config dir).
			// Therefore discover the installed K2s via PATH as last resort.
			// NOTE: no config file is copied here on purpose - the installed setup
			// config must stay at its original location.
			return readInstalledConfigFromPath()
		}

		if err := copyLegacyConfigFile(k2sConfig.Host().KubeConfig().CurrentDir(), setupConfigDir); err != nil {
			return nil, "", err
		}
	}

	slog.Info("Config file read")

	return runtimeConfig, setupConfigDir, nil
}

// resolveInstalledK2s indirects config.ResolveInstalledK2s so that the PATH-based
// discovery can be substituted in unit tests (same pattern as in cmd.go).
var resolveInstalledK2s = config.ResolveInstalledK2s

func readInstalledConfigFromPath() (*cconfig.K2sRuntimeConfig, string, error) {
	slog.Info("Setup config file not found in legacy dir, trying to discover the installed K2s via PATH")

	installed, err := resolveInstalledK2s()
	if err != nil && !errors.Is(err, cconfig.ErrSystemInCorruptedState) {
		// e.g. ErrSystemNotInstalled or multiple installations found in PATH
		return nil, "", err
	}
	if installed == nil {
		// Preserve an existing error (e.g. corrupted state) instead of masking it.
		if err != nil {
			return nil, "", err
		}
		return nil, "", cconfig.ErrSystemNotInstalled
	}

	installedConfigDir := installed.Config.Host().K2sSetupConfigDir()

	slog.Info("Installed K2s discovered via PATH", "install-dir", installed.InstallDir, "config-dir", installedConfigDir)

	// <err> is either nil or ErrSystemInCorruptedState; returning it preserves the
	// corrupted-state semantics of config.ReadRuntimeConfig.
	return installed.RuntimeConfig, installedConfigDir, err
}

// applySetupConfigDirOverride makes the setup config dir of the installed K2s known to the
// child processes (i.e. the PowerShell upgrade scripts) via an environment variable.
//
// This is only necessary if the installed K2s uses a different 'configDir.k2s' than the
// currently running package. The override exists solely to discover, analyze and uninstall
// the OLD installation.
//
// IMPORTANT: The override must NOT reach the installation of the new version. The new
// version is installed with the configuration of its own package, therefore the upgrade
// scripts clear the override again before the new 'k2s install' is started
// (see 'Invoke-ClusterInstall' in upgrade.module.psm1). The config file of the new package
// is never modified.
func applySetupConfigDirOverride(resolvedConfigDir string, packageConfigDir string) error {
	// Windows paths are case-insensitive, therefore dirs that differ only in casing (or in
	// trailing separators) denote the same setup config dir and must not trigger an override.
	if resolvedConfigDir == "" || kos.SamePath(resolvedConfigDir, packageConfigDir) {
		slog.Debug("Setup config dir of installed K2s equals the current package's config dir, no override needed", "config-dir", packageConfigDir)
		return nil
	}

	slog.Info("Overriding setup config dir for the old cluster analysis/uninstall",
		"env-var", definitions.SetupConfigDirEnvVar, "config-dir", resolvedConfigDir, "package-config-dir", packageConfigDir)

	if err := os.Setenv(definitions.SetupConfigDirEnvVar, resolvedConfigDir); err != nil {
		return fmt.Errorf("could not set setup config dir override '%s': %w", definitions.SetupConfigDirEnvVar, err)
	}
	return nil
}

func copyLegacyConfigFile(legacyDir string, targetDir string) error {
	slog.Info("Copying config file from legacy dir to target dir", "legacy-dir", legacyDir, "target-dir", targetDir)

	if err := os.MkdirAll(targetDir, fs.ModePerm); err != nil {
		return err
	}

	source := filepath.Join(legacyDir, definitions.K2sRuntimeConfigFileName)
	target := filepath.Join(targetDir, definitions.K2sRuntimeConfigFileName)

	return kos.CopyFile(source, target)
}

func createUpgradeCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "upgrade", "Start-ClusterUpgrade.ps1"))
	out, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if out {
		psCmd += " -ShowLogs"
	}
	skip, _ := strconv.ParseBool(cmd.Flags().Lookup(skipK8sResources).Value.String())
	if skip {
		psCmd += " -SkipResources "
	}
	delete, _ := strconv.ParseBool(cmd.Flags().Lookup(deleteFiles).Value.String())
	if delete {
		psCmd += " -DeleteFiles "
	}
	config := cmd.Flags().Lookup(configFileFlagName).Value.String()
	if len(config) > 0 {
		psCmd += " -Config " + utils.EscapeWithSingleQuotes(config)
	}
	proxy := cmd.Flags().Lookup(proxy).Value.String()
	if len(proxy) > 0 {
		psCmd += " -Proxy " + utils.EscapeWithSingleQuotes(proxy)
	}
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImagesFlag).Value.String())
	if skipImages {
		psCmd += " -SkipImages"
	}
	additionalHooksDir := cmd.Flags().Lookup(common.AdditionalHooksDirFlagName).Value.String()
	if additionalHooksDir != "" {
		psCmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(additionalHooksDir)
	}
	backupDir := cmd.Flags().Lookup(backupDir).Value.String()
	if backupDir != "" {
		psCmd += " -BackupDir " + utils.EscapeWithSingleQuotes(backupDir)
	}
	force, _ := strconv.ParseBool(cmd.Flags().Lookup(force).Value.String())
	if force {
		psCmd += " -Force"
	}
	return psCmd
}

func switchToUpgradeLogFile(showLog bool, logger *logging.Slogger) {
	upgradeLogFilePath := bl.GlobalLogFilePath() + "_cli_upgrade_" + time.Now().Format("2006-01-02_15-04-05")

	slog.Debug("Switching temporary to CLI log file", "path", upgradeLogFilePath)

	setLogger(showLog, logger, upgradeLogFilePath)
}

func switchToDefaultLogFile(showLog bool, logger *logging.Slogger) {
	globalLogFilePath := bl.GlobalLogFilePath()

	slog.Debug("Switching back to default log file", "path", globalLogFilePath)

	setLogger(showLog, logger, globalLogFilePath)
}

func setLogger(showLog bool, logger *logging.Slogger, path string) {
	logHandlers := []logging.HandlerBuilder{logging.NewFileHandler(path)}
	if showLog {
		logHandlers = append(logHandlers, logging.NewCliHandler())
	}
	logger.SetHandlers(logHandlers...).SetGlobally()
}
