// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package image

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("node_selector", func() {
	Describe("ValidateNodeSelector", func() {
		When("node selector is empty", func() {
			It("returns no error on Linux-only installation", func() {
				installConfig := contracts.NewK2sInstallConfig("k2s", true, "1.0.0", false, false)
				cpConfig := contracts.NewK2sControlPlaneConfig("my-cp-node")
				runtimeConfig := contracts.NewK2sRuntimeConfig(nil, installConfig, cpConfig)

				err := common.ValidateNodeSelector("", runtimeConfig)

				Expect(err).ToNot(HaveOccurred())
			})
		})

		When("installation is not Linux-only", func() {
			It("allows any node selector including multi-node or windows nodes", func() {
				installConfig := contracts.NewK2sInstallConfig("k2s", false, "1.0.0", false, false)
				cpConfig := contracts.NewK2sControlPlaneConfig("my-cp-node")
				runtimeConfig := contracts.NewK2sRuntimeConfig(nil, installConfig, cpConfig)

				Expect(common.ValidateNodeSelector("worker-1,worker-2", runtimeConfig)).To(Succeed())
				Expect(common.ValidateNodeSelector("win-worker-1", runtimeConfig)).To(Succeed())
			})
		})

		When("installation is Linux-only", func() {
			var runtimeConfig *contracts.K2sRuntimeConfig

			BeforeEach(func() {
				installConfig := contracts.NewK2sInstallConfig("k2s", true, "1.0.0", false, false)
				cpConfig := contracts.NewK2sControlPlaneConfig("controlplane-host")
				runtimeConfig = contracts.NewK2sRuntimeConfig(nil, installConfig, cpConfig)
			})

			It("rejects comma-separated multi-node selector with actionable message", func() {
				err := common.ValidateNodeSelector("worker-1,worker-2", runtimeConfig)

				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("multi-node selection 'worker-1,worker-2' is not supported on a Linux-only installation"))
			})

			It("rejects windows worker node names with actionable message", func() {
				for _, winNode := range []string{"windows", "win-worker", "k2s-win-worker", "winworker-1"} {
					err := common.ValidateNodeSelector(winNode, runtimeConfig)

					Expect(err).To(HaveOccurred())
					Expect(err.Error()).To(ContainSubstring("is a Windows worker node; Linux-only installations do not contain Windows worker nodes"))
				}
			})

			It("allows Linux hostnames containing 'win' such as 'darwin'", func() {
				installConfig := contracts.NewK2sInstallConfig("k2s", true, "1.0.0", false, false)
				cpConfig := contracts.NewK2sControlPlaneConfig("darwin")
				darwinConfig := contracts.NewK2sRuntimeConfig(nil, installConfig, cpConfig)

				Expect(common.ValidateNodeSelector("darwin", darwinConfig)).To(Succeed())
			})

			It("allows 'linux' as node selector", func() {
				err := common.ValidateNodeSelector("linux", runtimeConfig)

				Expect(err).ToNot(HaveOccurred())
			})

			It("allows control plane hostname as node selector", func() {
				err := common.ValidateNodeSelector("controlplane-host", runtimeConfig)

				Expect(err).ToNot(HaveOccurred())
			})

			It("rejects unknown node name not part of cluster", func() {
				err := common.ValidateNodeSelector("unknown-node", runtimeConfig)

				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("node 'unknown-node' is not part of this cluster"))
			})
		})
	})
})
