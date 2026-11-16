// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"fmt"
	"net"
	"path/filepath"
	"runtime"
	"strconv"

	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	"github.com/k2s-project/k2s/internal/json"
)

type cloudImageConfig struct {
	UrlRoot string `json:"urlRoot"`
	UrlFile string `json:"urlFile"`
}

type supportedWorkerOSEntry struct {
	OS         string           `json:"os"`
	CloudImage cloudImageConfig `json:"cloudImage"`
}

type configJson struct {
	SmallSetup        smallSetup               `json:"smallsetup"`
	ConfigDir         configDir                `json:"configDir"`
	SupportedWorkerOS []supportedWorkerOSEntry `json:"supportedWorkerOS"`
}

type smallSetup struct {
	ControlPlanIpAddress string `json:"masterIP"`
	KubeSwitchIPAddress  string `json:"kubeSwitch"`
	MasterNetworkCIDR    string `json:"masterNetworkCIDR"`
	ServicesCIDR         string `json:"servicesCIDR"`
	ServicesCIDRLinux    string `json:"servicesCIDRLinux"`
	ServicesCIDRWindows  string `json:"servicesCIDRWindows"`
}

// KubeSwitchConfig contains the K2s host gateway address and network from the
// central cfg/config.json configuration.
type KubeSwitchConfig struct {
	Address     string
	CIDR        string
	AddressCIDR string
}

// ServiceCIDRConfig contains the overall Kubernetes Service CIDR and the
// OS-specific allocation partitions enforced by the ClusterIP webhook.
type ServiceCIDRConfig struct {
	CIDR        string
	LinuxCIDR   string
	WindowsCIDR string
}

type configDir struct {
	Kube string `json:"kube"`
	K2s  string `json:"k2s"`
	Ssh  string `json:"ssh"`
	Logs string `json:"logs"`
}

// configFileRelDir and configFileName are joined via filepath.Join so the
// correct OS path separator is used on both Windows and Linux.
const (
	configFileRelDir = "cfg"
	configFileName   = "config.json"
)

func ReadK2sConfig(k2sInstallDir string) (*cconfig.K2sConfig, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error occurred while loading config file: %w", err)
	}

	kubeConfigDir, err := host.ResolveTildePrefixForCurrentUser(configJson.ConfigDir.Kube)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Kube, err)
	}

	sshDir, err := host.ResolveTildePrefixForCurrentUser(configJson.ConfigDir.Ssh)
	if err != nil {
		return nil, fmt.Errorf("error occurred while resolving tilde in file path '%s': %w", configJson.ConfigDir.Ssh, err)
	}

	kubeConfig := cconfig.NewKubeConfig(kubeConfigDir, configJson.ConfigDir.Kube, filepath.Join(kubeConfigDir, definitions.KubeconfigName))
	sshConfig := cconfig.NewSshConfig(sshDir, configJson.ConfigDir.Ssh, filepath.Join(sshDir, definitions.SSHSubDirName, definitions.SSHPrivateKeyName))
	k2sConfigDir := configJson.ConfigDir.K2s
	logsDir := configJson.ConfigDir.Logs
	if runtime.GOOS == "linux" {
		k2sConfigDir = "/var/lib/k2s"
		logsDir = "/var/log/k2s"
	}
	hostConfig := cconfig.NewHostConfig(kubeConfig, sshConfig, k2sConfigDir, k2sInstallDir, logsDir)
	controlPlaneConfig := cconfig.NewControlPlaneConfig(configJson.SmallSetup.ControlPlanIpAddress)

	return cconfig.NewK2sConfig(hostConfig, controlPlaneConfig), nil
}

// ReadSupportedWorkerOS returns the list of supported worker OS keys (e.g. "debian12", "debian13")
// from the supportedWorkerOS array in cfg/config.json.
func ReadSupportedWorkerOS(k2sInstallDir string) ([]string, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}

	result := make([]string, 0, len(configJson.SupportedWorkerOS))
	for _, entry := range configJson.SupportedWorkerOS {
		result = append(result, entry.OS)
	}
	return result, nil
}

func ReadKubeSwitchCIDR(k2sInstallDir string) (string, error) {
	config, err := ReadKubeSwitchConfig(k2sInstallDir)
	if err != nil {
		return "", err
	}
	return config.CIDR, nil
}

