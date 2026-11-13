// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"errors"
)

type Registry string

type Addon struct {
	Name           string
	Implementation string
}

type K2sRuntimeConfig struct {
	clusterConfig      *K2sClusterConfig
	installConfig      *K2sInstallConfig
	controlPlaneConfig *K2sControlPlaneConfig
}

type K2sClusterConfig struct {
	name               string
	registries         []Registry
	controlPlaneConfig *K2sControlPlaneConfig
	enabledAddons      []Addon
}

type K2sInstallConfig struct {
	setupName  string
	linuxOnly  bool
	version    string
	corrupted  bool
	wslEnabled bool
}

type K2sControlPlaneConfig struct {
	hostname string
}

var (
	ErrSystemNotInstalled     = errors.New("system-not-installed")
	ErrSystemInCorruptedState = errors.New("system-in-corrupted-state")
)

func NewK2sRuntimeConfig(clusterConfig *K2sClusterConfig, installConfig *K2sInstallConfig, controlPlaneConfig *K2sControlPlaneConfig) *K2sRuntimeConfig {
	return &K2sRuntimeConfig{
		clusterConfig:      clusterConfig,
		installConfig:      installConfig,
		controlPlaneConfig: controlPlaneConfig,
	}
}

func NewK2sClusterConfig(name string, registries []Registry, controlPlaneConfig *K2sControlPlaneConfig, enabledAddons []Addon) *K2sClusterConfig {
	return &K2sClusterConfig{
		name:               name,
		registries:         registries,
		controlPlaneConfig: controlPlaneConfig,
		enabledAddons:      enabledAddons,
	}
}

func NewK2sInstallConfig(setupName string, linuxOnly bool, version string, corrupted, wslEnabled bool) *K2sInstallConfig {
	return &K2sInstallConfig{
		setupName:  setupName,
		linuxOnly:  linuxOnly,
		version:    version,
		corrupted:  corrupted,
		wslEnabled: wslEnabled,
	}
}

func NewK2sControlPlaneConfig(hostname string) *K2sControlPlaneConfig {
	return &K2sControlPlaneConfig{
		hostname: hostname,
	}
}

func (c *K2sRuntimeConfig) ClusterConfig() *K2sClusterConfig {
	return c.clusterConfig
}

func (c *K2sRuntimeConfig) InstallConfig() *K2sInstallConfig {
	return c.installConfig
}

func (c *K2sRuntimeConfig) ControlPlaneConfig() *K2sControlPlaneConfig {
	return c.controlPlaneConfig
}

func (c *K2sClusterConfig) Name() string {
	return c.name
}

func (c *K2sClusterConfig) Registries() []Registry {
	return c.registries
}

func (c *K2sClusterConfig) ControlPlaneConfig() *K2sControlPlaneConfig {
	return c.controlPlaneConfig
}

func (c *K2sClusterConfig) EnabledAddons() []Addon {
	return c.enabledAddons
}

func (c *K2sInstallConfig) SetupName() string {
	return c.setupName
}

func (c *K2sInstallConfig) LinuxOnly() bool {
	return c.linuxOnly
}

func (c *K2sInstallConfig) Version() string {
	return c.version
}

func (c *K2sInstallConfig) Corrupted() bool {
	return c.corrupted
}

func (c *K2sInstallConfig) WslEnabled() bool {
	return c.wslEnabled
}

func (c *K2sControlPlaneConfig) Hostname() string {
	return c.hostname
}
