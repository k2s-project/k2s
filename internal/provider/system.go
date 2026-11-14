// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

// SystemProvider abstracts system-level operations (dump, upgrade, packaging, etc.).
// On Windows: delegates to PowerShell scripts.
// On Linux: uses native commands (kubectl, qemu-img, etc.).
type SystemProvider interface {
	// Dump collects diagnostic information from the cluster.
	Dump(config SystemDumpConfig) error

	// Upgrade upgrades the K2s cluster from a package.
	Upgrade(config SystemUpgradeConfig) error

	// Package creates an offline installation package.
	Package(config SystemPackageConfig) error

	// Reset resets the K2s system to a clean state.
	Reset(config SystemResetConfig) error

	// ResetNetwork resets the cluster networking.
	ResetNetwork(config SystemResetNetworkConfig) error

	// Compact compacts VM disk images to reclaim space.
	Compact(config SystemCompactConfig) error

	// Backup creates a backup of the cluster state.
	Backup(config SystemBackupConfig) error

	// Restore restores the cluster from a backup.
	Restore(config SystemRestoreConfig) error

	// CertificateRenew renews the Kubernetes certificates.
	CertificateRenew(config SystemCertRenewConfig) error

	// CertificateAutoRotation manages kubelet certificate auto-rotation configuration.
	CertificateAutoRotation(config SystemCertAutoRotationConfig) error
}

// SystemDumpConfig holds parameters for the dump operation.
type SystemDumpConfig struct {
	OutputDir    string
	SkipOpenDump bool
	ShowOutput   bool
	Nodes        string
}

// SystemUpgradeConfig holds parameters for the upgrade operation.
type SystemUpgradeConfig struct {
	PackagePath        string
	ConfigFile         string
	Proxy              string
	BackupDir          string
	AdditionalHooksDir string
	// NodeName identifies a specific worker node to upgrade (requires NodePackagePath).
	NodeName string
	// NodePackagePath is the path to the node package zip used for an offline node upgrade (requires NodeName).
	NodePackagePath string
	SkipImages      bool
	SkipResources   bool
	ForceOnline     bool
	Force           bool
	ShowOutput      bool
	DeletePackage   bool
}

// SystemPackageConfig holds parameters for the package operation.
type SystemPackageConfig struct {
	OutputDir         string
	PackageName       string
	ForDeltaPackage   bool
	BasePackagePath   string
	TargetPackagePath string
	NodePackage       bool
	OS                string
	Architecture      string
	Proxy             string
	IncludeGPU        bool
	ShowOutput        bool
}

// SystemResetConfig holds parameters for the reset operation.
type SystemResetConfig struct {
	ShowOutput bool
}

// SystemResetNetworkConfig holds parameters for network reset.
type SystemResetNetworkConfig struct {
	AdditionalHooksDir string
	Force              bool
	ShowOutput         bool
}

// SystemCompactConfig holds parameters for the compact operation.
type SystemCompactConfig struct {
	NoRestart  bool
	Yes        bool
	ShowOutput bool
}

// SystemBackupConfig holds parameters for the backup operation.
type SystemBackupConfig struct {
	BackupFile         string
	AdditionalHooksDir string
	SkipImages         bool
	SkipPVs            bool
	ShowOutput         bool
}

// SystemRestoreConfig holds parameters for the restore operation.
type SystemRestoreConfig struct {
	BackupFile         string
	AdditionalHooksDir string
	ErrorOnFailure     bool
	ShowOutput         bool
}

// SystemCertRenewConfig holds parameters for certificate renewal.
type SystemCertRenewConfig struct {
	Force      bool
	ShowOutput bool
}

// SystemCertAutoRotationConfig holds parameters for kubelet certificate auto-rotation management.
type SystemCertAutoRotationConfig struct {
	Enable     bool
	Disable    bool
	ShowStatus bool
	ShowOutput bool
}