// ReadServiceCIDRConfig loads and validates the Service IP allocation ranges
// from cfg/config.json. The Linux and Windows partitions must be distinct
// subnets of the overall Service CIDR configured for kubeadm.
func ReadServiceCIDRConfig(k2sInstallDir string) (ServiceCIDRConfig, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)
	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return ServiceCIDRConfig{}, fmt.Errorf("error reading config file: %w", err)
	}

	_, serviceNetwork, err := net.ParseCIDR(configJson.SmallSetup.ServicesCIDR)
	if err != nil {
		return ServiceCIDRConfig{}, fmt.Errorf("invalid services CIDR %q in config: %w", configJson.SmallSetup.ServicesCIDR, err)
	}
	_, linuxNetwork, err := net.ParseCIDR(configJson.SmallSetup.ServicesCIDRLinux)
	if err != nil {
		return ServiceCIDRConfig{}, fmt.Errorf("invalid Linux services CIDR %q in config: %w", configJson.SmallSetup.ServicesCIDRLinux, err)
	}
	_, windowsNetwork, err := net.ParseCIDR(configJson.SmallSetup.ServicesCIDRWindows)
	if err != nil {
		return ServiceCIDRConfig{}, fmt.Errorf("invalid Windows services CIDR %q in config: %w", configJson.SmallSetup.ServicesCIDRWindows, err)
	}
	if !serviceNetwork.Contains(linuxNetwork.IP) || !serviceNetwork.Contains(windowsNetwork.IP) {
		return ServiceCIDRConfig{}, fmt.Errorf("Linux and Windows service CIDRs must be within overall services CIDR %q", configJson.SmallSetup.ServicesCIDR)
	}
	if linuxNetwork.Contains(windowsNetwork.IP) || windowsNetwork.Contains(linuxNetwork.IP) {
		return ServiceCIDRConfig{}, fmt.Errorf("Linux service CIDR %q overlaps Windows service CIDR %q", configJson.SmallSetup.ServicesCIDRLinux, configJson.SmallSetup.ServicesCIDRWindows)
	}

	return ServiceCIDRConfig{
		CIDR:        configJson.SmallSetup.ServicesCIDR,
		LinuxCIDR:   configJson.SmallSetup.ServicesCIDRLinux,
		WindowsCIDR: configJson.SmallSetup.ServicesCIDRWindows,
	}, nil
}

// ReadKubeSwitchConfig loads and validates the configured KubeSwitch address
// and its containing CIDR from cfg/config.json.
func ReadKubeSwitchConfig(k2sInstallDir string) (KubeSwitchConfig, error) {
	configFilePath := filepath.Join(k2sInstallDir, configFileRelDir, configFileName)

	configJson, err := json.FromFile[configJson](configFilePath)
	if err != nil {
		return KubeSwitchConfig{}, fmt.Errorf("error reading config file: %w", err)
	}
	address := net.ParseIP(configJson.SmallSetup.KubeSwitchIPAddress)
	if address == nil {
		return KubeSwitchConfig{}, fmt.Errorf("invalid KubeSwitch address %q in config", configJson.SmallSetup.KubeSwitchIPAddress)
	}
	_, network, err := net.ParseCIDR(configJson.SmallSetup.MasterNetworkCIDR)
	if err != nil {
		return KubeSwitchConfig{}, fmt.Errorf("invalid KubeSwitch CIDR %q in config: %w", configJson.SmallSetup.MasterNetworkCIDR, err)
	}
	if !network.Contains(address) {
		return KubeSwitchConfig{}, fmt.Errorf("KubeSwitch address %q is not in configured CIDR %q", configJson.SmallSetup.KubeSwitchIPAddress, configJson.SmallSetup.MasterNetworkCIDR)
	}
	prefixLength, _ := network.Mask.Size()

	return KubeSwitchConfig{
		Address:     configJson.SmallSetup.KubeSwitchIPAddress,
		CIDR:        configJson.SmallSetup.MasterNetworkCIDR,
		AddressCIDR: configJson.SmallSetup.KubeSwitchIPAddress + "/" + strconv.Itoa(prefixLength),
	}, nil
}

func DetectLocalVM(ipAddress, installDir string) (bool, error) {
	cidr, err := ReadKubeSwitchCIDR(installDir)
	if err != nil {
		return false, fmt.Errorf("cannot read KubeSwitch CIDR: %w", err)
	}
	if cidr == "" {
		return false, nil
	}
	_, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return false, fmt.Errorf("invalid KubeSwitch CIDR '%s': %w", cidr, err)
	}
	ip := net.ParseIP(ipAddress)
	if ip == nil {
		return false, nil
	}
	return network.Contains(ip), nil
}
