// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"bufio"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	kjson "github.com/k2s-project/k2s/internal/json"
	linuxlifecycle "github.com/k2s-project/k2s/internal/linux/lifecycle"
)

// linuxWindowsWorkerStateFile is written by the native lifecycle when it
// provisions the managed Windows worker (see lib/modules/linux/node/windows-worker.sh).
const linuxWindowsWorkerStateFile = "windows-worker.json"

type linuxWindowsWorkerState struct {
	Name string `json:"name"`
}

type linuxSystemProvider struct {
	installDir string
	configDir  string
}

var linuxRunCombinedOutput = func(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

var linuxExecuteLifecycle = linuxlifecycle.Execute

var linuxConfirm = func(prompt string) bool {
	fmt.Print(prompt)
	answer, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.TrimSpace(answer) == "y"
}

func newLinuxSystemProvider(cfg ProviderConfig) *linuxSystemProvider {
	return &linuxSystemProvider{installDir: cfg.InstallDir, configDir: cfg.ConfigDir}
}

func (p *linuxSystemProvider) Dump(cfg SystemDumpConfig) error {
	slog.Info("[System] Dumping cluster info")
	args := []string{"cluster-info", "dump"}
	if cfg.OutputDir != "" {
		args = append(args, "--output-directory="+cfg.OutputDir)
	}
	cmd := exec.Command("kubectl", args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Run()
}

func (p *linuxSystemProvider) Upgrade(_ SystemUpgradeConfig) error {
	return NotSupportedError("system upgrade",
		"cluster upgrade on Linux hosts is not yet implemented; use package-based reinstall instead")
}

func (p *linuxSystemProvider) Package(_ SystemPackageConfig) error {
	return NotSupportedError("system package",
		"offline packaging on Linux hosts is not yet implemented")
}

func (p *linuxSystemProvider) Reset(_ SystemResetConfig) error {
	// Resetting the cluster on Linux is done via the native uninstall process, similar to Windows system reset flow.
	slog.Info("[System] Resetting cluster via native Linux uninstall")
	if err := linuxlifecycle.Execute("Uninstall", linuxlifecycle.Operation{
		InstallDir: p.installDir,
		ConfigDir:  p.configDir,
		LinuxOnly:  true,
	}); err != nil {
		return fmt.Errorf("native Linux uninstall failed: %w", err)
	}
	return nil
}

func (p *linuxSystemProvider) ResetNetwork(_ SystemResetNetworkConfig) error {
	return p.resetNetwork()
}

func (p *linuxSystemProvider) resetNetwork() error {
	slog.Info("[System] Resetting network interfaces")
	var failures []string

	cleanup := []struct {
		command        string
		args           []string
		ignoreNotFound bool
		display        string
	}{
		{command: "ip", args: []string{"link", "delete", "cni0"}, ignoreNotFound: true, display: "ip link delete cni0"},
		{command: "ip", args: []string{"link", "delete", "flannel.1"}, ignoreNotFound: true, display: "ip link delete flannel.1"},
		{command: "iptables", args: []string{"-F"}, display: "iptables -F"},
		{command: "iptables", args: []string{"-t", "nat", "-F"}, display: "iptables -t nat -F"},
		{command: "iptables", args: []string{"-X"}, display: "iptables -X"},
	}

	for _, step := range cleanup {
		output, err := linuxRunCombinedOutput(step.command, step.args...)
		if err == nil {
			continue
		}

		trimmedOutput := strings.TrimSpace(string(output))
		if step.ignoreNotFound && isLinuxLinkNotFound(trimmedOutput) {
			continue
		}

		if trimmedOutput == "" {
			failures = append(failures, fmt.Sprintf("%s: %v", step.display, err))
			continue
		}
		failures = append(failures, fmt.Sprintf("%s: %v (%s)", step.display, err, trimmedOutput))
	}

	if len(failures) > 0 {
		return fmt.Errorf("linux network cleanup failed: %s", strings.Join(failures, "; "))
	}

	return nil
}

func isLinuxLinkNotFound(output string) bool {
	return strings.Contains(output, "Cannot find device") || strings.Contains(output, "does not exist")
}

// Compact rewrites the QCOW2 disk of the managed Windows worker, the only VM
// on a Linux host, so that space freed inside the guest is returned to the host.
func (p *linuxSystemProvider) Compact(cfg SystemCompactConfig) error {
	if cfg.LinuxOnly {
		return NotSupportedError("system compact",
			"Linux-only setups on a Linux host have no VM disk to compact; the control plane runs natively on the host")
	}

	worker, err := readLinuxWindowsWorkerState(p.configDir)
	if err != nil {
		return err
	}

	if !cfg.Yes {
		output, err := linuxRunCombinedOutput("virsh", "domstate", worker.Name)
		if err == nil && strings.TrimSpace(string(output)) == "running" &&
			!linuxConfirm("The cluster must be stopped to compact the Windows worker disk. Stop cluster now? (y/n) ") {
			slog.Info("[System] Compaction cancelled by user")
			return nil
		}
	}

	return linuxExecuteLifecycle("Compact", linuxlifecycle.Operation{
		InstallDir: p.installDir,
		ConfigDir:  p.configDir,
		NoRestart:  cfg.NoRestart,
	})
}

func readLinuxWindowsWorkerState(configDir string) (*linuxWindowsWorkerState, error) {
	state, err := kjson.FromFile[linuxWindowsWorkerState](filepath.Join(configDir, linuxWindowsWorkerStateFile))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, NotSupportedError("system compact",
				"no managed Windows worker is installed, so there is no VM disk to compact")
		}
		return nil, fmt.Errorf("cannot read the Windows worker state: %w", err)
	}
	if state == nil || state.Name == "" {
		return nil, fmt.Errorf("the Windows worker state in '%s' does not name the worker VM", configDir)
	}
	return state, nil
}

