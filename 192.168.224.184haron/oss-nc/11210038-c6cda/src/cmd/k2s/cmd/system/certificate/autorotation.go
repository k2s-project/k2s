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

const (
	autoRotateEnableFlagName  = "enable"
	autoRotateDisableFlagName = "disable"
	autoRotateStatusFlagName  = "status"
)

var (
	autoRotationExample = `
# Show current kubelet certificate auto-rotation status
k2s system certificate autorotation --status
k2s system certificate autorotation -s

# Enable kubelet certificate auto-rotation
k2s system certificate autorotation --enable
k2s system certificate autorotation -e

# Disable kubelet certificate auto-rotation
k2s system certificate autorotation --disable
k2s system certificate autorotation -d
	`

	autoRotationCmd = &cobra.Command{
		Use:   "autorotation",
		Short: "Manages kubelet certificate auto-rotation (control-plane node only)",
		Long: `
Manages the kubelet certificate auto-rotation configuration.

When enabled, the kubelet automatically requests a new certificate before the current
one expires (at ~80% of its lifetime). The kubelet monitors its own certificate,
generates a new CSR, and the kube-controller-manager approves and issues the new
certificate automatically — no administrator intervention required.

Use --status to inspect the current auto-rotation state.
Use --enable / --disable to turn the feature on or off.

Note: The 'k2s system certificate renew' command handles control-plane certificates
(kube-apiserver, etcd, etc.) and is a separate operation from kubelet auto-rotation.
		`,
		Example: autoRotationExample,
		RunE:    manageAutoRotation,
	}
)

func init() {
	autoRotationCmd.Flags().BoolP(autoRotateEnableFlagName, "e", false, "enable kubelet certificate auto-rotation")
	autoRotationCmd.Flags().BoolP(autoRotateDisableFlagName, "d", false, "disable kubelet certificate auto-rotation")
	autoRotationCmd.Flags().BoolP(autoRotateStatusFlagName, "s", false, "show current kubelet certificate auto-rotation status")
	autoRotationCmd.MarkFlagsMutuallyExclusive(autoRotateEnableFlagName, autoRotateDisableFlagName, autoRotateStatusFlagName)
	autoRotationCmd.Flags().SortFlags = false
	autoRotationCmd.Flags().PrintDefaults()
}

func manageAutoRotation(cmd *cobra.Command, args []string) error {
	enableFlag, err := strconv.ParseBool(cmd.Flags().Lookup(autoRotateEnableFlagName).Value.String())
	if err != nil {
		return err
	}
	disableFlag, err := strconv.ParseBool(cmd.Flags().Lookup(autoRotateDisableFlagName).Value.String())
	if err != nil {
		return err
	}
	statusFlag, err := strconv.ParseBool(cmd.Flags().Lookup(autoRotateStatusFlagName).Value.String())
	if err != nil {
		return err
	}
	showLogs, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}

	// default to status when no flag provided
	if !enableFlag && !disableFlag {
		statusFlag = true
	}

	if enableFlag {
		pterm.Println("🔄 Enabling kubelet certificate auto-rotation...")
	} else if disableFlag {
		pterm.Println("🔒 Disabling kubelet certificate auto-rotation...")
	} else {
		pterm.Println("🔍 Checking kubelet certificate auto-rotation status...")
	}

	cmdSession := common.StartCmdSession(cmd.CommandPath())

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)

	if err := context.Providers().System.CertificateAutoRotation(provider.SystemCertAutoRotationConfig{
		Enable:     enableFlag,
		Disable:    disableFlag,
		ShowStatus: statusFlag,
		ShowOutput: showLogs,
	}); err != nil {
		return err
	}

	cmdSession.Finish()

	return nil
}

