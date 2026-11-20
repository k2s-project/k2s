<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# linkerdinit

Replacement for the upstream `linkerd2-proxy-init` inside the **Windows** Linkerd
data-plane image (`shsk2s.azurecr.io/linkerd/proxy:<edge-tag>`).

## Why this exists

Upstream `linkerd/linkerd2-proxy-init` only knows how to program Linux `iptables`.
It has no Windows backend, and no Windows binary is published. Cross-compiling it
with `GOOS=windows` produces an executable that starts and then fails on the first
`iptables-nft-save` call, which leaves every meshed Windows pod stuck in
`PodInitializing`.

On Windows nodes K2s does not need it: the redirection is programmed by the CNI
bridge plugin as an HNS `L4WFPPROXY` endpoint policy, see
[hnsproxy.go](../../internal/containernetworking/hnsproxy.go) and
[l4proxy](../l4proxy/). The injected `linkerd-init` container therefore has
nothing to do.

## What it does

It parses the arguments the Linkerd proxy injector renders, verifies they still
match the redirection contract in `cfg/config.json` →
`smallsetup.vfprules-k2s.hnsproxyconfig`, and exits `0`.

If Linkerd ever changes the proxy ports, the ignore lists, or asks for a
redirection option the HNS policy cannot express, it exits non-zero with a message
naming the file to update. A silent success would mesh the pod onto ports carrying
no traffic, which is far harder to diagnose than a failing init container.

## Build

Not part of `bgow`; it is never installed on the host. The Linkerd image pipeline
in the K2s-Support repo compiles it from this source:

```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
  -o release/linkerd2-proxy-init.exe ./cmd/linkerdinit
```

It is copied into the image by
[addons/security/build/Dockerfile.linkerd-proxy](../../addons/security/build/Dockerfile.linkerd-proxy).
