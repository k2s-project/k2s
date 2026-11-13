// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   Apache-2.0

package json_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	j "encoding/json"

	"github.com/k2s-project/k2s/internal/json"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestJsonPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "json pkg Integration Tests", Label("integration", "ci", "json"))
}

type testData struct {
	Prop1 string `json:"prop1"`
	Prop2 int    `json:"prop2"`
}

var _ = Describe("json pkg", func() {
	Describe("MarshalIndent", func() {
		It("returns indented json", func() {
			input := testData{
				Prop1: "test-prop",
				Prop2: 123,
			}
			expected := "{\n  \"prop1\": \"test-prop\",\n  \"prop2\": 123\n}"

			actual, err := json.MarshalIndent(input)

			Expect(err).ToNot(HaveOccurred())
			Expect(string(actual)).To(Equal(expected))
		})
	})

	Describe("FromFile", func() {
		When("file read error occurs", func() {
			It("returns the error", func() {
				nonExistentFile := filepath.Join(GinkgoT().TempDir(), "non-existent")

				actual, err := json.FromFile[testData](nonExistentFile)

				Expect(err).To(MatchError(os.ErrNotExist))
				Expect(actual).To(BeNil())
			})
		})

		When("unmarshal error occurs", func() {
			var filePath string

			BeforeEach(func() {
				content := "nonsense"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")

				Expect(os.WriteFile(filePath, []byte(content), os.ModePerm)).ToNot(HaveOccurred())
			})

			It("returns the error", func() {
				actual, err := json.FromFile[testData](filePath)

				var syntaxErr *j.SyntaxError
				Expect(errors.As(err, &syntaxErr)).To(BeTrue())
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			var filePath string

			BeforeEach(func() {
				content := "{\"prop1\": \"test-prop\", \"prop2\": 123}"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")

				Expect(os.WriteFile(filePath, []byte(content), os.ModePerm)).ToNot(HaveOccurred())
			})

			It("returns the json file content", func() {
				expected := testData{Prop1: "test-prop", Prop2: 123}

				actual, err := json.FromFile[testData](filePath)

				Expect(err).ToNot(HaveOccurred())
				Expect(*actual).To(Equal(expected))
			})
		})
	})

	Describe("ToFile", func() {
		When("successful", func() {
			var filePath string

			BeforeEach(func() {
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")
			})

			It("writes and reads the json file content", func() {
				expected := &testData{Prop1: "test-prop", Prop2: 123}

				err := json.ToFile(filePath, expected)

				actual, err := json.FromFile[testData](filePath)

				Expect(err).ToNot(HaveOccurred())
				Expect(*actual).To(Equal(*expected))
			})
		})
	})
})
