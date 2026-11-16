// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/internal/core/config"
	kos "github.com/k2s-project/k2s/internal/os"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests", Label("cli", "system", "upgrade", "package", "users", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system", Ordered, func() {
	var configPath string

	BeforeEach(func() {
		inputConfig := map[string]any{
			"SetupName":  "k2s",
			"Registries": []string{"r1", "r2"},
			"LinuxOnly":  true,
			"Version":    "test-version",
			"Corrupted":  true,
		}
		inputData, err := json.Marshal(inputConfig)
		Expect(err).ToNot(HaveOccurred())

		currentDir, err := kos.ExecutableDir()
		Expect(err).ToNot(HaveOccurred())
		installDir := filepath.Join(currentDir, "..\\..\\..\\..\\..\\..\\..\\..")

		GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

		config, err := config.ReadK2sConfig(installDir)
		Expect(err).ToNot(HaveOccurred())

		GinkgoWriter.Println("Creating <", config.Host().K2sSetupConfigDir(), ">..")

		Expect(os.MkdirAll(config.Host().K2sSetupConfigDir(), os.ModePerm)).To(Succeed())

		configPath = filepath.Join(config.Host().K2sSetupConfigDir(), "setup.json")

		GinkgoWriter.Println("Writing test data to <", configPath, ">..")

		Expect(os.WriteFile(configPath, inputData, os.ModePerm)).To(Succeed())

		DeferCleanup(func() {
			GinkgoWriter.Println("Deleting <", config.Host().K2sSetupConfigDir(), ">..")

			Expect(os.RemoveAll(config.Host().K2sSetupConfigDir())).To(Succeed())
		})
	})

	DescribeTable("print system-in-corrupted-state message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("corrupted state"))
		},

		Entry("upgrade", "system", "upgrade"),
		Entry("upgrade", "system", "reset", "network"),
		Entry("package", "system", "package", "--target-dir", "tempDir", "--name", "package.zip", "--for-offline-installation"),
		Entry("users add", "system", "users", "add", "-u", "non-existent"),
	)
})
