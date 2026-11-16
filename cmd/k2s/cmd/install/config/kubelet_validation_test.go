// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package config

import (
	"bytes"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/viper"
)

var _ = Describe("kubelet override configuration", func() {
	Describe("validateKubeletOverrides", func() {
		It("accepts both supported roles and fields", func() {
			config := viper.New()
			config.Set("kubeletOverrides", map[string]any{
				"linuxControlPlane": map[string]any{
					"enabled": true,
					"config": map[string]any{
						"maxPods": int64(100),
						"systemReserved": map[string]any{
							"cpu":    "500m",
							"memory": "1Gi",
						},
					},
				},
				"windowsWorker": map[string]any{
					"enabled": false,
					"config": map[string]any{
						"kubeReserved": map[string]any{
							"cpu":    "250m",
							"memory": "512Mi",
						},
					},
				},
			})

			Expect(validateKubeletOverrides(config)).To(Succeed())
		})

		It("accepts omitted overrides", func() {
			Expect(validateKubeletOverrides(viper.New())).To(Succeed())
		})

		DescribeTable("rejects malformed or unsupported values",
			func(value any, expectedMessage string) {
				config := viper.New()
				config.Set("kubeletOverrides", value)

				Expect(validateKubeletOverrides(config)).To(MatchError(ContainSubstring(expectedMessage)))
			},
			Entry("non-object root", "invalid", "kubeletOverrides must be an object"),
			Entry("unknown role", map[string]any{"unknown": map[string]any{}}, "unsupported kubeletOverrides role"),
			Entry("non-object role", map[string]any{"linuxControlPlane": "invalid"}, "linuxcontrolplane must be an object"),
			Entry("unknown role field", map[string]any{"linuxControlPlane": map[string]any{"unknown": true}}, "unsupported kubeletOverrides.linuxcontrolplane field"),
			Entry("mistyped enabled", map[string]any{"linuxControlPlane": map[string]any{"enabled": "true"}}, "enabled must be a boolean"),
			Entry("non-object config", map[string]any{"linuxControlPlane": map[string]any{"config": "invalid"}}, "config must be an object"),
			Entry("unknown config field", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"unknown": true}}}, "unsupported kubeletOverrides.linuxcontrolplane.config field"),
			Entry("zero maxPods", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"maxPods": 0}}}, "maxPods must be a positive integer"),
			Entry("fractional maxPods", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"maxPods": 1.5}}}, "maxPods must be a positive integer"),
			Entry("unknown resource", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"systemReserved": map[string]any{"disk": "1Gi"}}}}, "unsupported kubeletOverrides.linuxcontrolplane.config.systemreserved field"),
			Entry("mistyped resource", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"systemReserved": map[string]any{"cpu": 1}}}}, "must be a non-negative Kubernetes resource quantity string"),
			Entry("invalid quantity", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"systemReserved": map[string]any{"memory": "invalid"}}}}, "must be a non-negative Kubernetes resource quantity string"),
			Entry("negative quantity", map[string]any{"linuxControlPlane": map[string]any{"config": map[string]any{"systemReserved": map[string]any{"cpu": "-1"}}}}, "must be a non-negative Kubernetes resource quantity string"),
		)
	})

	Describe("conversion", func() {
		It("converts the documented YAML shape", func() {
			config := viper.New()
			config.SetConfigType("yaml")
			yamlConfig := []byte(`
kubeletOverrides:
  linuxControlPlane:
    enabled: true
    config:
      maxPods: 100
      systemReserved:
        cpu: 500m
        memory: 1Gi
`)
			Expect(config.ReadConfig(bytes.NewReader(yamlConfig))).To(Succeed())

			result, err := (&viperConfigConverter{}).convert(config)

			Expect(err).NotTo(HaveOccurred())
			Expect(result.KubeletOverrides.LinuxControlPlane).NotTo(BeNil())
			Expect(result.KubeletOverrides.LinuxControlPlane.Enabled).To(BeTrue())
			Expect(result.KubeletOverrides.LinuxControlPlane.Config.MaxPods).NotTo(BeNil())
			Expect(*result.KubeletOverrides.LinuxControlPlane.Config.MaxPods).To(Equal(int64(100)))
			Expect(result.KubeletOverrides.LinuxControlPlane.Config.SystemReserved.Cpu).To(Equal("500m"))
			Expect(result.KubeletOverrides.WindowsWorker).To(BeNil())
		})
	})
})
