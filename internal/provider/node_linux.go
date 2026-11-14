// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
)

type linuxNodeProvider struct {
	installDir string
}

func newLinuxNodeProvider(cfg ProviderConfig) *linuxNodeProvider {
	return &linuxNodeProvider{installDir: cfg.InstallDir}
}

// sshCmdToNode runs command on the target node (identified by user/ip) via SSH,
// unlike sshCmd which always targets the fixed Windows worker VM.
func sshCmdToNode(user, ip, command string) (string, error) {
	cmd := exec.Command("ssh",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "ConnectTimeout=10",
	)
	if identityFile := os.Getenv("K2S_SSH_IDENTITY_FILE"); identityFile != "" {
		cmd.Args = append(cmd.Args, "-i", identityFile, "-o", "IdentitiesOnly=yes")
	}
	if knownHostsFile := os.Getenv("K2S_SSH_KNOWN_HOSTS_FILE"); knownHostsFile != "" {
		cmd.Args = append(cmd.Args, "-o", "UserKnownHostsFile="+knownHostsFile)
	}
	cmd.Args = append(cmd.Args, fmt.Sprintf("%s@%s", user, ip), command)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && len(exitErr.Stderr) > 0 {
			return string(out), fmt.Errorf("SSH command failed: %w: %s", err, string(exitErr.Stderr))
		}
		return string(out), fmt.Errorf("SSH command failed: %w: %s", err, string(out))
	}
	return string(out), nil
}

// normalizeArch maps 'uname -m' output to Go-style architecture names, matching the
// normalization already used for the control-plane in install-cli-tools.sh.
func normalizeArch(unameM string) string {
	switch strings.TrimSpace(unameM) {
	case "x86_64":
		return "amd64"
	case "aarch64":
		return "arm64"
	default:
		return strings.TrimSpace(unameM)
	}
}

// assertSupportedNodeArchitecture fails fast if the target node's architecture/distro
// combination is not supported, before any provisioning is attempted. Only arm64 Debian
// external nodes are supported in addition to amd64.
func assertSupportedNodeArchitecture(user, ip string) error {
	unameOut, err := sshCmdToNode(user, ip, "uname -m")
	if err != nil {
		return fmt.Errorf("failed to detect architecture on remote node: %w", err)
	}
	arch := normalizeArch(unameOut)
	if arch == "amd64" {
		return nil
	}
	if arch != "arm64" {
		return fmt.Errorf("unsupported external node architecture '%s'; supported architectures are amd64 and arm64", arch)
	}

	osIDOut, err := sshCmdToNode(user, ip, ". /etc/os-release 2>/dev/null; echo \"$ID\"")
	if err != nil {
		return fmt.Errorf("failed to detect distribution on remote node: %w", err)
	}
	osID := strings.ToLower(strings.TrimSpace(osIDOut))
	if osID != "debian" {
		return fmt.Errorf("unsupported architecture/distro combination: arch '%s' is only supported on Debian-family distributions, detected OS ID '%s'", arch, osID)
	}

	return nil
}

func (p *linuxNodeProvider) Add(cfg NodeAddConfig) error {
	slog.Info("[Node] Adding node", "ip", cfg.IpAddress, "user", cfg.UserName, "name", cfg.NodeName)

	if err := assertSupportedNodeArchitecture(cfg.UserName, cfg.IpAddress); err != nil {
		return err
	}

	// Generate join token on control plane
	output, err := exec.Command("kubeadm", "token", "create", "--print-join-command").Output()
	if err != nil {
		return fmt.Errorf("failed to create join token: %w", err)
	}
	joinCmd := strings.TrimSpace(string(output))

	// kubeadm join must run as root (it writes /etc/kubernetes, starts kubelet, etc.);
	// the SSH user is assumed to have passwordless sudo, matching every other
	// bare-metal provisioning path in this codebase (e.g. harden-node.sh re-execs
	// itself via sudo when not already root).
	_, err = sshCmdToNode(cfg.UserName, cfg.IpAddress, "sudo "+joinCmd)
	if err != nil {
		return fmt.Errorf("kubeadm join failed on remote node: %w", err)
	}

	slog.Info("[Node] Node added successfully")
	return nil
}

func (p *linuxNodeProvider) Remove(cfg NodeRemoveConfig) error {
	slog.Info("[Node] Removing node", "name", cfg.NodeName)

	// Drain the node
	if err := exec.Command("kubectl", "drain", cfg.NodeName, "--ignore-daemonsets", "--delete-emptydir-data", "--force").Run(); err != nil {
		slog.Warn("[Node] Drain failed (continuing with removal)", "error", err)
	}

	// Delete the node from the cluster
	if err := exec.Command("kubectl", "delete", "node", cfg.NodeName).Run(); err != nil {
		return fmt.Errorf("failed to delete node '%s': %w", cfg.NodeName, err)
	}

	slog.Info("[Node] Node removed", "name", cfg.NodeName)
	return nil
}
