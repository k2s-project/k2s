// SPDX-FileCopyrightText:  © 2024 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package yaml_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	y "gopkg.in/yaml.v3"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/k2s-project/k2s/internal/yaml"
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
		When("file read error occurrs", func() {
			It("returns the error", func() {
				nonExistentFile := filepath.Join(GinkgoT().TempDir(), "non-existent")

				actual, err := yaml.FromFile[testData](nonExistentFile)

				Expect(err).To(MatchError(os.ErrNotExist))
				Expect(actual).To(BeNil())
			})
		})

		When("unmarshal error occurrs", func() {
			var filePath string

			BeforeEach(func() {
				content := "nonsense"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				file, err := os.OpenFile(filePath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(content))
				Expect(err).ToNot(HaveOccurred())

				err = file.Close()
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
				content := "prop1: test-prop\nprop2: 123"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				file, err := os.OpenFile(filePath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(content))
				Expect(err).ToNot(HaveOccurred())

				err = file.Close()
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
