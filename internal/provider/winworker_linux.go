// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package provider

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/host"
	"github.com/k2s-project/k2s/internal/output"
)

const (
	windowsWorkerStateFileName = "windows-worker.json"
	windowsWorkerKnownHostsRel = "ssh/windows-worker.known_hosts"
	defaultWindowsWorkerIP     = "172.19.1.101"
	defaultWindowsWorkerUser   = "remote"
	rootK2sSSHKeyPath          = "/root/.ssh/k2s/id_ed25519"
)

// cmdRunner abstracts external command execution (ssh, scp, kubectl) for unit testing.
type cmdRunner interface {
	Run(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error
}

type execCmdRunner struct{}

func (r *execCmdRunner) Run(ctx context.Context, name string, args []string, stdout, stderr io.Writer) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

// windowsWorkerState matches /var/lib/k2s/windows-worker.json.
type windowsWorkerState struct {
	Name    string `json:"name"`
	Network string `json:"network"`
	IP      string `json:"ip"`
	MAC     string `json:"mac"`
	Disk    string `json:"disk"`
	Proxy   string `json:"proxy"`
}

// sshConfig holds resolved SSH/SCP connection parameters for the Windows worker VM.
type sshConfig struct {
	User           string
	IP             string
	KeyPath        string
	KnownHostsPath string
}

// clusterNode represents a Kubernetes node in the cluster.
type clusterNode struct {
	Name           string
	OS             string
	IsControlPlane bool
}

// nodeTarget describes which nodes an image operation should target.
type nodeTarget struct {
	IncludeLinux    bool
	IncludeWindows  bool
	LinuxNodeName   string
	WindowsNodeName string
}

// winWorkerClient handles SSH/SCP communication, PowerShell execution, and node topology
// resolution for the KVM Windows worker VM on a Linux host.
type winWorkerClient struct {
	installDir   string
	configDir    string
	stdWriter    output.StreamWriter
	runner       cmdRunner
	stdoutWriter io.Writer
	stderrWriter io.Writer
	hostnameFn   func() (string, error)
	getenvFn     func(string) string
}

func newWinWorkerClient(installDir, configDir string, stdWriter output.StreamWriter) *winWorkerClient {
	return &winWorkerClient{
		installDir:   installDir,
		configDir:    configDir,
		stdWriter:    stdWriter,
		runner:       &execCmdRunner{},
		stdoutWriter: os.Stdout,
		stderrWriter: os.Stderr,
		hostnameFn:   os.Hostname,
		getenvFn:     os.Getenv,
	}
}

func (c *winWorkerClient) effectiveConfigDir() string {
	if c.configDir != "" {
		return c.configDir
	}
	return host.K2sConfigDir()
}

func (c *winWorkerClient) effectiveRunner() cmdRunner {
	if c.runner != nil {
		return c.runner
	}
	return &execCmdRunner{}
}

func (c *winWorkerClient) stdout() io.Writer {
	if c.stdoutWriter != nil {
		return c.stdoutWriter
	}
	return os.Stdout
}

func (c *winWorkerClient) stderr() io.Writer {
	if c.stderrWriter != nil {
		return c.stderrWriter
	}
	return os.Stderr
}

func (c *winWorkerClient) hostname() (string, error) {
	if c.hostnameFn != nil {
		return c.hostnameFn()
	}
	return os.Hostname()
}

func (c *winWorkerClient) getenv(key string) string {
	if c.getenvFn != nil {
		return c.getenvFn(key)
	}
	return os.Getenv(key)
}

func (c *winWorkerClient) isLinuxOnly() bool {
	return isLinuxOnlySetup(c.effectiveConfigDir())
}

// readWindowsWorkerState reads and parses <configDir>/windows-worker.json.
func readWindowsWorkerState(configDir string) (*windowsWorkerState, error) {
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	statePath := filepath.Join(configDir, windowsWorkerStateFileName)
	data, err := os.ReadFile(statePath)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", statePath, err)
	}
	var state windowsWorkerState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", statePath, err)
	}
	return &state, nil
}

// isLinuxOnlySetup checks <configDir>/setup.json for LinuxOnly. If setup.json is missing,
// unreadable, or omits LinuxOnly, it falls back to checking whether windows-worker.json exists.
func isLinuxOnlySetup(configDir string) bool {
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	if configDir != "" {
		setupPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
		if data, err := os.ReadFile(setupPath); err == nil {
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil {
				if val, ok := raw["LinuxOnly"]; ok {
					if b, ok := val.(bool); ok {
						return b
					}
				}
			}
		}

		workerPath := filepath.Join(configDir, windowsWorkerStateFileName)
		if info, err := os.Stat(workerPath); err == nil && !info.IsDir() {
			return false
		}
	}
	return true
}

