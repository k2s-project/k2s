// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common_test

import (
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/common"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install common Unit Tests", Label("unit", "ci", "install"))
}

var _ = Describe("ErrorTracker", func() {
	var sut interface {
		Track(line string)
		ErrOccurred() bool
		PreRequisiteError() (line string, found bool)
	}

	BeforeEach(func() {
		sut = common.NewErrorTracker()
	})

	Describe("ErrOccurred", func() {
		When("no line was tracked", func() {
			It("returns false", func() {
				Expect(sut.ErrOccurred()).To(BeFalse())
			})
		})

		When("a line was tracked", func() {
			It("returns true", func() {
				sut.Track("some error")

				Expect(sut.ErrOccurred()).To(BeTrue())
			})
		})
	})

	Describe("PreRequisiteError", func() {
		When("no line was tracked", func() {
			It("returns not found", func() {
				line, found := sut.PreRequisiteError()

				Expect(found).To(BeFalse())
				Expect(line).To(BeEmpty())
			})
		})

		When("tracked lines have no pre-requisite marker", func() {
			It("returns not found", func() {
				sut.Track("some error")
				sut.Track("another error")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeFalse())
				Expect(line).To(BeEmpty())
			})
		})

		When("a tracked line has the pre-requisite marker", func() {
			It("returns the line without the marker", func() {
				sut.Track("some error")
				sut.Track("[PREREQ-FAILED] Master node memory passed too low")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeTrue())
				Expect(line).To(Equal("Master node memory passed too low"))
			})
		})

		When("multiple tracked lines have the pre-requisite marker", func() {
			It("returns the first one", func() {
				sut.Track("[PREREQ-FAILED] first")
				sut.Track("[PREREQ-FAILED] second")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeTrue())
				Expect(line).To(Equal("first"))
			})
		})
	})
})
