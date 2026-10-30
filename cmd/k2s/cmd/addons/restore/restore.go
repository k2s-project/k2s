// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package restore

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	ac "github.com/k2s-project/k2s/cmd/k2s/cmd/addons/common"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/addonplacement"
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
	k2sos "github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/providers/powershell"
	"github.com/spf13/cobra"
)

const (
	fileFlagName      = "file"
	fileFlagShorthand = "f"
)

type backupManifest struct {
	K2sVersion        string   `json:"k2sVersion"`
	Files             []string `json:"files"`
	Addon             string   `json:"addon"`
	Implementation    string   `json:"implementation,omitempty"`
	InfraNodeSelector string   `json:"infraNodeSelector,omitempty"`
}

var restoreExample = `
  # Restore addon "registry" from a backup zip
    k2s addons restore registry -f registry-backup.zip

  # Restore addon "ingress nginx" from a backup zip
    k2s addons restore "ingress nginx" -f ingress-nginx-backup.zip

  # Restore newest backup for "ingress traefik" from default backup folder
    k2s addons restore "ingress traefik"
`

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "restore ADDON [IMPLEMENTATION]",
		Short:   "Restore addon data",
		Example: restoreExample,
		Args:    cobra.RangeArgs(1, 2),
		RunE:    runRestore,
	}

	cmd.Flags().StringP(fileFlagName, fileFlagShorthand, "", "Input zip file path (default: newest matching zip in C:\\Temp\\k2s\\Addons)")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runRestore(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	allAddons, addon, impl, err := loadAddonAndImpl(args)
	if err != nil {
		return err
	}
	ac.LogAddons(allAddons)

	zipPath, err := getAndValidateZipPath(cmd, impl.AddonsCmdName)
	if err != nil {
		return err
	}

	restoreScriptPath := filepath.Join(impl.Directory, "Restore.ps1")
	if !k2sos.PathExists(restoreScriptPath) {
		slog.Info("No Restore.ps1 found for addon; nothing to restore", "addon", addon.Metadata.Name, "implementation", impl.Name)
		cmdSession.Finish()
		return nil
	}

	stagingDir, cleanup, err := createStagingDir("k2s-addon-restore-*")
	if err != nil {
		return err
	}
	defer cleanup()

	if err := extractZipToDir(zipPath, stagingDir); err != nil {
		return err
	}

	manifest, err := readAndValidateManifest(filepath.Join(stagingDir, "backup.json"))
	if err != nil {
		return err
	}
	if err := validateManifestTargets(manifest, addon.Metadata.Name, impl.Name); err != nil {
		return err
	}
	if len(manifest.Files) == 0 {
		slog.Info("Backup contains no files; restore will only (re)enable the addon", "addon", addon.Metadata.Name, "implementation", impl.Name)
	}

	runtimeConfig, err := ensureK8sContext(cmd)
	if err != nil {
		return err
	}
	if isAddonEnabled(runtimeConfig, addon.Metadata.Name, impl.Name) {
		return fmt.Errorf("addon '%s' must be disabled before restore", impl.AddonsCmdName)
	}

	outputFlag, err := parseOutputFlag(cmd)
	if err != nil {
		return err
	}

	enableScriptPath := filepath.Join(impl.Directory, "EnableForRestore.ps1")
	useEnableForRestore := k2sos.PathExists(enableScriptPath)
	if !useEnableForRestore {
		enableScriptPath = filepath.Join(impl.Directory, "Enable.ps1")
	}
	if !k2sos.PathExists(enableScriptPath) {
		return fmt.Errorf("Enable.ps1 not found for addon '%s'", impl.AddonsCmdName)
	}
	// Pass the staging directory to EnableForRestore scripts so they can read
	// backup.json for addon-specific enable parameters (e.g. security addon
	// flags like --type, --ingress, --omitKeycloak). Only EnableForRestore.ps1
	// scripts accept -BackupDir; plain Enable.ps1 scripts do not.
	if useEnableForRestore {
		enableParams := []string{fmt.Sprintf(" -BackupDir %s", utils.EscapeWithSingleQuotes(stagingDir))}
		if err := executeScript(enableScriptPath, outputFlag, enableParams...); err != nil {
			return err
		}
	} else {
		if err := executeScript(enableScriptPath, outputFlag, selectorEnableParams(addon.Metadata.Name, manifest)...); err != nil {
			return err
		}
	}

	restoreParams := []string{fmt.Sprintf(" -BackupDir %s", utils.EscapeWithSingleQuotes(stagingDir))}
	if err := executeScript(restoreScriptPath, outputFlag, restoreParams...); err != nil {
		return err
	}

	slog.Info("Addon restore completed", "addon", addon.Metadata.Name, "implementation", impl.Name)
	cmdSession.Finish()
	return nil
}

