// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

type K2sConfig struct {
	hostConfig         *HostConfig
	controlPlaneConfig *ControlPlaneConfig
}

type HostConfig struct {
	kubeConfig        *KubeConfig
	sshConfig         *SSHConfig
	k2sSetupConfigDir string
	k2sInstallDir     string
	logsDir           string
}

type KubeConfig struct { // TODO: dir + files really necessary?
	currentDir  string
	currentPath string
	relativeDir string
}

type SSHConfig struct {
	currentDir            string
	currentPrivateKeyPath string
	relativeDir           string
}

type ControlPlaneConfig struct {
	ipAddr string
}

func NewK2sConfig(hostConfig *HostConfig, controlPlaneConfig *ControlPlaneConfig) *K2sConfig {
	return &K2sConfig{
		hostConfig:         hostConfig,
		controlPlaneConfig: controlPlaneConfig,
	}
}

func NewControlPlaneConfig(ipAddr string) *ControlPlaneConfig {
	return &ControlPlaneConfig{
		ipAddr: ipAddr,
	}
}

func NewHostConfig(kubeConfig *KubeConfig, sshConfig *SSHConfig, k2sSetupConfigDir, k2sInstallDir, logsDir string) *HostConfig {
	return &HostConfig{
		kubeConfig:        kubeConfig,
		sshConfig:         sshConfig,
		k2sSetupConfigDir: k2sSetupConfigDir,
		k2sInstallDir:     k2sInstallDir,
		logsDir:           logsDir,
	}
}

func NewKubeConfig(currentDir, relativeDir, currentPath string) *KubeConfig {
	return &KubeConfig{
		currentDir:  currentDir,
		currentPath: currentPath,
		relativeDir: relativeDir,
	}
}

func NewSshConfig(currentDir, relativeDir, currentPrivateKeyPath string) *SSHConfig {
	return &SSHConfig{
		currentDir:            currentDir,
		relativeDir:           relativeDir,
		currentPrivateKeyPath: currentPrivateKeyPath,
	}
}

func (c *K2sConfig) Host() *HostConfig {
	return c.hostConfig
}
func (c *K2sConfig) ControlPlane() *ControlPlaneConfig {
	return c.controlPlaneConfig
}

func (h *HostConfig) K2sSetupConfigDir() string {
	return h.k2sSetupConfigDir
}

func (h *HostConfig) K2sInstallDir() string {
	return h.k2sInstallDir
}

// LogsDir returns the configured root log directory from cfg/config.json (configDir.logs).
// May be empty if the key is not set; consumers should fall back to logging.RootLogDir() in that case.
func (h *HostConfig) LogsDir() string {
	return h.logsDir
}

func (c *HostConfig) KubeConfig() *KubeConfig {
	return c.kubeConfig
}

func (c *HostConfig) SshConfig() *SSHConfig {
	return c.sshConfig
}

func (c *ControlPlaneConfig) IpAddress() string {
	return c.ipAddr
}

func (c *KubeConfig) CurrentDir() string {
	return c.currentDir
}

func (c *KubeConfig) RelativeDir() string {
	return c.relativeDir
}

func (c *KubeConfig) CurrentPath() string {
	return c.currentPath
}

func (c *SSHConfig) CurrentDir() string {
	return c.currentDir
}

func (c *SSHConfig) RelativeDir() string {
	return c.relativeDir
}

func (c *SSHConfig) CurrentPrivateKeyPath() string {
	return c.currentPrivateKeyPath
}
