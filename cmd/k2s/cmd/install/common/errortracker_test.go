// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package common_test

import (
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/install/common"
	"github.com/k2s-project/k2s/internal/output"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type recordingWriter struct {
	stdOut  []string
	stdErr  []string
	flushed bool
}

func (w *recordingWriter) WriteStdOut(message string) { w.stdOut = append(w.stdOut, message) }
func (w *recordingWriter) WriteStdErr(message string) { w.stdErr = append(w.stdErr, message) }
func (w *recordingWriter) Flush()                     { w.flushed = true }

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install common Unit Tests", Label("unit", "ci", "install"))
}

var _ = Describe("ErrorTracker", func() {
	var (
		next *recordingWriter
		sut  interface {
			output.StreamWriter
			ErrOccurred() bool
			PreRequisiteError() (line string, found bool)
		}
	)

	BeforeEach(func() {
		next = &recordingWriter{}
		sut = common.NewErrorTracker(next)
	})

	Describe("forwarding", func() {
		It("forwards stdout, stderr and flush to the wrapped writer", func() {
			sut.WriteStdOut("out")
			sut.WriteStdErr("err")
			sut.Flush()

			Expect(next.stdOut).To(Equal([]string{"out"}))
			Expect(next.stdErr).To(Equal([]string{"err"}))
			Expect(next.flushed).To(BeTrue())
		})
	})

	Describe("ErrOccurred", func() {
		When("no line was written", func() {
			It("returns false", func() {
				Expect(sut.ErrOccurred()).To(BeFalse())
			})
		})

		When("only stdout was written", func() {
			It("returns false", func() {
				sut.WriteStdOut("some output")

				Expect(sut.ErrOccurred()).To(BeFalse())
			})
		})

		When("a stderr line was written", func() {
			It("returns true", func() {
				sut.WriteStdErr("some error")

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
				sut.WriteStdErr("some error")
				sut.WriteStdErr("another error")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeFalse())
				Expect(line).To(BeEmpty())
			})
		})

		When("a tracked line has the pre-requisite marker", func() {
			It("returns the line without the marker", func() {
				sut.WriteStdErr("some error")
				sut.WriteStdErr("[PREREQ-FAILED] Master node memory passed too low")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeTrue())
				Expect(line).To(Equal("Master node memory passed too low"))
			})
		})

		When("multiple tracked lines have the pre-requisite marker", func() {
			It("returns the first one", func() {
				sut.WriteStdErr("[PREREQ-FAILED] first")
				sut.WriteStdErr("[PREREQ-FAILED] second")

				line, found := sut.PreRequisiteError()

				Expect(found).To(BeTrue())
				Expect(line).To(Equal("first"))
			})
		})
	})
})
