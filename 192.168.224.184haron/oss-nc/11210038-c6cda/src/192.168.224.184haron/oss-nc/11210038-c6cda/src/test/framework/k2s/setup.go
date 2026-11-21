// SPDX-FileCopyrightText: © 2025 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package k2s

import (
	"errors"
	"os"
	"strings"
	"sync"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	contracts "github.com/k2s-project/k2s/internal/contracts/config"
	"github.com/k2s-project/k2s/internal/core/clusterconfig"
	"github.com/k2s-project/k2s/internal/core/config"
	"github.com/k2s-project/k2s/internal/definitions"
)

type SetupInfo struct {
	Config        contracts.K2sConfig
	RuntimeConfig contracts.K2sRuntimeConfig
	ClusterConfig *clusterconfig.Cluster
	WinNodeName   string
}

var lock sync.Mutex

func CreateSetupInfo(installDir string) *SetupInfo {
	config, err := config.ReadK2sConfig(installDir)
	Expect(err).ToNot(HaveOccurred())

	return &SetupInfo{
		Config: *config,
	}
}

// ReloadRuntimeConfig reloads the runtime config from file
// It is recommended to call this before reading any values from RuntimeConfig
func (si *SetupInfo) ReloadRuntimeConfig() {
	lock.Lock()
	defer lock.Unlock()
	GinkgoWriter.Println("Reloading K2s runtime config..")

	runtimeConfig, err := config.ReadRuntimeConfig(si.Config.Host().K2sSetupConfigDir())
	Expect(err).ToNot(HaveOccurred())

	winNodeName, err := getWinNodeName(runtimeConfig.InstallConfig().SetupName())
	Expect(err).ToNot(HaveOccurred())

	si.WinNodeName = winNodeName
	si.RuntimeConfig = *runtimeConfig

	GinkgoWriter.Println("K2s runtime config reloaded")
}

func (si *SetupInfo) LoadClusterConfig() {
	lock.Lock()
	defer lock.Unlock()

	GinkgoWriter.Println("Loading cluster config..")

	clusterConfig, err := clusterconfig.Read(si.Config.Host().K2sSetupConfigDir())
	Expect(err).ToNot(HaveOccurred())

	if clusterConfig != nil {
		si.ClusterConfig = clusterConfig
	}

	GinkgoWriter.Println("Cluster config loaded")
}

func (si *SetupInfo) GetProxyForNode(nodeName string) string {
	proxy := "http://172.19.1.1:8181"

	if si.ClusterConfig != nil {
		for _, n := range si.ClusterConfig.Nodes {
			if n.Name == nodeName && n.Proxy != "" {
				proxy = n.Proxy
				break
			}
		}
	}

	return proxy
}

func getWinNodeName(setupName string) (string, error) {
	switch setupName {
	case definitions.SetupNameK2s:
		name, err := os.Hostname()
		if err != nil {
			return "", err
		}
		return strings.ToLower(name), nil
	default:
		return "", errors.New("no setup type defined")
	}
}
