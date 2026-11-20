// SPDX-FileCopyrightText:  © 2024 The K2s Authors
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

func TestNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node CLI Commands Acceptance Tests", Label("cli", "node", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node", Ordered, func() {
	var configPath string

	// TODO: extract 'system-in-corrupted-state' to DSL for re-use
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

	Describe("copy", Label("copy"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "copy", "--ip-addr", "", "-s", "", "-t", "", "-u", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("exec", Label("exec"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "exec", "-i", "", "-u", "", "-c", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("connect", Label("connect"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "connect", "-i", "", "-u", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})
})
