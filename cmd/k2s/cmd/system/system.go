// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package system

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/backup"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/certificate"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/check"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/compact"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/dump"
	systempackage "github.com/k2s-project/k2s/cmd/k2s/cmd/system/package"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/proxy"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/reset"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/restore"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/upgrade"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/system/users"
	"github.com/spf13/cobra"
)

var SystemCmd = &cobra.Command{
	Use:   "system",
	Short: "Performs system-related tasks",
}

func init() {
	SystemCmd.AddCommand(dump.DumpCmd)
	SystemCmd.AddCommand(upgrade.UpgradeCmd)
	SystemCmd.AddCommand(reset.ResetCmd)
	SystemCmd.AddCommand(systempackage.PackageCmd)
	SystemCmd.AddCommand(users.NewCommand())
	SystemCmd.AddCommand(certificate.CertificateCmd)
	SystemCmd.AddCommand(proxy.ProxyCmd)
	SystemCmd.AddCommand(backup.SystemBackupCmd)
	SystemCmd.AddCommand(restore.SystemRestoreCmd)
	SystemCmd.AddCommand(compact.CompactCmd)
	SystemCmd.AddCommand(check.CheckCmd)
}
