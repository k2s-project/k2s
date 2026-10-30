// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

package backup

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
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
	"github.com/k2s-project/k2s/internal/core/addons"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	k2sos "github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/internal/providers/powershell"
	"github.com/spf13/cobra"
)

const (
	fileFlagName      = "file"
	fileFlagShorthand = "f"
)

type backupManifest struct {
	K2sVersion     string   `json:"k2sVersion"`
	Files          []string `json:"files"`
	Addon          string   `json:"addon"`
	Implementation string   `json:"implementation,omitempty"`
	CreatedAt      string   `json:"createdAt,omitempty"`
}

var backupExample = `
  # Backup addon "registry"
    k2s addons backup registry -f registry-backup.zip

  # Backup addon "ingress nginx"
    k2s addons backup "ingress nginx" -f ingress-nginx-backup.zip

  # Backup addon "ingress nginx" to default backup folder
    k2s addons backup "ingress nginx"
`

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "backup ADDON [IMPLEMENTATION]",
		Short:   "Backup addon data",
		Example: backupExample,
		Args:    cobra.RangeArgs(1, 2),
		RunE:    runBackup,
	}

	cmd.Flags().StringP(fileFlagName, fileFlagShorthand, "", "Output zip file path")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runBackup(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	allAddons, addon, impl, err := loadAddonAndImpl(args)
	if err != nil {
		return err
	}
	ac.LogAddons(allAddons)

	psScriptPath := filepath.Join(impl.Directory, "Backup.ps1")
	if !k2sos.PathExists(psScriptPath) {
		slog.Info("No Backup.ps1 found for addon; nothing to backup", "addon", addon.Metadata.Name, "implementation", impl.Name)
		cmdSession.Finish()
		return nil
	}

	if err := ensureK8sContext(cmd); err != nil {
		return err
	}

	stagingDir, cleanup, err := createStagingDir("k2s-addon-backup-*")
	if err != nil {
		return err
	}
	defer cleanup()

	outputFlag, err := parseOutputFlag(cmd)
	if err != nil {
		return err
	}

	if err := executeBackupScript(psScriptPath, stagingDir, outputFlag); err != nil {
		return err
	}
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	configPath := filepath.Join(context.Config().Host().K2sSetupConfigDir(), definitions.K2sRuntimeConfigFileName)
	if err := addPlacementMetadata(filepath.Join(stagingDir, "backup.json"), configPath, addon.Metadata.Name, impl.Name); err != nil {
		return err
	}

	manifest, err := readAndValidateManifest(filepath.Join(stagingDir, "backup.json"))
	if err != nil {
		return err
	}
	if len(manifest.Files) == 0 {
		slog.Info("Addon backup contains no files; creating metadata-only backup zip", "addon", addon.Metadata.Name, "implementation", impl.Name)
	}

	zipPath, err := cmd.Flags().GetString(fileFlagName)
	if err != nil {
		return err
	}
	zipPath, err = defaultZipPathIfEmpty(zipPath, impl.AddonsCmdName)
	if err != nil {
		return err
	}

	if err := createZipFromDir(stagingDir, zipPath); err != nil {
		return err
	}

	slog.Info("Addon backup created", "addon", addon.Metadata.Name, "implementation", impl.Name, "file", zipPath)
	cmdSession.Finish()
	return nil
}

func addPlacementMetadata(manifestPath, configPath, addonName, implementation string) error {
	// Best effort: a missing or unreadable runtime config must not fail a backup.
	configData, err := os.ReadFile(configPath)
	if err != nil {
		slog.Warn("Skipping addon placement metadata; runtime config unreadable", "path", configPath, "error", err)
		return nil
	}
	var config struct {
		EnabledAddons []struct {
			Name              string
			Implementation    string
			InfraNodeSelector string
		}
	}
	if err := json.Unmarshal(bytes.TrimPrefix(configData, []byte{0xEF, 0xBB, 0xBF}), &config); err != nil {
		slog.Warn("Skipping addon placement metadata; runtime config invalid", "path", configPath, "error", err)
		return nil
	}
	selector := ""
	for _, addon := range config.EnabledAddons {
		if addon.Name == addonName && addon.Implementation == implementation {
			selector = addon.InfraNodeSelector
			break
		}
	}
	if selector == "" && addonName == implementation {
		for _, addon := range config.EnabledAddons {
			if addon.Name == addonName && addon.Implementation == "" {
				selector = addon.InfraNodeSelector
				break
			}
		}
	}
	if selector == "" {
		return nil
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return err
	}
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF}), &manifest); err != nil {
		return err
	}
	if manifest == nil {
		return errors.New("invalid backup.json: expected an object")
	}
	encodedSelector, err := json.Marshal(selector)
	if err != nil {
		return err
	}
	manifest["infraNodeSelector"] = encodedSelector
	data, err = json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(manifestPath, data, 0o600)
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

