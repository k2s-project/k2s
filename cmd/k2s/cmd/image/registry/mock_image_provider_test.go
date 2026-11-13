// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package registry

import (
	"context"
	"os"

	"github.com/k2s-project/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/k2s-project/k2s/internal/contracts/config"
	coreconfig "github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/provider"
	"github.com/spf13/cobra"
	"github.com/stretchr/testify/mock"
)

type mockImageProvider struct {
	mock.Mock
}

func (m *mockImageProvider) List(config provider.ImageListConfig) (*provider.ImageListResult, error) {
	args := m.Called(config)
	if args.Get(0) == nil {
		return nil, args.Error(1)
	}
	return args.Get(0).(*provider.ImageListResult), args.Error(1)
}

func (m *mockImageProvider) Pull(config provider.ImagePullConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Remove(config provider.ImageRemoveConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Build(config provider.ImageBuildConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Import(config provider.ImageImportConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Export(config provider.ImageExportConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Tag(config provider.ImageTagConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Push(config provider.ImagePushConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) Clean(config provider.ImageCleanConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) RegistryAdd(config provider.ImageRegistryAddConfig) error {
	return m.Called(config).Error(0)
}

func (m *mockImageProvider) RegistryRemove(config provider.ImageRegistryRemoveConfig) error {
	return m.Called(config).Error(0)
}

func setupTestCmdContext(cmd *cobra.Command, mockImg *mockImageProvider, linuxOnly bool, cpHostname string) string {
	tempDir, err := os.MkdirTemp("", "k2s-registry-test-*")
	if err != nil {
		panic(err)
	}

	if err := coreconfig.WriteRuntimeConfig(tempDir, "k2s", linuxOnly, "1.0.0", "k2s", cpHostname, false); err != nil {
		panic(err)
	}

	hostConfig := cconfig.NewHostConfig(nil, nil, tempDir, tempDir, tempDir)
	k2sConfig := cconfig.NewK2sConfig(hostConfig, nil)

	var reg *provider.Registry
	if mockImg != nil {
		reg = &provider.Registry{Image: mockImg}
	}

	cmdContext := common.NewCmdContext(k2sConfig, nil, reg, nil)
	ctx := context.WithValue(context.Background(), common.ContextKeyCmdContext, cmdContext)
	cmd.SetContext(ctx)

	return tempDir
}
