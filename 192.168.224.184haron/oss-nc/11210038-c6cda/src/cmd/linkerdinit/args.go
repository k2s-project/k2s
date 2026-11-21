// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"sort"
	"strings"
)

// flagSet holds the parsed linkerd2-proxy-init arguments keyed by flag name without dashes.
type flagSet map[string]string

// booleanFlags do not consume the following token when passed without "=".
var booleanFlags = map[string]struct{}{
	"ipv6":          {},
	"simulate":      {},
	"use-wait-flag": {},
	"w":             {},
	"version":       {},
	"help":          {},
	"h":             {},
}

// aliases maps the upstream shorthand flags to their long form.
var aliases = map[string]string{
	"p": "incoming-proxy-port",
	"o": "outgoing-proxy-port",
	"u": "proxy-uid",
	"g": "proxy-gid",
	"r": "ports-to-redirect",
}

// parseArgs is intentionally tolerant: upstream adds flags over time and unknown
// flags must not break meshing. Only the redirection contract is enforced.
func parseArgs(argv []string) (flagSet, error) {
	flags := flagSet{}

	for i := 0; i < len(argv); i++ {
		token := argv[i]
		if !strings.HasPrefix(token, "-") {
			return nil, fmt.Errorf("unexpected positional argument %q", token)
		}

		name := strings.TrimLeft(token, "-")
		if name == "" {
			return nil, fmt.Errorf("unexpected argument %q", token)
		}

		value := ""
		if idx := strings.Index(name, "="); idx >= 0 {
			name, value = name[:idx], name[idx+1:]
		} else if _, isBool := booleanFlags[name]; isBool {
			value = "true"
		} else {
			if i+1 >= len(argv) || strings.HasPrefix(argv[i+1], "--") {
				return nil, fmt.Errorf("flag %q is missing a value", token)
			}
			i++
			value = argv[i]
		}

		if long, ok := aliases[name]; ok {
			name = long
		}
		flags[name] = value
	}

	return flags, nil
}

// verifyContract fails when the chart no longer matches what the K2s CNI programs.
// Failing loudly is deliberate: a silent exit 0 would mesh the pod onto ports that
// carry no traffic, which is far harder to diagnose than a CrashLoopBackOff.
func verifyContract(flags flagSet) error {
	if err := requireEqual(flags, "incoming-proxy-port", inboundProxyPort, "inboundproxyport"); err != nil {
		return err
	}
	if err := requireEqual(flags, "outgoing-proxy-port", outboundProxyPort, "outboundproxyport"); err != nil {
		return err
	}
	if err := requirePortSet(flags, "inbound-ports-to-ignore", inboundPortExceptions, "inboundportexceptions"); err != nil {
		return err
	}
	if err := requirePortSet(flags, "outbound-ports-to-ignore", outboundPortExceptions, "outboundportexceptions"); err != nil {
		return err
	}

	for _, unsupported := range []string{"ports-to-redirect", "subnets-to-ignore"} {
		if value, ok := flags[unsupported]; ok && strings.TrimSpace(value) != "" {
			return fmt.Errorf("--%s=%q cannot be expressed as an HNS L4WFPPROXY policy; extend %s and internal/containernetworking/hnsproxy.go before enabling it",
				unsupported, value, hnsProxyConfigPath)
		}
	}

	return nil
}

func requireEqual(flags flagSet, flagName, expected, configKey string) error {
	actual, ok := flags[flagName]
	if !ok {
		return fmt.Errorf("--%s was not passed by the Linkerd proxy injector; the K2s Windows redirection contract cannot be verified", flagName)
	}
	if actual != expected {
		return contractMismatch(flagName, actual, expected, configKey)
	}
	return nil
}

func requirePortSet(flags flagSet, flagName, expected, configKey string) error {
	actual, ok := flags[flagName]
	if !ok {
		return fmt.Errorf("--%s was not passed by the Linkerd proxy injector; the K2s Windows redirection contract cannot be verified", flagName)
	}
	if !samePortSet(actual, expected) {
		return contractMismatch(flagName, actual, expected, configKey)
	}
	return nil
}

func contractMismatch(flagName, actual, expected, configKey string) error {
	return fmt.Errorf("Linkerd passed --%s=%q but the K2s CNI programs %q; update %s -> vfprules-k2s.hnsproxyconfig.%s and cmd/linkerdinit/contract.go",
		flagName, actual, expected, hnsProxyConfigPath, configKey)
}

func samePortSet(a, b string) bool {
	left, right := splitPorts(a), splitPorts(b)
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func splitPorts(value string) []string {
	ports := []string{}
	for _, part := range strings.Split(value, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			ports = append(ports, part)
		}
	}
	sort.Strings(ports)
	return ports
}
