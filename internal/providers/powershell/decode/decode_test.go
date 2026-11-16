// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package decode_test

import (
	"encoding/base64"
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/providers/powershell/decode"
)

func TestDecodePkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "decode pkg Unit Tests", Label("unit", "ci", "decode"))
}

var _ = Describe("decode pkg", func() {
	Describe("IsEncodedMessage", func() {
		When("message is not encoded", func() {
			It("returns false", func() {
				message := "not-encoded"

				actual := decode.IsEncodedMessage(message)

				Expect(actual).To(BeFalse())
			})
		})

		When("message is encoded", func() {
			It("returns true", func() {
				message := "#pm#some-payload"

				actual := decode.IsEncodedMessage(message)

				Expect(actual).To(BeTrue())
			})
		})
	})

	Describe("DecodeMessages", func() {
		When("no messages passed", func() {
			It("returns error", func() {
				messages := []string{}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).To(MatchError(ContainSubstring("no messages")))
				Expect(actual).To(BeNil())
			})
		})

		When("message is malformed", func() {
			It("returns error", func() {
				messages := []string{"malformed"}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).To(MatchError(ContainSubstring("malformed")))
				Expect(actual).To(BeNil())
			})
		})

		When("message type does not match", func() {
			It("returns error", func() {
				messages := []string{"##wrong-type#"}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).To(MatchError(ContainSubstring("type mismatch")))
				Expect(actual).To(BeNil())
			})
		})

		When("base64 decoding failes", func() {
			It("returns error", func() {
				messages := []string{"##test#invalid-base64"}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				var decodingErr base64.CorruptInputError
				Expect(errors.As(err, &decodingErr)).To(BeTrue())
				Expect(actual).To(BeNil())
			})
		})

		When("uncompression failes", func() {
			It("returns error", func() {
				messages := []string{"##test#cGF5bG9hZA=="}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).To(MatchError(ContainSubstring("unexpected EOF")))
				Expect(actual).To(BeNil())
			})
		})

		When("single message passed", func() {
			It("returns decoded message", func() {
				messages := []string{"##test#H4sIAAAAAAAAAytJLS7RzU0tLk5MTwUAWnKJhAwAAAA="}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).ToNot(HaveOccurred())
				Expect(string(actual)).To(Equal("test-message"))
			})
		})

		When("multiple messages passed", func() {
			It("returns decoded message", func() {
				messages := []string{
					"##test#H4sIAAAAAAAAAytJLS7",
					"##test#RzU0tLk5MTwUAWnKJhAwAAAA=",
				}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).ToNot(HaveOccurred())
				Expect(string(actual)).To(Equal("test-message"))
			})
		})

		When("duplicate independent messages passed (fallback)", func() {
			It("falls back to last message and succeeds", func() {
				// Simulate two independent Send-ToCli calls producing two complete payloads.
				// The first is a valid standalone message, the second is another valid standalone message.
				// Concatenated base64 is invalid, but fallback to last should work.
				messages := []string{
					"##test#H4sIAAAAAAAAAytJLS7RzU0tLk5MTwUAWnKJhAwAAAA=",
					"##test#H4sIAAAAAAAAAytJLS7RzU0tLk5MTwUAWnKJhAwAAAA=",
				}
				messageType := "test"

				actual, err := decode.DecodeMessages(messages, messageType)

				Expect(err).ToNot(HaveOccurred())
				Expect(string(actual)).To(Equal("test-message"))
			})
		})
	})
})