func ensureK8sContext(cmd *cobra.Command) error {
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

	return context.EnsureK2sK8sContext(runtimeConfig.ClusterConfig().Name())
}

func createStagingDir(pattern string) (dir string, cleanup func(), err error) {
	dir, err = os.MkdirTemp("", pattern)
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp dir: %w", err)
	}
	return dir, func() { _ = os.RemoveAll(dir) }, nil
}

func parseOutputFlag(cmd *cobra.Command) (bool, error) {
	return strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
}

func executeBackupScript(scriptPath, stagingDir string, outputFlag bool) error {
	psCmd := utils.FormatScriptFilePath(scriptPath)
	params := []string{fmt.Sprintf(" -BackupDir %s", utils.EscapeWithSingleQuotes(stagingDir))}
	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}
	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}
	return nil
}

func readAndValidateManifest(manifestPath string) (backupManifest, error) {
	manifestData, err := os.ReadFile(manifestPath)
	if err != nil {
		return backupManifest{}, fmt.Errorf("backup script did not create required backup.json: %w", err)
	}

	manifestData = bytes.TrimPrefix(manifestData, []byte{0xEF, 0xBB, 0xBF})

	var manifest backupManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		return backupManifest{}, fmt.Errorf("invalid backup.json: %w", err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(manifestData, &raw); err != nil {
		return backupManifest{}, fmt.Errorf("invalid backup.json: %w", err)
	}
	if strings.TrimSpace(manifest.K2sVersion) == "" {
		return backupManifest{}, errors.New("invalid backup.json: missing 'k2sVersion'")
	}
	if _, ok := raw["files"]; !ok {
		return backupManifest{}, errors.New("invalid backup.json: missing 'files'")
	}
	return manifest, nil
}

func defaultZipPathIfEmpty(zipPath string, addonsCmdName string) (string, error) {
	zipPath = strings.TrimSpace(zipPath)
	if zipPath == "" {
		wd := filepath.Join(os.TempDir(), "k2s", "Addons")
		if runtime.GOOS == "windows" {
			wd = `C:\Temp\k2s\Addons`
		}
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return "", fmt.Errorf("failed to create default addons backup directory: %w", err)
		}
		safe := strings.NewReplacer(" ", "_", "\\", "_", "/", "_").Replace(addonsCmdName)
		zipPath = filepath.Join(wd, fmt.Sprintf("%s_backup_%s.zip", safe, time.Now().Format("20060102_150405")))
	}
	if !strings.HasSuffix(strings.ToLower(zipPath), ".zip") {
		zipPath += ".zip"
	}
	return zipPath, nil
}

func createZipFromDir(sourceDir, zipPath string) error {
	_, zipWriter, cleanup, err := createZipFile(zipPath)
	if err != nil {
		return err
	}
	defer cleanup()

	return filepath.WalkDir(sourceDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		return addFileToZip(zipWriter, sourceDir, path, d)
	})
}

func createZipFile(zipPath string) (zipFile *os.File, zipWriter *zip.Writer, cleanup func(), err error) {
	if err := os.MkdirAll(filepath.Dir(zipPath), 0o755); err != nil {
		return nil, nil, nil, fmt.Errorf("failed to create output directory: %w", err)
	}

	zipFile, err = os.Create(zipPath)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("failed to create zip file: %w", err)
	}

	zipWriter = zip.NewWriter(zipFile)
	cleanup = func() {
		_ = zipWriter.Close()
		_ = zipFile.Close()
	}
	return zipFile, zipWriter, cleanup, nil
}

func addFileToZip(zipWriter *zip.Writer, sourceDir string, filePath string, d fs.DirEntry) error {
	rel, err := filepath.Rel(sourceDir, filePath)
	if err != nil {
		return err
	}
	rel = filepath.ToSlash(rel)

	info, err := d.Info()
	if err != nil {
		return err
	}

	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	header.Name = rel
	header.Method = zip.Deflate

	writer, err := zipWriter.CreateHeader(header)
	if err != nil {
		return err
	}

	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = io.Copy(writer, file)
	return err
}
