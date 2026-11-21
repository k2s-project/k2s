// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package users_test

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/user"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/k2s-project/k2s/internal/cli"
	contracts "github.com/k2s-project/k2s/internal/contracts/users"
	"github.com/k2s-project/k2s/internal/core/users"
	"github.com/k2s-project/k2s/internal/definitions"
	"github.com/k2s-project/k2s/internal/providers/kubeconfig"
	"github.com/k2s-project/k2s/internal/providers/osusers"
	"github.com/k2s-project/k2s/internal/providers/ssh"
	"github.com/k2s-project/k2s/test/framework"
)

type winUserProvider struct {
	findByName func(name string) (*contracts.OSUser, error)
	getCurrent func() (*contracts.OSUser, error)
}

const systemUserId = "S-1-5-18"
const systemUserName = "NT AUTHORITY\\SYSTEM"

var suite *framework.K2sTestSuite

func (p *winUserProvider) FindByName(name string) (*contracts.OSUser, error) {
	return p.findByName(name)
}

func (p *winUserProvider) FindById(id string) (*contracts.OSUser, error) {
	return nil, errors.New("not implemented")
}

func (p *winUserProvider) CurrentUser() (*contracts.OSUser, error) {
	return p.getCurrent()
}

func TestUsers(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system users Acceptance Tests", Label("cli", "system", "users", "add", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system users add", Ordered, func() {
	When("user is SYSTEM user", func() {
		var userProvider users.OSUserProvider
		var expectedKeyPath string
		var expectedRemoteUser string
		var kubeconfigPath string
		var sut *users.UserAdmission

		When("user has no previous kubeconfig with current context set", func() {
			BeforeAll(func() {
				fakeHomeDir := filepath.Join(GinkgoT().TempDir(), systemUserId)
				GinkgoWriter.Println("Using temp home dir <", fakeHomeDir, ">")

				expectedRemoteUser = "remote@" + suite.SetupInfo().Config.ControlPlane().IpAddress()
				expectedKeyPath = filepath.Join(fakeHomeDir, `.ssh\k2s\id_rsa`)
				kubeconfigPath = filepath.Join(fakeHomeDir, ".kube", "config")

				systemUserWithFakeHomeDir := contracts.NewOSUser(systemUserId, systemUserName, fakeHomeDir)

				userProvider = &winUserProvider{
					findByName: func(_ string) (*contracts.OSUser, error) { return systemUserWithFakeHomeDir, nil },
					getCurrent: osusers.CurrentUser,
				}

				connectionOptions := ssh.ConnectionOptions{
					RemoteUser:        definitions.SSHRemoteUser,
					IpAddress:         suite.SetupInfo().Config.ControlPlane().IpAddress(),
					Port:              definitions.SSHDefaultPort,
					SshPrivateKeyPath: suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
					Timeout:           definitions.SSHDefaultTimeout,
				}

				sut = users.NewUserAdmission(&suite.SetupInfo().Config, suite.SetupInfo().RuntimeConfig.ClusterConfig().Name(), connectionOptions, userProvider)

				Expect(sut.AddByName(systemUserName)).To(Succeed())
			})

			It("grants Windows SYSTEM user access to K2s control-plane", MustPassRepeatedly(2), func(ctx context.Context) {
				output := suite.Cli("ssh.exe").MustExec(ctx, "-n", "-o", "StrictHostKeyChecking=no", "-i", expectedKeyPath, expectedRemoteUser, "echo 'SSH access test successful'")

				Expect(output).To(ContainSubstring("SSH access test successful"))
			})

			It("sets Windows SYSTEM user's current context to K2s", func(ctx context.Context) {
				kubeconfig, err := kubeconfig.FromFile(kubeconfigPath)

				Expect(err).ToNot(HaveOccurred())
				Expect(kubeconfig.CurrentContext).To(Equal("k2s-NT-AUTHORITY-SYSTEM@" + suite.SetupInfo().RuntimeConfig.ClusterConfig().Name()))
			})
		})

		When("user has previous kubeconfig with current context set", func() {
			BeforeAll(func() {
				kubeconfig := `
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ABCD1234
    server: https://localhost:6443
  name: other-cluster
contexts:
- context:
    cluster: other-cluster
    user: other-user
  name: other-user@other-cluster
current-context: "other-user@other-cluster"
kind: Config
preferences: {}
users:
- name: other-user
  user:
    client-certificate-data: EFGH5678
    client-key-data: IJKL9012
`

				fakeHomeDir := filepath.Join(GinkgoT().TempDir(), systemUserId)
				GinkgoWriter.Println("Using temp home dir <", fakeHomeDir, ">")

				expectedRemoteUser = "remote@" + suite.SetupInfo().Config.ControlPlane().IpAddress()
				expectedKeyPath = filepath.Join(fakeHomeDir, `.ssh\k2s\id_rsa`)
				kubeconfigDir := filepath.Join(fakeHomeDir, ".kube")
				kubeconfigPath = filepath.Join(kubeconfigDir, "config")

				systemUserWithFakeHomeDir := contracts.NewOSUser(systemUserId, systemUserName, fakeHomeDir)

				userProvider = &winUserProvider{
					findByName: func(_ string) (*contracts.OSUser, error) { return systemUserWithFakeHomeDir, nil },
					getCurrent: osusers.CurrentUser,
				}

				connectionOptions := ssh.ConnectionOptions{
					RemoteUser:        definitions.SSHRemoteUser,
					IpAddress:         suite.SetupInfo().Config.ControlPlane().IpAddress(),
					Port:              definitions.SSHDefaultPort,
					SshPrivateKeyPath: suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
					Timeout:           definitions.SSHDefaultTimeout,
				}

				sut = users.NewUserAdmission(&suite.SetupInfo().Config, suite.SetupInfo().RuntimeConfig.ClusterConfig().Name(), connectionOptions, userProvider)

				Expect(os.MkdirAll(kubeconfigDir, os.ModePerm)).To(Succeed())
				Expect(os.WriteFile(kubeconfigPath, []byte(kubeconfig), os.ModePerm)).To(Succeed())
				Expect(sut.AddByName(systemUserName)).To(Succeed())
			})

			It("grants Windows SYSTEM user access to K2s control-plane", MustPassRepeatedly(2), func(ctx context.Context) {
				output := suite.Cli("ssh.exe").MustExec(ctx, "-n", "-o", "StrictHostKeyChecking=no", "-i", expectedKeyPath, expectedRemoteUser, "echo 'SSH access test successful'")

				Expect(output).To(ContainSubstring("SSH access test successful"))
			})

			It("keeps Windows SYSTEM user's previous context as current context", func(ctx context.Context) {
				kubeconfig, err := kubeconfig.FromFile(kubeconfigPath)

				Expect(err).ToNot(HaveOccurred())
				Expect(kubeconfig.CurrentContext).To(Equal("other-user@other-cluster"))
			})
		})
	})

	When("user not found by name", func() {
		It("prints not-found warning", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "users", "add", "-u", "non-existent-name")

			Expect(output).To(SatisfyAll(
				ContainSubstring("WARNING"),
				ContainSubstring("could not find"),
				ContainSubstring("name 'non-existent-name'"),
			))
		})
	})

	When("user not found by id", func() {
		It("prints not-found warning", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "users", "add", "-i", "non-existent-id")

			Expect(output).To(SatisfyAll(
				ContainSubstring("WARNING"),
				ContainSubstring("could not find"),
				ContainSubstring("id 'non-existent-id'"),
			))
		})
	})

	When("user is current admin user", func() {
		It("prints error", func(ctx context.Context) {
			currentUser, err := user.Current()
			Expect(err).ToNot(HaveOccurred())

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "users", "add", "-i", currentUser.Uid)

			Expect(output).To(SatisfyAll(
				ContainSubstring("ERROR"),
				ContainSubstring("cannot overwrite access of current user"),
				ContainSubstring(currentUser.Uid),
				ContainSubstring(currentUser.Username),
			))
		})
	})
})
