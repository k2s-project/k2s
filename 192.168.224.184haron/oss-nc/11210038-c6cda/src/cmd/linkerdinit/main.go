// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

// linkerdinit replaces the upstream linkerd2-proxy-init inside the Windows
// Linkerd data-plane image. Upstream only configures Linux iptables, while on
// Windows nodes K2s programs the equivalent HNS L4WFPPROXY endpoint policy from
// its CNI plugin. This binary therefore performs no networking changes; it only
// verifies that the arguments the proxy injector passes still match what the CNI
// programmed, and then exits successfully.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/k2s-project/k2s/internal/cli"
	ve "github.com/k2s-project/k2s/internal/version"
)

const cliName = "linkerdinit"

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "[LinkerdInit] ERROR: %v\n", err)
		os.Exit(int(cli.ExitCodeFailure))
	}
}

func run(argv []string, out io.Writer) error {
	flags, err := parseArgs(argv)
	if err != nil {
		return err
	}

	if _, ok := flags["version"]; ok {
		ve.GetVersion().Print(cliName)
		return nil
	}

	if err := verifyContract(flags); err != nil {
		return err
	}

	fmt.Fprintf(out, "[LinkerdInit] Redirection contract verified: inbound %s, outbound %s, inbound exceptions %s, outbound exceptions %s\n",
		inboundProxyPort, outboundProxyPort, inboundPortExceptions, outboundPortExceptions)
	fmt.Fprintln(out, "[LinkerdInit] Windows traffic redirection is programmed by the K2s CNI as an HNS L4WFPPROXY policy; nothing to do here.")

	return nil
}
