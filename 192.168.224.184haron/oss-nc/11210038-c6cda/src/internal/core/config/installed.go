// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"errors"
	"fmt"
	"log/slog"
	bos "os"
	"path/filepath"
	"runtime"
	"strings"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/json"
	kos "github.com/k2s-project/k2s/internal/os"
)

// k2sCliBaseName is the base name of the K2s CLI executable.
const k2sCliBaseName = "k2s"

// setupJson is the minimal struct for reading InstallFolder from setup.json.
type setupJson struct {
	InstallFolder string `json:"InstallFolder"`
}

// InstalledK2s describes an already installed K2s system that was discovered
// independently of the currently running package's configuration.
type InstalledK2s struct {
	// InstallDir is the installation root of the discovered K2s, e.g. 'C:\ws\K2s'.
	InstallDir string
	// Config is the configuration read from '<InstallDir>\cfg\config.json'.
	// Its Host().K2sSetupConfigDir() points to the actual (possibly customized)
	// 'configDir.k2s' of the installed system.
	Config *contracts.K2sConfig
	// RuntimeConfig is the setup config read from '<configDir.k2s>\setup.json'.
	// It is always set, even if the installation is marked as corrupted.
	RuntimeConfig *contracts.K2sRuntimeConfig
}

// dirKey normalizes a directory path for comparison, honoring the case-sensitivity
// semantics of the current platform.
func dirKey(dir string) string {
	cleaned := filepath.Clean(dir)
	if runtime.GOOS == "windows" {
		return strings.ToLower(cleaned)
	}
	return cleaned
}

// ReadInstallFolder reads the 'InstallFolder' entry from the setup.json located
// in the given config dir. An empty string is returned if the entry is not set.
func ReadInstallFolder(configDir string) (string, error) {
	setupConfigPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	setup, err := json.FromFile[setupJson](setupConfigPath)
	if err != nil {
		return "", fmt.Errorf("error occurred while loading setup config file '%s': %w", setupConfigPath, err)
	}
	return setup.InstallFolder, nil
}

// ResolveInstalledK2s discovers an already installed K2s system via the PATH
// environment variable. K2s adds its installation root to the machine PATH during
// installation, therefore the installed system can be located even if the currently
// running package is configured with a different 'configDir.k2s'.
//
// Discovery:
//
//	PATH -> k2s executables (excluding the running one) -> install dir
//	     -> <install dir>/cfg/config.json -> configDir.k2s
//	     -> <configDir.k2s>/setup.json
//
// Errors:
//   - contracts.ErrSystemNotInstalled if no valid installation was found
//   - contracts.ErrSystemInCorruptedState if the single installation found is corrupted
//   - an explicit error if more than one valid installation was found
func ResolveInstalledK2s() (*InstalledK2s, error) {
	currentExe, err := bos.Executable()
	if err != nil {
		return nil, fmt.Errorf("could not determine current executable: %w", err)
	}
	return resolveInstalledK2s(currentExe)
}

func resolveInstalledK2s(currentExe string) (*InstalledK2s, error) {
	exeName := kos.ExecutableFileName(k2sCliBaseName)

	candidates, err := kos.FindOtherExecutablesInPath(currentExe, exeName)
	if err != nil {
		return nil, fmt.Errorf("error occurred while scanning PATH for '%s': %w", exeName, err)
	}

	var found []*InstalledK2s
	var corruptedErr error
	seenDirs := map[string]bool{}

	for _, candidateExe := range candidates {
		installDir := filepath.Dir(candidateExe)

		key := dirKey(installDir)
		if seenDirs[key] {
			continue
		}
		seenDirs[key] = true

		k2sConfig, err := ReadK2sConfig(installDir)
		if err != nil {
			slog.Debug("Skipping PATH candidate, config file could not be read", "install-dir", installDir, "error", err)
			continue
		}

		setupConfigDir := k2sConfig.Host().K2sSetupConfigDir()
		if setupConfigDir == "" {
			slog.Debug("Skipping PATH candidate, 'configDir.k2s' is empty", "install-dir", installDir)
			continue
		}

		runtimeConfig, err := ReadRuntimeConfig(setupConfigDir)
		if err != nil {
			if !errors.Is(err, contracts.ErrSystemInCorruptedState) {
				slog.Debug("Skipping PATH candidate, setup config could not be read", "install-dir", installDir, "config-dir", setupConfigDir, "error", err)
				continue
			}
			// A corrupted installation is still an existing installation, therefore the
			// candidate is kept and the corrupted-state error is propagated to the caller.
			slog.Warn("Installed K2s found in corrupted state", "install-dir", installDir, "config-dir", setupConfigDir)
			corruptedErr = err
		}

		// InstallFolder is persisted state and may be stale (e.g. after moving the
		// installation), whereas PATH reflects the live installation. Therefore a
		// mismatch is only logged and does not reject the candidate.
		if installFolder, err := ReadInstallFolder(setupConfigDir); err == nil {
			if installFolder != "" && dirKey(installFolder) != key {
				slog.Warn("'InstallFolder' in setup config differs from installation directory found in PATH",
					"install-folder", installFolder, "install-dir", installDir)
			}
		}

		slog.Debug("Installed K2s candidate found via PATH", "install-dir", installDir, "config-dir", setupConfigDir)

		found = append(found, &InstalledK2s{InstallDir: installDir, Config: k2sConfig, RuntimeConfig: runtimeConfig})
	}

	switch len(found) {
	case 0:
		return nil, contracts.ErrSystemNotInstalled
	case 1:
		slog.Info("Installed K2s discovered via PATH", "install-dir", found[0].InstallDir, "config-dir", found[0].Config.Host().K2sSetupConfigDir())
		return found[0], corruptedErr
	default:
		installDirs := make([]string, 0, len(found))
		for _, installed := range found {
			installDirs = append(installDirs, installed.InstallDir)
		}
		return nil, fmt.Errorf("found multiple installed K2s (%s); please clean up your PATH environment variable so that only one K2s installation remains", strings.Join(installDirs, ", "))
	}
}
