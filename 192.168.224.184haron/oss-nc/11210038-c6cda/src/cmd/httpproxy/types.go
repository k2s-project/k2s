// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0
package main

type networkCIDRs []string

type proxyConfig struct {
	VerboseLogging *bool
	ListenAddress  *string
	ForwardProxy   *string
	AllowedCidrs   networkCIDRs
}
