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
	"path/filepath"
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

func kubeadmJoinCommand(tokenCommand string) string {
	return strings.TrimSpace(tokenCommand) + " --cri-socket unix:///run/crio/crio.sock"
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

func (p *linuxNodeProvider) Rename(cfg NodeRenameConfig) error {
	if _, err := cfg.Validated(); err != nil {
		return err
	}
	return NotSupportedError("node rename", "worker identity repair is currently available only from a Windows K2s host")
}

// Add joins a Debian 13 worker node (amd64 or arm64) to the cluster that runs on this host. The
// work is done by lib/scripts/linux/debian/worker/bare-metal/Add.sh, the Linux counterpart of the
// Windows bare-metal Add.ps1. Only offline node packages are supported on this path.
func (p *linuxNodeProvider) Add(cfg NodeAddConfig) error {
	if cfg.IpAddress == "" {
		return errors.New("--ip-addr is required to add a node")
	}
	if cfg.UserName == "" {
		return errors.New("--username is required to add a node")
	}
	if cfg.NodePackagePath == "" {
		return NotSupportedError("node add without --node-package", "the Linux host adds nodes from an offline node package; build one with 'k2s system package --node-package'")
	}

	script := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "worker", "bare-metal", "Add.sh")
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("node add script not found: %w", err)
	}

	slog.Info("[Node] Adding node", "ip", cfg.IpAddress, "user", cfg.UserName, "package", cfg.NodePackagePath)
	cmd := exec.Command("bash", script,
		"--ip-address", cfg.IpAddress,
		"--user", cfg.UserName,
		"--node-package", cfg.NodePackagePath,
		"--install-dir", p.installDir,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("adding node %s failed: %w", cfg.IpAddress, err)
	}
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
