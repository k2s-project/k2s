// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package powershell

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/test/reflection"
	"github.com/stretchr/testify/mock"
)

type decoderMock struct {
	mock.Mock
}

type writerMock struct {
	mock.Mock
}

func (m *decoderMock) IsEncodedMessage(message string) bool {
	args := m.Called(message)

	return args.Bool(0)
}

func (m *decoderMock) DecodeMessage(message string, targetType string) ([]byte, error) {
	args := m.Called(message, targetType)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *writerMock) WriteStdOut(message string) {
	m.Called(message)
}

func (m *writerMock) WriteStdErr(message string) {
	m.Called(message)
}

func (m *writerMock) Flush() {
	m.Called()
}

func TestPowershellPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "powershell pkg Tests", Label("ci", "powershell"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("powershell pkg", func() {
	Describe("structuredOutputWriter", func() {
		Describe("WriteStdOut", func() {
			When("message is not encoded", func() {
				It("passes message to inner writer", func() {
					const message = "this is not encoded"

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.WriteStdOut), message).Once()

					sut := &structuredOutputWriter{
						isEncodedMessage: func(message string) bool { return false },
						stdWriter:        writerMock,
					}

					sut.WriteStdOut(message)

					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("message is encoded", func() {
				It("messages are accumulated", func() {
					const inputMessage = "some-message"

					sut := &structuredOutputWriter{
						isEncodedMessage: func(message string) bool { return true },
					}

					sut.WriteStdOut(inputMessage)
					sut.WriteStdOut(inputMessage)
					sut.WriteStdOut(inputMessage)

					Expect(sut.rawMessages).To(ConsistOf(
						inputMessage,
						inputMessage,
						inputMessage,
					))
				})
			})
		})

		Describe("WriteStdErr", func() {
			It("passes message to inner writer", func() {
				const message = "msg"

				writerMock := &writerMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.WriteStdErr), message).Once()

				sut := &structuredOutputWriter{stdWriter: writerMock}

				sut.WriteStdErr(message)

				writerMock.AssertExpectations(GinkgoT())
			})
		})

		Describe("Flush", func() {
			It("calls function of inner writer", func() {
				writerMock := &writerMock{}
				writerMock.On(reflection.GetFunctionName(writerMock.Flush)).Once()

				sut := &structuredOutputWriter{stdWriter: writerMock}

				sut.Flush()

				writerMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("buildCmdString", Label("unit"), func() {
		When("no additional params", func() {
			It("returns cmd with default params only", func() {
				script := "some-script"
				targetType := "some-type"

				actual := buildCmdString(script, targetType)

				Expect(actual).To(Equal("some-script -EncodeStructuredOutput -MessageType some-type"))
			})
		})

		When("additional params", func() {
			It("returns cmd with all params", func() {
				script := "some-script"
				targetType := "some-type"
				params := []string{"-p1 test", "-p2", "-p3"}

				actual := buildCmdString(script, targetType, params...)

				Expect(actual).To(Equal("some-script -EncodeStructuredOutput -MessageType some-type -p1 test -p2 -p3"))
			})
		})
	})

	Describe("convertToResult", Label("unit"), func() {
		When("unmarshalling failes", func() {
			It("returns error", func() {
				message := []byte("non-integer")

				actual, err := convertToResult[int](message)

				Expect(err).To(MatchError(ContainSubstring("could not unmarshal message")))
				Expect(actual).To(BeZero())
			})
		})

		When("successful", func() {
			It("returns converted result", func() {
				expected := `["test-msg"]`
				msg := []byte(expected)

				actual, err := convertToResult[[]string](msg)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal([]string{"test-msg"}))
			})
		})
	})

	Describe("prepareExecScript", Label("unit"), func() {
		It("passes the script as a verbatim string literal to the wrapper script", func() {
			const script = `&'C:\k2s\install.ps1' -Proxy 'it''s $(calc) ` + "`" + `"'`
			const expectedSuffix = `Invoke-ExecScript.ps1' -Script '&''C:\k2s\install.ps1'' -Proxy ''it''''s $(calc) ` + "`" + `"'''`

			actual, err := prepareExecScript(script)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).To(HavePrefix("&'"))
			Expect(actual).To(HaveSuffix(expectedSuffix))
		})
	})
})
