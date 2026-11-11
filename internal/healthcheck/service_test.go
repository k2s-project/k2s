// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck_test

import (
	"errors"

	"github.com/k2s-project/k2s/internal/healthcheck"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Hyper-V service check", func() {
	It("queries the vmms service and passes when it is running", func() {
		var queried string
		check := healthcheck.NewHyperVServiceCheck(func(name string) (bool, error) {
			queried = name
			return true, nil
		})

		result := runSingle(check)

		Expect(queried).To(Equal("vmms"))
		Expect(result.Name).To(Equal("hyperv-vmms"))
		Expect(result.Status).To(Equal(healthcheck.StatusPass))
	})

	It("fails when the service is not running", func() {
		check := healthcheck.NewHyperVServiceCheck(func(string) (bool, error) { return false, nil })

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(Equal("service 'vmms' is not running"))
		Expect(result.Hint).To(ContainSubstring("Start-Service vmms"))
	})

	It("fails when the service cannot be queried", func() {
		check := healthcheck.NewHyperVServiceCheck(func(string) (bool, error) { return false, errors.New("service does not exist") })

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(ContainSubstring("service does not exist"))
		Expect(result.Hint).To(ContainSubstring("Hyper-V is enabled"))
	})
})
