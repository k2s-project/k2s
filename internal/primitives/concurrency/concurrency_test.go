// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package concurrency_test

import (
	"errors"
	"sync/atomic"
	"testing"

	sut "github.com/k2s-project/k2s/internal/primitives/concurrency"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestConcurrency(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "concurrency pkg Unit Tests", Label("unit", "ci"))
}

var _ = Describe("RunAll", func() {
	When("no functions are given", func() {
		It("returns nil", func() {
			Expect(sut.RunAll()).To(BeNil())
		})
	})

	When("all functions succeed", func() {
		It("returns nil and calls every function", func() {
			var calls atomic.Int32

			err := sut.RunAll(
				func() error { calls.Add(1); return nil },
				func() error { calls.Add(1); return nil },
				func() error { calls.Add(1); return nil },
			)

			Expect(err).To(BeNil())
			Expect(calls.Load()).To(Equal(int32(3)))
		})
	})

	When("a single function fails", func() {
		It("returns that error", func() {
			failure := errors.New("oops")

			err := sut.RunAll(
				func() error { return nil },
				func() error { return failure },
				func() error { return nil },
			)

			Expect(err).To(MatchError(failure))
		})
	})

	When("multiple functions fail", func() {
		It("joins all errors instead of stopping at the first one", func() {
			firstFailure := errors.New("first failure")
			secondFailure := errors.New("second failure")

			err := sut.RunAll(
				func() error { return firstFailure },
				func() error { return nil },
				func() error { return secondFailure },
			)

			Expect(errors.Is(err, firstFailure)).To(BeTrue())
			Expect(errors.Is(err, secondFailure)).To(BeTrue())
		})
	})

	When("one function fails", func() {
		It("still runs every other function", func() {
			var calls atomic.Int32

			_ = sut.RunAll(
				func() error { calls.Add(1); return errors.New("oops") },
				func() error { calls.Add(1); return nil },
				func() error { calls.Add(1); return nil },
			)

			Expect(calls.Load()).To(Equal(int32(3)))
		})
	})

	When("functions complete out of order", func() {
		It("preserves the original argument order in the joined error", func() {
			first := errors.New("first")
			second := errors.New("second")
			release := make(chan struct{})

			// first blocks until second has already returned, proving order is by
			// argument position, not completion time.
			err := sut.RunAll(
				func() error {
					<-release
					return first
				},
				func() error {
					defer close(release)
					return second
				},
			)

			Expect(err.Error()).To(Equal(first.Error() + "\n" + second.Error()))
		})
	})
})
