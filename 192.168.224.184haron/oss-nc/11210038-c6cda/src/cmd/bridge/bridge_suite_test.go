// SPDX-FileCopyrightText: © 2024 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var t *testing.T

func TestBridgeUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "bridge Acceptance Tests", Label("acceptance"))
}

var _ = Describe("Bridge Tests", func() {
	It("executes add CMD", func() {
		Skip("test currently not working")

		// testDualStack := (os.Getenv("TestDualStack") == "1")
		// imageToUse := os.Getenv("ImageToUse")
		// ipams := util.GetDefaultIpams()

		// if testDualStack {
		// 	ipams = append(ipams, util.GetDefaultIpv6Ipams()...)
		// }

		// testNetwork := util.CreateTestNetwork(t, "bridgeNet", "L2Bridge", ipams, true)
		// pt := util.MakeTestStruct(t, testNetwork, "bridge", true, true, "", testDualStack, imageToUse)
		// pt.Ipv6Url = os.Getenv("Ipv6UrlToUse")
		// pt.RunAll(t)
	})
})