func isReadableFile(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

func (c *winWorkerClient) resolveSSHConfig() sshConfig {
	cfg := sshConfig{
		User: defaultWindowsWorkerUser,
		IP:   defaultWindowsWorkerIP,
	}

	configDir := c.effectiveConfigDir()
	if state, err := readWindowsWorkerState(configDir); err == nil && strings.TrimSpace(state.IP) != "" {
		cfg.IP = strings.TrimSpace(state.IP)
	}

	if c.installDir != "" {
		if k2sCfg, err := config.ReadK2sConfig(c.installDir); err == nil {
			keyPath := k2sCfg.Host().SshConfig().CurrentPrivateKeyPath()
			if isReadableFile(keyPath) {
				cfg.KeyPath = keyPath
			}
		}
	}
	if cfg.KeyPath == "" && isReadableFile(rootK2sSSHKeyPath) {
		cfg.KeyPath = rootK2sSSHKeyPath
	}
	if cfg.KeyPath == "" {
		if home := c.getenv("HOME"); home != "" {
			candidate := filepath.Join(home, ".ssh", "k2s", "id_ed25519")
			if isReadableFile(candidate) {
				cfg.KeyPath = candidate
			}
		}
	}

	if configDir != "" {
		khPath := filepath.Join(configDir, filepath.FromSlash(windowsWorkerKnownHostsRel))
		if isReadableFile(khPath) {
			cfg.KnownHostsPath = khPath
		}
	}

	return cfg
}

func (s sshConfig) commonArgs() []string {
	var args []string
	if s.KeyPath != "" {
		args = append(args, "-i", s.KeyPath)
	}
	args = append(args,
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
	)
	if s.KnownHostsPath != "" {
		args = append(args,
			"-o", "StrictHostKeyChecking=yes",
			"-o", "UserKnownHostsFile="+s.KnownHostsPath,
		)
	} else {
		args = append(args,
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
		)
	}
	return args
}

func (s sshConfig) target() string {
	return fmt.Sprintf("%s@%s", s.User, s.IP)
}

func (s sshConfig) sshArgs(remoteCmd string) []string {
	args := s.commonArgs()
	args = append(args, s.target(), remoteCmd)
	return args
}

func toSCPWindowsPath(winPath string) string {
	return strings.ReplaceAll(winPath, "\\", "/")
}

func (s sshConfig) scpToArgs(localPath, remoteWinPath string) []string {
	args := s.commonArgs()
	args = append(args, localPath, fmt.Sprintf("%s:%s", s.target(), toSCPWindowsPath(remoteWinPath)))
	return args
}

func (s sshConfig) scpFromArgs(remoteWinPath, localPath string) []string {
	args := s.commonArgs()
	args = append(args, fmt.Sprintf("%s:%s", s.target(), toSCPWindowsPath(remoteWinPath)), localPath)
	return args
}

// encodePowerShellUTF16LE encodes a PowerShell script as UTF-16LE base64 for -EncodedCommand.
func encodePowerShellUTF16LE(script string) string {
	encoded := utf16.Encode([]rune(script))
	buf := make([]byte, len(encoded)*2)
	for i, u := range encoded {
		binary.LittleEndian.PutUint16(buf[i*2:], u)
	}
	return base64.StdEncoding.EncodeToString(buf)
}

// psSingleQuote safely wraps a string in PowerShell single quotes.
func psSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// winTempDir generates a unique temporary directory path on the Windows worker VM.
func winTempDir(prefix string) string {
	cleanPrefix := strings.TrimSpace(prefix)
	if cleanPrefix == "" {
		cleanPrefix = "k2s"
	}
	var b [8]byte
	var suffix string
	if _, err := rand.Read(b[:]); err == nil {
		suffix = fmt.Sprintf("%x", b[:])
	} else {
		suffix = fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return fmt.Sprintf(`C:\ProgramData\K2s\tmp\%s-%s`, cleanPrefix, suffix)
}

// runWindowsPowerShell executes a PowerShell script on the Windows worker VM via SSH
// using UTF-16LE -EncodedCommand.
func (c *winWorkerClient) runWindowsPowerShell(ctx context.Context, script string, showOutput bool) (string, error) {
	wrapped := "$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n" + script
	b64 := encodePowerShellUTF16LE(wrapped)
	remoteCmd := "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + b64

	cfg := c.resolveSSHConfig()
	args := cfg.sshArgs(remoteCmd)

	var stdoutBuf, stderrBuf bytes.Buffer
	var stdoutW io.Writer = &stdoutBuf
	var stderrW io.Writer = &stderrBuf
	if showOutput {
		stdoutW = io.MultiWriter(&stdoutBuf, c.stdout())
		stderrW = io.MultiWriter(&stderrBuf, c.stderr())
	}

	err := c.effectiveRunner().Run(ctx, "ssh", args, stdoutW, stderrW)
	out := strings.TrimSpace(strings.ReplaceAll(stdoutBuf.String(), "\r", ""))
	if err != nil {
		errOut := strings.TrimSpace(strings.ReplaceAll(stderrBuf.String(), "\r", ""))
		if errOut != "" {
			return out, fmt.Errorf("Windows PowerShell command failed: %w: %s", err, errOut)
		}
		if out != "" {
			return out, fmt.Errorf("Windows PowerShell command failed: %w: %s", err, out)
		}
		return out, fmt.Errorf("Windows PowerShell command failed: %w", err)
	}
	return out, nil
}

// scpToWindows copies a local file on the Linux host to a path on the Windows worker VM.
func (c *winWorkerClient) scpToWindows(ctx context.Context, localPath, remoteWinPath string) error {
	cfg := c.resolveSSHConfig()
	args := cfg.scpToArgs(localPath, remoteWinPath)

	var stdoutBuf, stderrBuf bytes.Buffer
	err := c.effectiveRunner().Run(ctx, "scp", args, &stdoutBuf, &stderrBuf)
	if err != nil {
		errOut := strings.TrimSpace(strings.ReplaceAll(stderrBuf.String(), "\r", ""))
		if errOut != "" {
			return fmt.Errorf("scp to Windows failed: %w: %s", err, errOut)
		}
		return fmt.Errorf("scp to Windows failed: %w", err)
	}
	return nil
}

// scpFromWindows copies a file from the Windows worker VM to a local path on the Linux host.
func (c *winWorkerClient) scpFromWindows(ctx context.Context, remoteWinPath, localPath string) error {
	cfg := c.resolveSSHConfig()
	args := cfg.scpFromArgs(remoteWinPath, localPath)

	var stdoutBuf, stderrBuf bytes.Buffer
	err := c.effectiveRunner().Run(ctx, "scp", args, &stdoutBuf, &stderrBuf)
	if err != nil {
		errOut := strings.TrimSpace(strings.ReplaceAll(stderrBuf.String(), "\r", ""))
		if errOut != "" {
			return fmt.Errorf("scp from Windows failed: %w: %s", err, errOut)
		}
		return fmt.Errorf("scp from Windows failed: %w", err)
	}
	return nil
}

type kubectlNodeList struct {
	Items []struct {
		Metadata struct {
			Name   string            `json:"name"`
			Labels map[string]string `json:"labels"`
		} `json:"metadata"`
		Status struct {
			NodeInfo struct {
				OperatingSystem string `json:"operatingSystem"`
			} `json:"nodeInfo"`
		} `json:"status"`
	} `json:"items"`
}

func (c *winWorkerClient) kubectlNodesArgs() []string {
	args := []string{"get", "nodes", "-o", "json"}
	if c.getenv("KUBECONFIG") == "" {
		for _, candidate := range []string{"/etc/kubernetes/admin.conf", "/etc/kubernetes/super-admin.conf"} {
			if isReadableFile(candidate) {
				args = append([]string{"--kubeconfig", candidate}, args...)
				break
			}
		}
	}
	return args
}

func (c *winWorkerClient) discoverClusterNodes(ctx context.Context) ([]clusterNode, error) {
	var stdoutBuf, stderrBuf bytes.Buffer
	err := c.effectiveRunner().Run(ctx, "kubectl", c.kubectlNodesArgs(), &stdoutBuf, &stderrBuf)
	if err != nil {
		errOut := strings.TrimSpace(stderrBuf.String())
		if errOut != "" {
			return nil, fmt.Errorf("kubectl get nodes failed: %w: %s", err, errOut)
		}
		return nil, fmt.Errorf("kubectl get nodes failed: %w", err)
	}

	var list kubectlNodeList
	if err := json.Unmarshal(stdoutBuf.Bytes(), &list); err != nil {
		return nil, fmt.Errorf("parsing kubectl nodes output: %w", err)
	}

	nodes := make([]clusterNode, 0, len(list.Items))
	for _, item := range list.Items {
		nodeOS := strings.ToLower(strings.TrimSpace(item.Status.NodeInfo.OperatingSystem))
		if nodeOS == "" {
			nodeOS = strings.ToLower(strings.TrimSpace(item.Metadata.Labels["kubernetes.io/os"]))
		}
		_, isCP := item.Metadata.Labels["node-role.kubernetes.io/control-plane"]
		if !isCP {
			_, isCP = item.Metadata.Labels["node-role.kubernetes.io/master"]
		}
		nodes = append(nodes, clusterNode{
			Name:           item.Metadata.Name,
			OS:             nodeOS,
			IsControlPlane: isCP,
		})
	}
	return nodes, nil
}

// discoverNodes resolves the Linux control-plane node name and (when not LinuxOnly)
// the Windows worker node name from Kubernetes, with local/SSH fallbacks.
func (c *winWorkerClient) discoverNodes(ctx context.Context) (linuxNodeName string, windowsNodeName string, err error) {
	nodes, kErr := c.discoverClusterNodes(ctx)
	if kErr != nil {
		slog.Debug("[WinWorker] kubectl node discovery failed, using fallbacks", "error", kErr)
	} else {
		for _, n := range nodes {
			switch n.OS {
			case "linux":
				if linuxNodeName == "" || n.IsControlPlane {
					linuxNodeName = n.Name
				}
			case "windows":
				if windowsNodeName == "" {
					windowsNodeName = n.Name
				}
			}
		}
	}

	if linuxNodeName == "" {
		if h, hErr := c.hostname(); hErr == nil && strings.TrimSpace(h) != "" {
			linuxNodeName = strings.ToLower(strings.TrimSpace(h))
		} else {
			linuxNodeName = "linux"
		}
	}

	if !c.isLinuxOnly() && windowsNodeName == "" {
		if out, sshErr := c.runWindowsPowerShell(ctx, "$env:COMPUTERNAME.ToLower()", false); sshErr == nil && out != "" {
			windowsNodeName = strings.ToLower(strings.TrimSpace(out))
		} else {
			if sshErr != nil {
				slog.Debug("[WinWorker] Windows node name SSH fallback failed", "error", sshErr)
			}
			windowsNodeName = "windows"
		}
	}

	return linuxNodeName, windowsNodeName, nil
}

// resolveNodeTarget resolves --node/--nodes and --windows flags into concrete node targets.
func (c *winWorkerClient) resolveNodeTarget(ctx context.Context, requestedNodes []string, windowsFlag bool, defaultAll bool) (*nodeTarget, error) {
	linuxOnly := c.isLinuxOnly()
	linuxName, winName, err := c.discoverNodes(ctx)
	if err != nil {
		return nil, err
	}

	target := &nodeTarget{
		LinuxNodeName:   linuxName,
		WindowsNodeName: winName,
	}

	var nonEmptyRequested []string
	for _, raw := range requestedNodes {
		if trimmed := strings.TrimSpace(raw); trimmed != "" {
			nonEmptyRequested = append(nonEmptyRequested, trimmed)
		}
	}

	if len(nonEmptyRequested) > 0 {
		for _, req := range nonEmptyRequested {
			lower := strings.ToLower(req)
			isLinuxMatch := lower == strings.ToLower(linuxName) || lower == "linux" || lower == "kubemaster"
			isWinAlias := lower == "windows" || lower == "k2s-win-worker"
			isWinMatch := !linuxOnly && ((winName != "" && lower == strings.ToLower(winName)) || isWinAlias)

			if linuxOnly && isWinAlias {
				return nil, fmt.Errorf("Windows node %q is not available in a Linux-only installation", req)
			}
			if !isLinuxMatch && !isWinMatch {
				if linuxOnly {
					return nil, fmt.Errorf("unknown node %q; available node: %s", req, linuxName)
				}
				return nil, fmt.Errorf("unknown node %q; available nodes: %s, %s", req, linuxName, winName)
			}
			if isLinuxMatch {
				target.IncludeLinux = true
			}
			if isWinMatch {
				target.IncludeWindows = true
			}
		}

		if windowsFlag {
			if linuxOnly {
				return nil, errors.New("--windows is not supported on a Linux-only installation")
			}
			if target.IncludeLinux && !target.IncludeWindows {
				return nil, fmt.Errorf("cannot combine --windows with Linux-only node selection (%s)", strings.Join(nonEmptyRequested, ", "))
			}
			target.IncludeLinux = false
			target.IncludeWindows = true
		}

		return target, nil
	}

	if windowsFlag {
		if linuxOnly {
			return nil, errors.New("--windows is not supported on a Linux-only installation")
		}
		target.IncludeLinux = false
		target.IncludeWindows = true
		return target, nil
	}

	target.IncludeLinux = true
	if defaultAll {
		target.IncludeWindows = !linuxOnly
	}
	return target, nil
}