func selectorEnableParams(addonName string, manifest backupManifest) []string {
	if !addonplacement.SupportsAddon(addonName) || strings.TrimSpace(manifest.InfraNodeSelector) == "" {
		return nil
	}
	return []string{fmt.Sprintf(" -InfraNodeSelector %s", utils.EscapeWithSingleQuotes(strings.TrimSpace(manifest.InfraNodeSelector)))}
}

func getAndValidateZipPath(cmd *cobra.Command, addonsCmdName string) (string, error) {
	zipPath, err := cmd.Flags().GetString(fileFlagName)
	if err != nil {
		return "", err
	}
	zipPath = strings.TrimSpace(zipPath)
	if zipPath == "" {
		latest, err := findLatestBackupZip(addonsCmdName)
		if err != nil {
			return "", err
		}
		zipPath = latest
	}
	if !k2sos.PathExists(zipPath) {
		return "", fmt.Errorf("backup file not found: %s", zipPath)
	}
	return zipPath, nil
}

func findLatestBackupZip(addonsCmdName string) (string, error) {
	backupDir := defaultAddonsBackupDir()
	safe := strings.NewReplacer(" ", "_", "\\\\", "_", "/", "_").Replace(addonsCmdName)
	pattern := filepath.Join(backupDir, fmt.Sprintf("%s_backup_*.zip", safe))

	candidates, err := filepath.Glob(pattern)
	if err != nil {
		return "", err
	}
	if len(candidates) == 0 {
		return "", fmt.Errorf("no backup zip found for '%s' in %s; provide -f/--file", addonsCmdName, backupDir)
	}

	latestPath := ""
	var latestTime time.Time
	for _, p := range candidates {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.IsDir() {
			continue
		}
		if latestPath == "" || info.ModTime().After(latestTime) {
			latestPath = p
			latestTime = info.ModTime()
		}
	}
	if latestPath == "" {
		return "", fmt.Errorf("no usable backup zip found for '%s' in %s; provide -f/--file", addonsCmdName, backupDir)
	}

	return latestPath, nil
}

func defaultAddonsBackupDir() string {
	if runtime.GOOS == "windows" {
		return `C:\Temp\k2s\Addons`
	}
	return filepath.Join(os.TempDir(), "k2s", "Addons")
}

func loadAddonAndImpl(args []string) (allAddons addons.Addons, addon addons.Addon, impl addons.Implementation, err error) {
	allAddons, err = addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return nil, addon, impl, err
	}

	addon, impl, err = ac.FindImplementation(allAddons, args)
	if err != nil {
		return allAddons, addon, impl, err
	}

	return allAddons, addon, impl, nil
}

func createStagingDir(pattern string) (dir string, cleanup func(), err error) {
	dir, err = os.MkdirTemp("", pattern)
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp dir: %w", err)
	}
	return dir, func() { _ = os.RemoveAll(dir) }, nil
}

func validateManifestTargets(manifest backupManifest, addonName, implementationName string) error {
	if !strings.EqualFold(manifest.Addon, addonName) {
		return fmt.Errorf("backup is for addon '%s', not '%s'", manifest.Addon, addonName)
	}
	if strings.TrimSpace(manifest.InfraNodeSelector) != "" && !addonplacement.SupportsAddon(addonName) {
		return fmt.Errorf("addon '%s' cannot replay the backup's infrastructure placement; its installation owner is not integrated", addonName)
	}
	if manifest.InfraNodeSelector != "" {
		if _, err := addonplacement.ParseSelector(manifest.InfraNodeSelector); err != nil {
			return fmt.Errorf("invalid backup infrastructure placement: %w", err)
		}
	}
	if addonName != implementationName {
		if !strings.EqualFold(manifest.Implementation, implementationName) {
			return fmt.Errorf("backup is for implementation '%s', not '%s'", manifest.Implementation, implementationName)
		}
	}
	return nil
}

