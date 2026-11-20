// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck_test

import (
	"testing"

	"github.com/k2s-project/k2s/internal/healthcheck"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestHealthcheckPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "healthcheck pkg Unit Tests", Label("unit", "ci"))
}

func constCheck(name string, status healthcheck.Status) healthcheck.Check {
	return healthcheck.Check{
		Name:        name,
		Description: name + " description",
		Run: func() healthcheck.Outcome {
			return healthcheck.Outcome{Status: status, Message: name + " message", Hint: name + " hint"}
		},
	}
}

var _ = Describe("healthcheck pkg", func() {
	Describe("Run", func() {
		It("runs all checks in order and collects their results", func() {
			report := healthcheck.Run([]healthcheck.Check{
				constCheck("first", healthcheck.StatusPass),
				constCheck("second", healthcheck.StatusFail),
			})

			Expect(report.Results).To(Equal([]healthcheck.Result{
				{Name: "first", Description: "first description", Status: healthcheck.StatusPass, Message: "first message", Hint: "first hint"},
				{Name: "second", Description: "second description", Status: healthcheck.StatusFail, Message: "second message", Hint: "second hint"},
			}))
		})

		It("returns an empty report for no checks", func() {
			report := healthcheck.Run(nil)

			Expect(report.Results).To(BeEmpty())
			Expect(report.HasFailures()).To(BeFalse())
		})
	})

	Describe("Report", func() {
		It("counts results by status and detects failures", func() {
			report := healthcheck.Run([]healthcheck.Check{
				constCheck("a", healthcheck.StatusPass),
				constCheck("b", healthcheck.StatusWarn),
				constCheck("c", healthcheck.StatusWarn),
				constCheck("d", healthcheck.StatusSkip),
			})

			Expect(report.Count(healthcheck.StatusPass)).To(Equal(1))
			Expect(report.Count(healthcheck.StatusWarn)).To(Equal(2))
			Expect(report.Count(healthcheck.StatusSkip)).To(Equal(1))
			Expect(report.Count(healthcheck.StatusFail)).To(Equal(0))
			Expect(report.HasFailures()).To(BeFalse())

			report = healthcheck.Run([]healthcheck.Check{constCheck("e", healthcheck.StatusFail)})

			Expect(report.HasFailures()).To(BeTrue())
		})
	})

	Describe("NewSkippedCheck", func() {
		It("keeps name and description but skips instead of running", func() {
			executed := false
			check := healthcheck.Check{
				Name:        "my-check",
				Description: "My check",
				Run: func() healthcheck.Outcome {
					executed = true
					return healthcheck.Outcome{Status: healthcheck.StatusFail}
				},
			}

			report := healthcheck.Run([]healthcheck.Check{healthcheck.NewSkippedCheck(check, "not applicable")})

			Expect(executed).To(BeFalse())
			Expect(report.Results).To(ConsistOf(healthcheck.Result{
				Name:        "my-check",
				Description: "My check",
				Status:      healthcheck.StatusSkip,
				Message:     "not applicable",
			}))
		})
	})
})

func runSingle(check healthcheck.Check) healthcheck.Result {
	report := healthcheck.Run([]healthcheck.Check{check})
	ExpectWithOffset(1, report.Results).To(HaveLen(1))
	return report.Results[0]
}
