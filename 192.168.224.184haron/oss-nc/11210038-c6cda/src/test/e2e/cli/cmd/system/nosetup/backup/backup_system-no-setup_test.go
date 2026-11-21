// SPDX-FileCopyrightText: © 2025 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package backup

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

func TestSystemBackup(t *testing.T) {
 RegisterFailHandler(Fail)
 RunSpecs(t, "system backup Command Tests", Label("cli", "system", "backup", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
 suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
 suite.TearDown(ctx)
})

var _ = Describe("'system backup' command", Ordered, func() {
 Describe("when no cluster is installed", func() {
  It("returns an error message indicating no setup is available", func(ctx context.Context) {
   tempDir := GinkgoT().TempDir()
   backupFile := filepath.Join(tempDir, "test-backup.zip")

   output, exitCode := suite.K2sCli().Exec(ctx, "system", "backup", "-f", backupFile)

   Expect(exitCode).NotTo(Equal(0))
   Expect(output).To(Or(
    ContainSubstring("not found"),
    ContainSubstring("not installed"),
   ))
  })
 })
})
