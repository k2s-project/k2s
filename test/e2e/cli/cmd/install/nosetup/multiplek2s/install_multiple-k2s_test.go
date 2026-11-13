// SPDX-FileCopyrightText:  © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package multiplek2s

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	"github.com/k2s-project/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install CLI Command Acceptance Tests", Label("cli", "install", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("install", Ordered, func() {
	It("prints error when multiple k2s.exe found in PATH", func(ctx SpecContext) {
		tmpDir := GinkgoT().TempDir()
		exeName := "k2s.exe"
		dummyExePath := filepath.Join(tmpDir, exeName)
		Expect(os.WriteFile(dummyExePath, []byte{}, 0755)).To(Succeed())
		origPath := os.Getenv("PATH")
		defer os.Setenv("PATH", origPath)
		os.Setenv("PATH", tmpDir+string(os.PathListSeparator)+origPath)
		args := []string{"install"}
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)
		GinkgoWriter.Println("[TestLog] CLI Output:\n" + output)

		Expect(output).To(ContainSubstring("Please clean up your PATH environment variable to remove old k2s.exe locations before proceeding with installation"))
	})
})
