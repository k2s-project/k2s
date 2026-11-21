// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package restore

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/k2s-project/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite

func TestSystemRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system restore Command Tests", Label("cli", "system", "restore", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'system restore' command", Ordered, func() {
	// Note: --error-on-failure (-e) flag behavior is extensively tested in the
	// system-running restore tests where a cluster is available

	Describe("when no cluster is installed", func() {
		It("returns an error message indicating no setup is available", func(ctx context.Context) {
			tempDir := GinkgoT().TempDir()
			backupFile := filepath.Join(tempDir, "test-backup.zip")

			output, exitCode := suite.K2sCli().Exec(ctx, "system", "restore", "-f", backupFile)

			Expect(exitCode).NotTo(Equal(0))
			Expect(output).To(Or(
				ContainSubstring("not found"),
				ContainSubstring("not installed"),
			))
		})
	})

    Describe("when backup file does not exist", func() {
      It("returns an error message indicating no setup is available", func(ctx context.Context) {
       tempDir := GinkgoT().TempDir()
       nonExistentFile := filepath.Join(tempDir, "test-backup.zip")

       output, exitCode := suite.K2sCli().Exec(ctx, "system", "restore", "-f", nonExistentFile)

       Expect(exitCode).NotTo(Equal(0))
       Expect(output).To(Or(
        ContainSubstring("not found"),
        ContainSubstring("not installed"),
       ))
      })
    })
})