func ensureK8sContext(cmd *cobra.Command) (*cconfig.K2sRuntimeConfig, error) {
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return nil, common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return nil, common.CreateSystemNotInstalledCmdFailure()
		}
		return nil, err
	}

	if err := context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name()); err != nil {
		return nil, err
	}
	return runtimeConfig, nil
}

func parseOutputFlag(cmd *cobra.Command) (bool, error) {
	return strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
}

func executeScript(scriptPath string, outputFlag bool, params ...string) error {
	psCmd := utils.FormatScriptFilePath(scriptPath)
	allParams := make([]string, 0, len(params)+1)
	allParams = append(allParams, params...)
	if outputFlag {
		allParams = append(allParams, " -ShowLogs")
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), allParams...)
	if err != nil {
		return err
	}
	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}
	return nil
}

func isAddonEnabled(runtimeConfig *cconfig.K2sRuntimeConfig, addonName, implementationName string) bool {
	expectedImpl := ""
	if addonName != implementationName {
		expectedImpl = implementationName
	}

	for _, a := range runtimeConfig.ClusterConfig().EnabledAddons() {
		if strings.EqualFold(a.Name, addonName) && strings.EqualFold(a.Implementation, expectedImpl) {
			return true
		}
	}
	return false
}

func readAndValidateManifest(manifestPath string) (backupManifest, error) {
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return backupManifest{}, fmt.Errorf("missing required backup.json: %w", err)
	}

	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})

	var manifest backupManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return backupManifest{}, fmt.Errorf("invalid backup.json: %w", err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return backupManifest{}, fmt.Errorf("invalid backup.json: %w", err)
	}
	if strings.TrimSpace(manifest.K2sVersion) == "" {
		return backupManifest{}, errors.New("invalid backup.json: missing 'k2sVersion'")
	}
	if _, ok := raw["files"]; !ok {
		return backupManifest{}, errors.New("invalid backup.json: missing 'files'")
	}
	if strings.TrimSpace(manifest.Addon) == "" {
		return backupManifest{}, errors.New("invalid backup.json: missing 'addon'")
	}
	return manifest, nil
}

func extractZipToDir(zipPath, destinationDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("failed to open zip: %w", err)
	}
	defer r.Close()

	base, err := filepath.Abs(destinationDir)
	if err != nil {
		return err
	}

	for _, f := range r.File {
		if err := extractZipEntry(f, base); err != nil {
			return err
		}
	}

	return nil
}

func extractZipEntry(f *zip.File, baseDir string) error {
	if f.FileInfo().Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("zip contains symlink entry: %s", f.Name)
	}

	rel := filepath.FromSlash(f.Name)
	targetPath := filepath.Join(baseDir, rel)
	targetPathClean := filepath.Clean(targetPath)

	if !isWithinBaseDir(baseDir, targetPathClean) {
		return fmt.Errorf("zip entry path traversal detected: %s", f.Name)
	}

	if f.FileInfo().IsDir() {
		return os.MkdirAll(targetPathClean, 0o755)
	}

	if err := os.MkdirAll(filepath.Dir(targetPathClean), 0o755); err != nil {
		return err
	}

	src, err := f.Open()
	if err != nil {
		return err
	}
	defer src.Close()

	dst, err := os.Create(targetPathClean)
	if err != nil {
		return err
	}
	defer dst.Close()

	_, err = io.Copy(dst, src)
	return err
}

func isWithinBaseDir(baseDir, targetPath string) bool {
	baseClean := filepath.Clean(baseDir)
	targetClean := filepath.Clean(targetPath)

	if strings.EqualFold(baseClean, targetClean) {
		return true
	}

	baseWithSep := baseClean + string(os.PathSeparator)
	return strings.HasPrefix(strings.ToLower(targetClean), strings.ToLower(baseWithSep))
}
