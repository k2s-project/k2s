// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package setuporchestration

// Orchestrator is the platform abstraction for cluster lifecycle operations.
// Each host operating system provides its own implementation.
type Orchestrator interface {
	// Install provisions the K2s cluster on this host.
	// On Windows: calls PowerShell scripts to create a Linux VM + Windows worker.
	// On Linux: runs kubeadm init natively + creates a Windows VM worker.
	Install(config InstallConfig) error

	// Uninstall tears down the cluster and removes all K2s resources.
	Uninstall(config UninstallConfig) error

	// Start brings up a previously stopped cluster.
	Start(config StartConfig) error

	// Stop gracefully stops the cluster.
	Stop(config StopConfig) error
}

// VMManager abstracts virtual machine lifecycle operations.
// On Windows: backed by Hyper-V cmdlets.
// On Linux: backed by libvirt/KVM.
type VMManager interface {
	// CreateVM provisions a new virtual machine from the given image.
	CreateVM(config VMConfig) error

	// StartVM starts a stopped virtual machine.
	StartVM(name string) error

	// StopVM gracefully shuts down a running virtual machine.
	StopVM(name string) error

	// RemoveVM destroys a virtual machine and its storage.
	RemoveVM(name string) error

	// VMExists checks whether a VM with the given name exists.
	VMExists(name string) (bool, error)

	// VMIsRunning checks whether a VM with the given name is currently running.
	VMIsRunning(name string) (bool, error)
}

// ServiceManager abstracts host-level service management.
// On Windows: backed by NSSM + Windows Service Control Manager.
// On Linux: backed by systemd.
type ServiceManager interface {
	// StartService starts a named service.
	StartService(name string) error

	// StopService stops a named service.
	StopService(name string) error

	// RestartService restarts a named service.
	RestartService(name string) error

	// IsServiceRunning checks whether a named service is running.
	IsServiceRunning(name string) (bool, error)

	// InstallService installs a service with the given configuration.
	InstallService(config ServiceConfig) error

	// RemoveService uninstalls a named service.
	RemoveService(name string) error
}

// InstallConfig holds parameters for cluster installation.
type InstallConfig struct {
	ShowLogs                bool
	SkipStart               bool
	MasterVMProcessorCount  string
	MasterVMMemory          string
	MasterDiskSize          string
	LinuxOnly               bool
	WSL                     bool
	ForceOnlineInstallation bool
	Proxy                   string
	NoProxy                 []string
	AdditionalHooksDir      string
	ConfigDir               string // K2s setup config dir (e.g. /var/lib/k2s or C:\ProgramData\K2s)
	InstallDir              string // K2s install dir (directory of the k2s binary)
	Version                 string // K2s version string
	ClusterName             string // Kubernetes cluster name
	ControlPlaneHostname    string // hostname of the control plane node
}

// UninstallConfig holds parameters for cluster uninstallation.
type UninstallConfig struct {
	ShowLogs                          bool
	SkipPurge                         bool
	LinuxOnly                         bool
	DeleteFilesForOfflineInstallation bool
	AdditionalHooksDir                string
	ConfigDir                         string // K2s setup config dir
}

// StartConfig holds parameters for cluster start.
type StartConfig struct {
	ShowLogs            bool
	LinuxOnly           bool
	AdditionalHooksDir  string
	UseCachedK2sVSwitch bool
	ConfigDir           string
	InstallDir          string
}

// StopConfig holds parameters for cluster stop.
type StopConfig struct {
	ShowLogs           bool
	LinuxOnly          bool
	AdditionalHooksDir string
	ConfigDir          string
}

// VMConfig holds parameters for virtual machine creation.
type VMConfig struct {
	Name          string
	ImagePath     string
	CPUCount      int
	MemoryMB      int
	DiskSizeGB    int
	NetworkBridge string
	DynamicMemory bool
}

// ServiceConfig holds parameters for service installation.
type ServiceConfig struct {
	Name       string
	BinaryPath string
	Args       []string
	WorkingDir string
}
