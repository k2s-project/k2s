// SPDX-FileCopyrightText: © 2026 The K2s Authors
//
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestClusteripWebhookUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "clusterip-webhook Unit Tests", Label("unit", "ci"))
}
