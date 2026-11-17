// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"errors"
	"fmt"
	"regexp"
)

var (
	// countPattern matches a non-negative whole number, e.g. a CPU or restart count.
	countPattern = regexp.MustCompile(`^[0-9]+$`)

	// sizePattern matches a memory or disk size such as 6GB, 512MB or 1.5GB.
	sizePattern = regexp.MustCompile(`(?i)^[0-9]+(\.[0-9]+)?([KMGT]?B|[KMGT])?$`)

	// proxyPattern matches [scheme://][user[:password]@]host[:port][/]. The proxy is relayed to PowerShell and
	// to shell commands on the nodes, so characters with a meaning there (e.g. $ ; & ' " ` ( ) and whitespace)
	// are rejected; within credentials they have to be percent-encoded. Neither the user nor the host may start
	// with '-', so the value can never be mistaken for a command-line option.
	proxyPattern = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9+.-]*://)?` +
		`([A-Za-z0-9._~%][A-Za-z0-9._~%!*+,=-]*(:[A-Za-z0-9._~%!*+,=-]*)?@)?` +
		`([A-Za-z0-9][A-Za-z0-9._-]*|\[[0-9A-Fa-f:.]+\])` +
		`(:[0-9]{1,5})?/?$`)
)

// validateResourceValues ensures that the node resource values are plain numbers or sizes, since they are
// passed on unquoted to the setup scripts.
func validateResourceValues(config *InstallConfig) error {
	for i := range config.Nodes {
		node := &config.Nodes[i]

		if node.Resources.Cpu != "" && !countPattern.MatchString(node.Resources.Cpu) {
			return fmt.Errorf("invalid CPU count '%s' for node role '%s': expected a whole number", node.Resources.Cpu, node.Role)
		}

		sizes := []struct {
			name  string
			value string
		}{
			{"memory", node.Resources.Memory},
			{"minimum memory", node.Resources.MemoryMin},
			{"maximum memory", node.Resources.MemoryMax},
			{"disk size", node.Resources.Disk},
		}
		for _, size := range sizes {
			if size.value != "" && !sizePattern.MatchString(size.value) {
				return fmt.Errorf("invalid %s '%s' for node role '%s': expected format <number>[<unit>], e.g. 512MB or 6GB", size.name, size.value, node.Role)
			}
		}
	}

	return nil
}

// validateEnvValues ensures that environment values which are passed on unquoted to the setup scripts or to
// the nodes are well-formed.
func validateEnvValues(config *InstallConfig) error {
	if config.Env.RestartPostInstall != "" && !countPattern.MatchString(config.Env.RestartPostInstall) {
		return fmt.Errorf("invalid restartPostInstallCount '%s': expected a whole number", config.Env.RestartPostInstall)
	}

	return ValidateProxy(config.Env.Proxy)
}

// ValidateProxy returns an error if proxy is neither empty nor a proxy address of the form
// [scheme://][user[:password]@]host[:port].
func ValidateProxy(proxy string) error {
	if proxy == "" || proxyPattern.MatchString(proxy) {
		return nil
	}

	// the value is not part of the message, since it might contain credentials
	return errors.New("invalid proxy: expected format [scheme://][user[:password]@]host[:port], with special characters in user and password percent-encoded")
}
