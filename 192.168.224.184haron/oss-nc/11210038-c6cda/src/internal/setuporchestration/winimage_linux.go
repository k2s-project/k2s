// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package setuporchestration

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
)

const (
	// windowsWorkerQCOW2Name is the filename for the pre-built Windows worker disk image.
	windowsWorkerQCOW2Name = "WindowsWorker-Base.qcow2"

	// windowsNodeVHDXName is the legacy VHDX filename from the Windows packaging pipeline.
	windowsNodeVHDXName = "Kubenode-Base.vhdx"

	// winVMDiskName is the active disk image name for the running Windows worker VM.
	winVMDiskName = "k2s-win-worker.qcow2"
)

// PrepareWindowsImage prepares the Windows worker VM disk image.
// It looks for a pre-built QCOW2 first. If not found, it converts the VHDX
// base image to QCOW2 using qemu-img. The final image is placed in vmDataDir.
func PrepareWindowsImage(installDir, vmDataDir string, diskSizeGB int) (string, error) {
	slog.Info("[WinImage] Preparing Windows worker VM image",
		"installDir", installDir, "vmDataDir", vmDataDir, "diskSizeGB", diskSizeGB)

	// Ensure the VM data directory exists
	if err := os.MkdirAll(vmDataDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create VM data directory '%s': %w", vmDataDir, err)
	}

	destPath := filepath.Join(vmDataDir, winVMDiskName)

	// Check if the disk image already exists (e.g. from a previous install)
	if _, err := os.Stat(destPath); err == nil {
		slog.Info("[WinImage] Windows worker disk image already exists", "path", destPath)
		return destPath, nil
	}

	// Strategy 1: Use pre-built QCOW2 from offline package
	prebuiltQCOW2 := filepath.Join(installDir, "bin", windowsWorkerQCOW2Name)
	if _, err := os.Stat(prebuiltQCOW2); err == nil {
		slog.Info("[WinImage] Found pre-built QCOW2, copying to VM data dir", "src", prebuiltQCOW2)
		if err := copyFile(prebuiltQCOW2, destPath); err != nil {
			return "", fmt.Errorf("failed to copy pre-built QCOW2: %w", err)
		}
		if err := resizeDisk(destPath, diskSizeGB); err != nil {
			return "", fmt.Errorf("failed to resize disk image: %w", err)
		}
		return destPath, nil
	}

	// Strategy 2: Convert VHDX to QCOW2
	vhdxPath := filepath.Join(installDir, "bin", windowsNodeVHDXName)
	if _, err := os.Stat(vhdxPath); err == nil {
		slog.Info("[WinImage] Converting VHDX to QCOW2", "src", vhdxPath, "dst", destPath)
		if err := convertVHDXToQCOW2(vhdxPath, destPath); err != nil {
			return "", fmt.Errorf("VHDX to QCOW2 conversion failed: %w", err)
		}
		if err := resizeDisk(destPath, diskSizeGB); err != nil {
			return "", fmt.Errorf("failed to resize disk image: %w", err)
		}
		return destPath, nil
	}

	return "", fmt.Errorf("no Windows worker base image found (tried '%s' and '%s')", prebuiltQCOW2, vhdxPath)
}

// convertVHDXToQCOW2 converts a Hyper-V VHDX image to KVM QCOW2 format.
func convertVHDXToQCOW2(vhdxPath, qcow2Path string) error {
	// vpc format handles both VHD and VHDX
	return runCommand("qemu-img", "convert", "-f", "vpc", "-O", "qcow2", "-o", "compat=1.1", vhdxPath, qcow2Path)
}

// resizeDisk resizes a QCOW2 disk image to the specified size in GB.
func resizeDisk(imagePath string, sizeGB int) error {
	if sizeGB <= 0 {
		return nil
	}
	slog.Info("[WinImage] Resizing disk image", "path", imagePath, "sizeGB", sizeGB)
	return runCommand("qemu-img", "resize", imagePath, fmt.Sprintf("%dG", sizeGB))
}

// copyFile copies a file from src to dst.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read '%s': %w", src, err)
	}
	if err := os.WriteFile(dst, data, 0644); err != nil {
		return fmt.Errorf("write '%s': %w", dst, err)
	}
	return nil
}
