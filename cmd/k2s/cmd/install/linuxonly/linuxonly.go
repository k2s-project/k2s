// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package linuxonly

import (
	"errors"
	"fmt"

	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"
	"github.com/k2s-project/k2s/cmd/k2s/utils"
)

var ErrWslNotSupported = errors.New("linux-only in combination with WSL is currently not supported")

func BuildCmd(config *ic.InstallConfig) (cmd string, err error) {
	if config.Behavior.Wsl {
		return "", ErrWslNotSupported
	}

	controlPlaneNode, err := config.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return "", err
	}

	path := fmt.Sprintf("%s\\lib\\scripts\\windows\\linuxonly\\install\\install.ps1", utils.InstallDir())
	formattedPath := utils.FormatScriptFilePath(path)
	cmd = fmt.Sprintf("%s -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		formattedPath,
		controlPlaneNode.Resources.Cpu,
		controlPlaneNode.Resources.Memory,
		controlPlaneNode.Resources.Disk)

	if controlPlaneNode.Resources.DynamicMemory {
		cmd += " -EnableDynamicMemory"
		if controlPlaneNode.Resources.MemoryMin != "" {
			cmd += " -MasterVMMemoryMin " + controlPlaneNode.Resources.MemoryMin
		}
		if controlPlaneNode.Resources.MemoryMax != "" {
			cmd += " -MasterVMMemoryMax " + controlPlaneNode.Resources.MemoryMax
		}
	}

	if config.Env.Proxy != "" {
		cmd += " -Proxy " + utils.EscapeWithSingleQuotes(config.Env.Proxy)
	}
	if len(config.Env.NoProxy) > 0 {
		cmd += " -NoProxy " + utils.EscapeArrayWithSingleQuotes(config.Env.NoProxy)
	}
	if config.Env.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(config.Env.AdditionalHooksDir)
	}
	if config.Behavior.ShowOutput {
		cmd += " -ShowLogs"
	}
	if config.Behavior.SkipStart {
		cmd += " -SkipStart"
	}
	if config.Behavior.DeleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}
	if config.Behavior.ForceOnlineInstallation {
		cmd += " -ForceOnlineInstallation"
	}
	if config.Behavior.AppendLog {
		cmd += " -AppendLogFile"
	}
	return cmd, nil
}
