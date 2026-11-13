// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/json"
)

type config struct {
	SetupName                string               `json:"SetupType"`
	Registries               []contracts.Registry `json:"Registries"`
	LinuxOnly                bool                 `json:"LinuxOnly"`
	Version                  string               `json:"Version"`
	ControlPlaneNodeHostname string               `json:"ControlPlaneNodeHostname"`
	Corrupted                bool                 `json:"Corrupted"`
	ClusterName              string               `json:"ClusterName"`
	WslEnabled               bool                 `json:"WSL"`
	EnabledAddons            []addon              `json:"EnabledAddons"`
}

type addon struct {
	Name           string `json:"Name"`
	Implementation string `json:"Implementation"`
}

func ReadRuntimeConfig(configDir string) (*contracts.K2sRuntimeConfig, error) {
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	config, err := json.FromFile[config](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Debug("Setup config file not found, assuming setup is not installed", "err-msg", err, "path", configPath)

			return nil, contracts.ErrSystemNotInstalled
		}
		return nil, fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	if config.ClusterName == "" {
		slog.Info("Cluster name not found in setup config, defaulting to legacy cluster name", "cluster-name", definitions.LegacyClusterName)
		config.ClusterName = definitions.LegacyClusterName
	}

	controlPlaneConfig := contracts.NewK2sControlPlaneConfig(config.ControlPlaneNodeHostname)
	clusterConfig := contracts.NewK2sClusterConfig(config.ClusterName, config.Registries, controlPlaneConfig, mapAddons(config.EnabledAddons))
	installConfig := contracts.NewK2sInstallConfig(config.SetupName, config.LinuxOnly, config.Version, config.Corrupted, config.WslEnabled)

	k2sRuntimeConfig := contracts.NewK2sRuntimeConfig(clusterConfig, installConfig, controlPlaneConfig)

	if config.Corrupted {
		// <config> instead of <nil> so that e.g. 'k2s uninstall' cmd can use it's content
		return k2sRuntimeConfig, contracts.ErrSystemInCorruptedState
	}
	return k2sRuntimeConfig, nil
}

func MarkSetupAsCorrupted(configDir string) error {
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	config, err := json.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			newConfig := map[string]any{definitions.SetupCorruptedKey: true}

			return json.ToFile(configPath, &newConfig)
		}
		return fmt.Errorf("error occurred while loading setup config file: %w", err)
	}

	(*config)[definitions.SetupCorruptedKey] = true

	return json.ToFile(configPath, config)
}

func mapAddons(inputAddons []addon) (addons []contracts.Addon) {
	for _, addon := range inputAddons {
		addons = append(addons, contracts.Addon{
			Name:           addon.Name,
			Implementation: addon.Implementation,
		})
	}
	return
}

// WriteRuntimeConfig persists the setup configuration to the given directory.
// It creates the directory if it does not exist.
func WriteRuntimeConfig(configDir string, setupName string, linuxOnly bool, version string, clusterName string, controlPlaneHostname string, wslEnabled bool) error {
	if err := os.MkdirAll(configDir, os.ModePerm); err != nil {
		return fmt.Errorf("failed to create config directory '%s': %w", configDir, err)
	}

	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)

	cfg := &config{
		SetupName:                setupName,
		LinuxOnly:                linuxOnly,
		Version:                  version,
		ClusterName:              clusterName,
		ControlPlaneNodeHostname: controlPlaneHostname,
		WslEnabled:               wslEnabled,
	}

	return json.ToFile(configPath, cfg)
}
