// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier:   MIT

package yaml_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	y "gopkg.in/yaml.v3"

	"github.com/k2s-project/k2s/internal/yaml"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestYamlPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "yaml pkg Integration Tests", Label("integration", "ci", "yaml"))
}

type testData struct {
	Prop1 string `yaml:"prop1"`
	Prop2 int    `yaml:"prop2"`
}

var _ = Describe("yaml pkg", func() {
	Describe("FromFile", func() {
		When("file read error occurs", func() {
			It("returns the error", func() {
				nonExistentFile := filepath.Join(GinkgoT().TempDir(), "non-existent")

				actual, err := yaml.FromFile[testData](nonExistentFile)

				Expect(err).To(MatchError(os.ErrNotExist))
				Expect(actual).To(BeNil())
			})
		})

		When("unmarshal error occurs", func() {
			var filePath string

			BeforeEach(func() {
				filePath = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				err := os.WriteFile(filePath, []byte("nonsense"), os.ModePerm)

				Expect(err).ToNot(HaveOccurred())
			})

			It("returns the error", func() {
				actual, err := yaml.FromFile[testData](filePath)

				var typeError *y.TypeError
				Expect(errors.As(err, &typeError)).To(BeTrue())
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			var filePath string

			BeforeEach(func() {
				filePath = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				err := os.WriteFile(filePath, []byte("prop1: test-prop\nprop2: 123"), os.ModePerm)

				Expect(err).ToNot(HaveOccurred())
			})

			It("returns the json file content", func() {
				expected := testData{Prop1: "test-prop", Prop2: 123}

				actual, err := yaml.FromFile[testData](filePath)

				Expect(err).ToNot(HaveOccurred())
				Expect(*actual).To(Equal(expected))
			})
		})
	})
})
