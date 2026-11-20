// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

// Redirection contract between the Linkerd chart and the K2s CNI plugin.
//
// On Windows nodes the traffic redirection is NOT performed by the injected
// linkerd-init container. It is programmed by the K2s CNI bridge plugin as an
// HNS L4WFPPROXY endpoint policy (see internal/containernetworking/hnsproxy.go),
// configured from cfg/config.json -> vfprules-k2s.hnsproxyconfig.
//
// These constants mirror that configuration. contract_test.go asserts they stay
// in sync with cfg/config.json, so the file remains the single source of truth.
const (
	inboundProxyPort  = "4143"
	outboundProxyPort = "4140"

	inboundPortExceptions  = "4190,4191,4567,4568"
	outboundPortExceptions = "4567,4568"
)

// hnsProxyConfigPath is the path of the K2s CNI configuration relative to the repo root.
const hnsProxyConfigPath = "cfg/config.json"