func (p *linuxSystemProvider) Backup(cfg SystemBackupConfig) error {
	return runLinuxSystemBackup(p.installDir, cfg)
}

func (p *linuxSystemProvider) Restore(_ SystemRestoreConfig) error {
	return NotSupportedError("system restore",
		"cluster restore on Linux hosts is not yet implemented")
}

func (p *linuxSystemProvider) CertificateRenew(_ SystemCertRenewConfig) error {
	slog.Info("[System] Renewing Kubernetes certificates")
	if err := exec.Command("kubeadm", "certs", "renew", "all").Run(); err != nil {
		return err
	}

	// Renew the clusterip-webhook certificate by restarting the deployment.
	// The init container generates a fresh certificate on each Pod start.
	slog.Info("[System] Renewing clusterip-webhook certificate")
	checkCmd := exec.Command("kubectl", "get", "deployment", "clusterip-webhook",
		"-n", "k2s-webhook", "--no-headers")
	if out, err := checkCmd.CombinedOutput(); err != nil {
		if exitErr, ok := errors.AsType[*exec.ExitError](err); ok && exitErr.ExitCode() == 1 {
			slog.Info("[System] clusterip-webhook deployment not found - skipping webhook cert renewal")
			return nil
		}
		slog.Warn("[System] Failed to check clusterip-webhook deployment - skipping webhook cert renewal",
			"error", err, "output", string(out))
		return nil
	}

	restartCmd := exec.Command("kubectl", "rollout", "restart",
		"deployment/clusterip-webhook", "-n", "k2s-webhook")
	if out, err := restartCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("failed to restart clusterip-webhook deployment: %w\n%s", err, out)
	}

	statusCmd := exec.Command("kubectl", "rollout", "status",
		"deployment/clusterip-webhook", "-n", "k2s-webhook", "--timeout=120s")
	if out, err := statusCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("clusterip-webhook deployment did not become ready: %w\n%s", err, out)
	}

	slog.Info("[System] clusterip-webhook certificate renewed successfully")
	return nil
}

func (p *linuxSystemProvider) CertificateAutoRotation(cfg SystemCertAutoRotationConfig) error {
	const kubeletConfigPath = "/var/lib/kubelet/config.yaml"

	// patchScript uses only sed/grep — no python3 dependency.
	// It creates a backup before patching and restores on failure.
	patchScript := func(value string) string {
		return fmt.Sprintf(`
set -euo pipefail
CONFIG="%s"
BACKUP="${CONFIG}.bak"
sudo cp "$CONFIG" "$BACKUP"
if sudo grep -q 'rotateCertificates' "$CONFIG"; then
    sudo sed -i 's/rotateCertificates:.*/rotateCertificates: %s/' "$CONFIG"
else
    echo 'rotateCertificates: %s' | sudo tee -a "$CONFIG" > /dev/null
fi
`, kubeletConfigPath, value, value)
	}

	if cfg.Enable {
		slog.Info("[System] Enabling kubelet certificate auto-rotation")
		cmd := exec.Command("bash", "-c", patchScript("true"))
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to enable rotateCertificates in kubelet config: %w\n%s", err, out)
		}
		slog.Info("[System] Restarting kubelet to apply auto-rotation setting")
		if out, err := exec.Command("systemctl", "restart", "kubelet").CombinedOutput(); err != nil {
			return fmt.Errorf("failed to restart kubelet: %w\n%s", err, out)
		}
		return nil
	}

	if cfg.Disable {
		slog.Info("[System] Disabling kubelet certificate auto-rotation")
		cmd := exec.Command("bash", "-c", patchScript("false"))
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("failed to disable rotateCertificates in kubelet config: %w\n%s", err, out)
		}
		slog.Info("[System] Restarting kubelet to apply auto-rotation setting")
		if out, err := exec.Command("systemctl", "restart", "kubelet").CombinedOutput(); err != nil {
			return fmt.Errorf("failed to restart kubelet: %w\n%s", err, out)
		}
		return nil
	}

	// status (default)
	slog.Info("[System] Checking kubelet certificate auto-rotation status")
	statusScript := fmt.Sprintf(`
CONFIG="%s"
if sudo grep -q 'rotateCertificates: true' "$CONFIG"; then
    echo "Kubelet certificate auto-rotation: enabled"
else
    echo "Kubelet certificate auto-rotation: disabled (or not set)"
fi
`, kubeletConfigPath)
	out, err := exec.Command("bash", "-c", statusScript).Output()
	if err != nil {
		return fmt.Errorf("failed to read kubelet config: %w", err)
	}
	slog.Info("[System] " + string(out))
	return nil
}
