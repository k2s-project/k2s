// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package certificate

import (
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	"github.com/k2s-project/k2s/internal/provider"
)

var (
	example = `
# Trigger certificate renewal only when certificates are expired
k2s system certificate renew
# Trigger certificate renewal always
k2s system certificate renew --force
k2s system certificate renew -f
	`

	renewCmd = &cobra.Command{
		Use:   "renew",
		Short: "Renews Kubernetes certificates (control-plane node only)",
		Long: `
Determines if Kubernetes certificates have expired and renews them.
With the --force option, the certificate renewal is performed irrespective of their expiration status.
		`,
		Example: example,
		RunE:    renewCertificates,
	}
)

func init() {
	renewCmd.Flags().BoolP("force", "f", false, "force renewal of certificates")
	renewCmd.Flags().SortFlags = false
	renewCmd.Flags().PrintDefaults()
}

func renewCertificates(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🔑 Renewing Kubernetes certificates...")

	force, err := strconv.ParseBool(cmd.Flags().Lookup("force").Value.String())
	if err != nil {
		return err
	}

	showLogs, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	if err := context.Providers().System.CertificateRenew(provider.SystemCertRenewConfig{
		Force:      force,
		ShowOutput: showLogs,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}
