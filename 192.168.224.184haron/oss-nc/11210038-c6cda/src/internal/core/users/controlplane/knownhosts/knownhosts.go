// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package knownhosts

import (
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/contracts/users"
	k_host "github.com/k2s-project/k2s/internal/host"
	k_os "github.com/k2s-project/k2s/internal/os"
)

type KnownHostsCopier struct {
	sshConfig *config.SSHConfig
}

const (
	fileLineSeparator  = "\n"
	knownHostsFileName = "known_hosts"
)

func NewKnownHostsCopier(sshConfig *config.SSHConfig) *KnownHostsCopier {
	return &KnownHostsCopier{
		sshConfig: sshConfig,
	}
}

func (k *KnownHostsCopier) CopyHostEntries(host string, user *users.OSUser) error {
	slog.Debug("Copying host entries from current known_hosts file to known_hosts files of new user", "host", host, "target-user", user.Name())

	sourcePath := filepath.Join(k.sshConfig.CurrentDir(), knownHostsFileName)

	hostEntries, err := findHostEntries(sourcePath, host)
	if err != nil {
		return fmt.Errorf("failed to find host entries for host '%s' in '%s': %w", host, sourcePath, err)
	}
	if len(hostEntries) < 1 {
		return fmt.Errorf("no host entries found for host '%s' in '%s'", host, sourcePath)
	}

	targetDir := k_host.ResolveTildePrefix(k.sshConfig.RelativeDir(), user.HomeDir())
	targetPath := filepath.Join(targetDir, knownHostsFileName)

	if k_os.PathExists(targetPath) {
		slog.Debug("Target file already existing, adding host entries", "path", targetPath)
		if err := updateFile(targetPath, host, hostEntries); err != nil {
			return fmt.Errorf("failed to add host entries to target file '%s': %w", targetPath, err)
		}
		return nil
	}

	if err := os.MkdirAll(targetDir, fs.ModePerm); err != nil {
		return fmt.Errorf("failed to create target directory '%s': %w", targetDir, err)
	}

	slog.Debug("Target file not existing, creating it with host entries", "path", targetPath)
	if err := writeToFile(targetPath, hostEntries); err != nil {
		return fmt.Errorf("failed to create target file '%s' with host entries: %w", targetPath, err)
	}

	slog.Debug("Host entries copied from current user to new user", "source-path", sourcePath, "target-path", targetPath)
	return nil
}

func findHostEntries(path, host string) (hostEntries []string, err error) {
	slog.Debug("Looking for host in known_hosts file", "path", path, "host", host)

	bytes, err := os.ReadFile(path)
	if err != nil {
		return hostEntries, fmt.Errorf("failed to read known_hosts file '%s': %w", path, err)
	}

	knownHosts := strings.SplitSeq(string(bytes), fileLineSeparator)

	for entry := range knownHosts {
		if !strings.HasPrefix(entry, host) {
			continue
		}
		slog.Debug("Found host entry in known_hosts", "entry", entry)
		hostEntries = append(hostEntries, entry)
	}

	slog.Debug("Host entries found", "count", len(hostEntries), "host", host)
	return
}

func updateFile(path, host string, hostEntries []string) error {
	slog.Debug("Updating known_hosts file with host entries", "path", path, "host", host)

	bytes, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read known_hosts file '%s': %w", path, err)
	}

	resultEntries := []string{}

	existingEntries := strings.SplitSeq(string(bytes), fileLineSeparator)

	for entry := range existingEntries {
		if strings.HasPrefix(entry, host) || entry == "" {
			continue
		}
		resultEntries = append(resultEntries, entry)
	}
	resultEntries = append(resultEntries, hostEntries...)

	if err := writeToFile(path, resultEntries); err != nil {
		return fmt.Errorf("failed to update known_hosts file with host entries '%s': %w", path, err)
	}

	slog.Debug("Known_hosts file updated with new host entries", "path", path, "host", host, "count", len(hostEntries))
	return nil
}

func writeToFile(path string, hostEntries []string) error {
	slog.Debug("Writing host entries to known_hosts file", "path", path, "count", len(hostEntries))

	lines := strings.Join(hostEntries, fileLineSeparator) + fileLineSeparator

	if err := os.WriteFile(path, []byte(lines), fs.ModePerm); err != nil {
		return fmt.Errorf("failed to write host entries to known_hosts file '%s': %w", path, err)
	}

	slog.Debug("Host entries written to known_hosts file", "path", path, "count", len(hostEntries))
	return nil
}
