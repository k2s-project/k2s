//go:build linux

// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package provider

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("nodeRole", Label("unit"), func() {
	DescribeTable("derives the role from the node labels",
		func(labels map[string]string, want string) {
			Expect(nodeRole(labels)).To(Equal(want))
		},
		Entry("control plane", map[string]string{"node-role.kubernetes.io/control-plane": "", "kubernetes.io/role": "worker"}, "control-plane"),
		Entry("worker labeled by K2s", map[string]string{"kubernetes.io/role": "worker"}, "worker"),
		Entry("other node-role label", map[string]string{"node-role.kubernetes.io/infra": ""}, "infra"),
		Entry("no role", map[string]string{"kubernetes.io/os": "linux"}, ""),
	)
})
