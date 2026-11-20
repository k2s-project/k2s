// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main_test

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/k2s-project/k2s/internal/cli"
)

type TestContent struct {
	ApiVersion string   `json:"apiVersion"`
	Kind       string   `json:"kind"`
	Metadata   Metadata `json:"metadata"`
	Spec       Spec     `json:"spec"`
}

type Metadata struct {
	Name string `json:"name"`
}

type Spec struct {
	StringVal string  `json:"string-val"`
	NumberVal float64 `json:"number-val"`
	ListVal   []Item  `json:"list-val"`
}

type Item struct {
	Prop1 string `json:"prop1"`
	Prop2 int    `json:"prop2"`
}

const (
	yamlPath        = "test\\test.yaml"
	invalidYamlPath = "test\\invalid.yaml"
	horizontalTab   = byte(9)
	lineFeed        = byte(10)
)

var (
	exePath  string
	jsonPath string
	rawJson  []byte
)

func TestYaml2json(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "yaml2json Acceptance Tests", Label("util", "acceptance", "yaml2json"))
}

var _ = BeforeSuite(func() {
	var err error
	exePath, err = gexec.Build("github.com/k2s-project/k2s/cmd/yaml2json")
	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("temp exe path:", exePath)

	tempDir := GinkgoT().TempDir()

	GinkgoWriter.Println("temp dir:", tempDir)

	jsonPath = filepath.Join(tempDir, "test.json")

	GinkgoWriter.Println("temp json file path:", jsonPath)
})

var _ = AfterSuite(func() {
	gexec.Kill()
	gexec.CleanupBuildArtifacts()
})

var _ = Describe("yaml2json", func() {
	When("input file exists", func() {
		When("content is valid", func() {
			When("no indentation", Ordered, func() {
				BeforeAll(func(ctx context.Context) {
					cmd := exec.Command(exePath, "-input", yamlPath, "-output", jsonPath)

					executeCmd(cmd, ctx, cli.ExitCodeSuccess)

					var err error
					rawJson, err = os.ReadFile(jsonPath)
					Expect(err).ToNot(HaveOccurred())
				})

				It("json contains original information", func(ctx context.Context) {
					var content TestContent
					Expect(json.Unmarshal(rawJson, &content)).To(Succeed())

					expectJsonContainsOriginalInfo(&content)
				})

				It("json is unindented", func(ctx context.Context) {
					Expect(rawJson).ToNot(ContainElement(horizontalTab))
					Expect(rawJson).ToNot(ContainElement(lineFeed))
				})
			})

			When("with indentation", Ordered, func() {
				BeforeAll(func(ctx context.Context) {
					cmd := exec.Command(exePath, "-input", yamlPath, "-output", jsonPath, "-indent")

					executeCmd(cmd, ctx, cli.ExitCodeSuccess)

					var err error
					rawJson, err = os.ReadFile(jsonPath)
					Expect(err).ToNot(HaveOccurred())
				})

				It("json contains original information", func(ctx context.Context) {
					var content TestContent
					Expect(json.Unmarshal(rawJson, &content)).To(Succeed())

					expectJsonContainsOriginalInfo(&content)
				})

				It("json is indented", func(ctx context.Context) {
					Expect(rawJson).To(ContainElement(horizontalTab))
					Expect(rawJson).To(ContainElement(lineFeed))
				})
			})
		})

		When("content is invalid", func() {
			It("exits with non-zero code", func(ctx context.Context) {
				cmd := exec.Command(exePath, "-input", invalidYamlPath, "-output", jsonPath)

				executeCmd(cmd, ctx, cli.ExitCodeFailure)
			})
		})
	})

	When("input file does not exist", func() {
		It("exits with non-zero code", func(ctx context.Context) {
			cmd := exec.Command(exePath, "-input", "non-existent", "-output", jsonPath)

			executeCmd(cmd, ctx, cli.ExitCodeFailure)
		})
	})

	When("input path is empty", func() {
		It("exits with non-zero code", func(ctx context.Context) {
			cmd := exec.Command(exePath, "-output", jsonPath)

			executeCmd(cmd, ctx, cli.ExitCodeFailure)
		})
	})

	When("output path is empty", func() {
		It("exits with non-zero code", func(ctx context.Context) {
			cmd := exec.Command(exePath, "-input", "some value")

			executeCmd(cmd, ctx, cli.ExitCodeFailure)
		})
	})

	When("verbosity level is error", func() {
		It("logs nothing on success", func(ctx context.Context) {
			cmd := exec.Command(exePath, "-input", yamlPath, "-output", jsonPath, "-verbosity", "error")

			output := executeCmd(cmd, ctx, cli.ExitCodeSuccess)

			Expect(output).To(BeEmpty())
		})
	})

	When("verbosity level is info", func() {
		It("logs basics on success", func(ctx context.Context) {
			cmd := exec.Command(exePath, "-input", yamlPath, "-output", jsonPath, "-verbosity", "info")

			output := executeCmd(cmd, ctx, cli.ExitCodeSuccess)

			Expect(output).ToNot(BeEmpty())
		})
	})
})

func executeCmd(cmd *exec.Cmd, ctx context.Context, expectedExitCode cli.ExitCode) string {
	session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
	Expect(err).ToNot(HaveOccurred())

	Eventually(session,
		1*time.Second,
		50*time.Millisecond,
		ctx).Should(gexec.Exit(int(expectedExitCode)), "Command '%v' exited with exit code '%v' instead of %d", session.Command, session.ExitCode(), expectedExitCode)

	return string(session.Out.Contents())
}

func expectJsonContainsOriginalInfo(content *TestContent) {
	Expect(content.ApiVersion).To(Equal("v1"))
	Expect(content.Kind).To(Equal("test-file"))
	Expect(content.Metadata.Name).To(Equal("conversion-test"))
	Expect(content.Spec.StringVal).To(Equal("test-string"))
	Expect(content.Spec.NumberVal).To(Equal(123.45))
	Expect(content.Spec.ListVal).To(HaveLen(2))
	Expect(content.Spec.ListVal[0].Prop1).To(Equal("val-1"))
	Expect(content.Spec.ListVal[0].Prop2).To(Equal(1))
	Expect(content.Spec.ListVal[1].Prop1).To(Equal("val-2"))
	Expect(content.Spec.ListVal[1].Prop2).To(Equal(2))
}
