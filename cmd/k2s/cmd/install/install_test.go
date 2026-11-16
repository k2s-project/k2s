// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package install

import (
	"testing"

	"github.com/k2s-project/k2s/cmd/k2s/utils/tz"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	ic "github.com/k2s-project/k2s/cmd/k2s/cmd/install/config"

	"github.com/k2s-project/k2s/internal/contracts/config"
	r "github.com/k2s-project/k2s/internal/test/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Install(kind ic.Kind, cmd *cobra.Command, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error), cmdSession common.CmdSession) error {
	args := m.Called(kind, cmd, buildCmdFunc, cmdSession)

	return args.Error(0)
}

type mockTzConfigWorkspaceHandle struct {
	mock.Mock
}

func (m *mockTzConfigWorkspaceHandle) Release() error {
	args := m.Called()
	return args.Error(0)
}

func SetupTimezoneConfigMock() {
	mockTimezoneConfigWorkspaceHandle := &mockTzConfigWorkspaceHandle{}
	mockTimezoneConfigWorkspaceHandle.On(r.GetFunctionName(mockTimezoneConfigWorkspaceHandle.Release)).Return(nil)

	createTzHandleFunc = func(config *config.KubeConfig) (tz.ConfigWorkspaceHandle, error) {
		return mockTimezoneConfigWorkspaceHandle, nil
	}
}

func TestInstall(t *testing.T) {
	RegisterFailHandler(Fail)
	SetupTimezoneConfigMock()
	RunSpecs(t, "install Unit Tests", Label("unit", "ci"))
}

var _ = Describe("install", func() {
	Describe("install", func() {
		When("error while receiving Linux-only flag value occurred", func() {
			It("returns error", func() {
				cmd := &cobra.Command{}

				Expect(install(cmd, nil)).ToNot(Succeed())
			})
		})
	})
})
