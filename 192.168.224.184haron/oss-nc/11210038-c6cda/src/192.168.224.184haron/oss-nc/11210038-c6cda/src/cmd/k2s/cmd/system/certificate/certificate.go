// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package certificate

import "github.com/spf13/cobra"

var CertificateCmd = &cobra.Command{
	Use:   "certificate",
	Short: "Manage system certificates",
}

func init() {
	CertificateCmd.AddCommand(renewCmd)
	CertificateCmd.AddCommand(autoRotationCmd)
}
