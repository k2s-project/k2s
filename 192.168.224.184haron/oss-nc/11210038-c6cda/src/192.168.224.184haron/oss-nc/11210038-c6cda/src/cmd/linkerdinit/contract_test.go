// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type hnsProxyConfig struct {
	InboundProxyPort       string `json:"inboundproxyport"`
	OutboundProxyPort      string `json:"outboundproxyport"`
	InboundPortExceptions  string `json:"inboundportexceptions"`
	OutboundPortExceptions string `json:"outboundportexceptions"`
}

type k2sConfig struct {
	SmallSetup struct {
		VfpRules struct {
			HnsProxyConfig hnsProxyConfig `json:"hnsproxyconfig"`
		} `json:"vfprules-k2s"`
	} `json:"smallsetup"`
}

func findConfigPath() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(dir, filepath.FromSlash(hnsProxyConfigPath))
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", os.ErrNotExist
}

var _ = Describe("contract", func() {
	It("matches the HNS proxy configuration the K2s CNI applies", func() {
		configPath, err := findConfigPath()
		Expect(err).ToNot(HaveOccurred())

		content, err := os.ReadFile(configPath)
		Expect(err).ToNot(HaveOccurred())

		var config k2sConfig
		Expect(json.Unmarshal(content, &config)).To(Succeed())

		actual := config.SmallSetup.VfpRules.HnsProxyConfig

		Expect(actual.InboundProxyPort).To(Equal(inboundProxyPort))
		Expect(actual.OutboundProxyPort).To(Equal(outboundProxyPort))
		Expect(actual.InboundPortExceptions).To(Equal(inboundPortExceptions))
		Expect(actual.OutboundPortExceptions).To(Equal(outboundPortExceptions))
	})
})
