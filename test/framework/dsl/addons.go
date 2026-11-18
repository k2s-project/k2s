// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package dsl

import (
	"github.com/samber/lo"
	"github.com/k2s-project/k2s/internal/contracts/config"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

func (k2s *K2s) IsAddonEnabled(name string, implementation ...string) bool {
	impl := ""
	if len(implementation) > 0 {
		impl = implementation[0]
	}
	return lo.ContainsBy(k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons(), func(a config.Addon) bool {
		return a.Name == name && a.Implementation == impl
	})
}

func (k2s *K2s) VerifyAddonIsEnabled(name string, implementation ...string) {
	implementationName := ""
	if len(implementation) > 0 {
		implementationName = implementation[0]
	}

	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	addons := k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()

	Expect(addons).To(ContainElement(SatisfyAll(
		HaveField("Name", name),
		HaveField("Implementation", implementationName),
	)))
}

func (k2s *K2s) VerifyAddonIsDisabled(name string, implementation ...string) {
	implementationName := ""
	if len(implementation) > 0 {
		implementationName = implementation[0]
	}

	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	addons := k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()

	Expect(addons).ToNot(ContainElement(SatisfyAll(
		HaveField("Name", name),
		HaveField("Implementation", implementationName),
	)))
}
