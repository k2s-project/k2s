// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package certificate

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestAutoRotation(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "AutoRotation Unit Tests", Label("unit", "ci"))
}

var _ = Describe("autorotation command flags", func() {

	BeforeEach(func() {
		// Reset all flags to defaults before each test
		autoRotationCmd.Flags().Set(autoRotateEnableFlagName, "false")
		autoRotationCmd.Flags().Set(autoRotateDisableFlagName, "false")
		autoRotationCmd.Flags().Set(autoRotateStatusFlagName, "false")
	})

	Describe("default behavior (no flags)", Label("unit"), func() {
		It("defaults to status when no flags set", func() {
			enableVal := autoRotationCmd.Flags().Lookup(autoRotateEnableFlagName).Value.String()
			disableVal := autoRotationCmd.Flags().Lookup(autoRotateDisableFlagName).Value.String()
			statusVal := autoRotationCmd.Flags().Lookup(autoRotateStatusFlagName).Value.String()

			Expect(enableVal).To(Equal("false"))
			Expect(disableVal).To(Equal("false"))
			Expect(statusVal).To(Equal("false"))
			// When all are false, manageAutoRotation defaults to status behavior
		})
	})

	Describe("enable flag", Label("unit"), func() {
		It("sets enable to true", func() {
			autoRotationCmd.Flags().Set(autoRotateEnableFlagName, "true")

			enableVal := autoRotationCmd.Flags().Lookup(autoRotateEnableFlagName).Value.String()
			disableVal := autoRotationCmd.Flags().Lookup(autoRotateDisableFlagName).Value.String()
			statusVal := autoRotationCmd.Flags().Lookup(autoRotateStatusFlagName).Value.String()

			Expect(enableVal).To(Equal("true"))
			Expect(disableVal).To(Equal("false"))
			Expect(statusVal).To(Equal("false"))
		})
	})

	Describe("disable flag", Label("unit"), func() {
		It("sets disable to true", func() {
			autoRotationCmd.Flags().Set(autoRotateDisableFlagName, "true")

			enableVal := autoRotationCmd.Flags().Lookup(autoRotateEnableFlagName).Value.String()
			disableVal := autoRotationCmd.Flags().Lookup(autoRotateDisableFlagName).Value.String()
			statusVal := autoRotationCmd.Flags().Lookup(autoRotateStatusFlagName).Value.String()

			Expect(enableVal).To(Equal("false"))
			Expect(disableVal).To(Equal("true"))
			Expect(statusVal).To(Equal("false"))
		})
	})

	Describe("status flag", Label("unit"), func() {
		It("sets status to true", func() {
			autoRotationCmd.Flags().Set(autoRotateStatusFlagName, "true")

			enableVal := autoRotationCmd.Flags().Lookup(autoRotateEnableFlagName).Value.String()
			disableVal := autoRotationCmd.Flags().Lookup(autoRotateDisableFlagName).Value.String()
			statusVal := autoRotationCmd.Flags().Lookup(autoRotateStatusFlagName).Value.String()

			Expect(enableVal).To(Equal("false"))
			Expect(disableVal).To(Equal("false"))
			Expect(statusVal).To(Equal("true"))
		})
	})

	Describe("short flags", Label("unit"), func() {
		It("-e sets enable", func() {
			flag := autoRotationCmd.Flags().ShorthandLookup("e")
			Expect(flag).NotTo(BeNil())
			Expect(flag.Name).To(Equal(autoRotateEnableFlagName))
		})

		It("-d sets disable", func() {
			flag := autoRotationCmd.Flags().ShorthandLookup("d")
			Expect(flag).NotTo(BeNil())
			Expect(flag.Name).To(Equal(autoRotateDisableFlagName))
		})

		It("-s sets status", func() {
			flag := autoRotationCmd.Flags().ShorthandLookup("s")
			Expect(flag).NotTo(BeNil())
			Expect(flag.Name).To(Equal(autoRotateStatusFlagName))
		})
	})

	Describe("mutual exclusion", Label("unit"), func() {
		// Note: Cobra's ValidateFlagGroups checks the 'Changed' property of flags.
		// Once a flag is Set(), it remains 'Changed' for the lifetime of that command instance.
		// The mutual exclusion tests for "rejects" combinations work because we set multiple
		// flags in the same test. The "allows alone" tests verify via the CLI (already tested
		// in integration tests A4-A6). Here we test the rejection logic only.

		It("rejects --enable and --disable together", func() {
			autoRotationCmd.Flags().Set(autoRotateEnableFlagName, "true")
			autoRotationCmd.Flags().Set(autoRotateDisableFlagName, "true")

			err := autoRotationCmd.ValidateFlagGroups()
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("if any flags in the group"))
		})

		It("rejects --enable and --status together", func() {
			autoRotationCmd.Flags().Set(autoRotateEnableFlagName, "true")
			autoRotationCmd.Flags().Set(autoRotateStatusFlagName, "true")

			err := autoRotationCmd.ValidateFlagGroups()
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("if any flags in the group"))
		})

		It("rejects --disable and --status together", func() {
			autoRotationCmd.Flags().Set(autoRotateDisableFlagName, "true")
			autoRotationCmd.Flags().Set(autoRotateStatusFlagName, "true")

			err := autoRotationCmd.ValidateFlagGroups()
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("if any flags in the group"))
		})
	})

	Describe("command metadata", Label("unit"), func() {
		It("has correct Use field", func() {
			Expect(autoRotationCmd.Use).To(Equal("autorotation"))
		})

		It("has non-empty Short description", func() {
			Expect(autoRotationCmd.Short).NotTo(BeEmpty())
		})

		It("has non-empty Long description", func() {
			Expect(autoRotationCmd.Long).NotTo(BeEmpty())
		})

		It("has examples", func() {
			Expect(autoRotationCmd.Example).NotTo(BeEmpty())
		})
	})
})


